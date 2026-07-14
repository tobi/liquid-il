# frozen_string_literal: true

require "thread"

module LiquidIL
  # A loaded artifact: the callable proc plus its metadata — the leanest
  # render path for the production pattern
  #
  #   blob = memcache.get(key)
  #   LiquidIL.load_artifact(blob).render(assigns)
  #
  # Unlike Template, this carries no source/context. Rendering builds
  # the Scope directly (no context/register merging).
  class CompiledArtifact
    attr_reader :byte_size, :digest, :partial_constants, :partial_dependencies,
                :template_metadata, :host_tag_metadata, :host_tag_index

    def initialize(compiled_proc, partial_constants, byte_size, digest, partial_dependencies = nil,
                   template_metadata = nil, host_tag_metadata = nil)
      @proc = compiled_proc
      @partial_constants = partial_constants
      @byte_size = byte_size
      @digest = digest
      # {name => {digest:, disposition:}} — only external entries are persisted
      # (see Artifact); nil for artifacts with no external partials.
      @partial_dependencies = partial_dependencies
      @template_metadata = template_metadata
      @host_tag_metadata = host_tag_metadata
      @host_tag_index = build_host_tag_index(host_tag_metadata)
    end

    def render(assigns = {}, registers: nil, render_errors: true, static_environments: nil,
               strict_variables: nil, strict_filters: nil, resource_limits: nil,
               partial_provider: nil, output: nil, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      scope = RenderExecutor.build_scope(
        assigns,
        registers: registers,
        render_errors: render_errors,
        static_environments: static_environments,
        strict_variables: strict_variables,
        strict_filters: strict_filters,
        resource_limits: resource_limits,
        partial_provider: partial_provider,
      )
      RenderExecutor.call(@proc, scope, @partial_constants, output: output)
    end

    def render!(assigns = {}, **options)
      render(assigns, render_errors: false, **options)
    end

    # Render against a caller-supplied, fully-configured Scope instead of
    # building one from assigns. This is the storefront context-bridge seam:
    # a host ContextShim owns the Scope (scope reads/writes, registers,
    # resource accounting, filters, file_system) and hands it to the engine
    # to execute the loaded artifact's proc. Errors are formatted inline
    # exactly like #render when scope.render_errors is true.
    def render_scope(scope, output: nil)
      RenderExecutor.call(@proc, scope, @partial_constants, output: output)
    end

    # Append into a caller-provided buffer instead of returning a fresh string;
    # returns the buffer. Mirrors Template#render_to_output_buffer.
    def render_to_output_buffer(context_or_assigns = {}, output = +"", **options)
      render(context_or_assigns, output: output, **options)
    end

    private

    def build_host_tag_index(metadata)
      return EMPTY_HASH unless metadata

      index = {}
      metadata.each_value do |tags|
        tags.each do |source_id, slot, _name, _line, plan|
          plan.freeze
          slots = (index[source_id] ||= [])
          existing = slots[slot]
          if existing && !existing.equal?(plan) && existing != plan
            raise CorruptArtifactError, "conflicting host tag slot #{slot} for #{source_id}"
          end
          slots[slot] = plan
        end
      end
      index.each_value(&:freeze)
      index.freeze
    end
  end

  # Memory-bounded LRU cache of loaded artifacts, for processes that render
  # the same templates repeatedly. The common access pattern:
  #
  #   cache = LiquidIL::TemplateCache.new(max_bytes: 64 * 1024 * 1024)
  #   blob  = memcache.get(key)
  #   cache.render(key, blob, assigns)   # loads+caches once, then reuses
  #
  # Accounting: the budget is charged with each artifact's persisted byte
  # size (`blob.bytesize`) — a stable proxy for the loaded ISeq's memory
  # footprint. When an insert pushes the total over `max_bytes`, least-
  # recently-used entries are evicted until the total fits. A single
  # artifact larger than the whole budget is rendered but not retained.
  #
  # Staleness: each entry remembers its validated payload CRC32; if a later
  # call passes a blob whose checksum differs (template was republished under the same key),
  # the entry is transparently reloaded. LRU metadata is mutex-protected;
  # expensive decoding uses a per-key singleflight outside that global mutex.
  class TemplateCache
    Flight = Struct.new(:condition, :done, :artifact, :error, :waiters)

    attr_reader :max_bytes

    def initialize(max_bytes: 64 * 1024 * 1024)
      @max_bytes = Integer(max_bytes)
      raise ArgumentError, "max_bytes must not be negative" if @max_bytes.negative?

      @entries = {}      # key => CompiledArtifact (Hash preserves LRU order)
      @flights = {}      # key => Flight (decode/load singleflight)
      @total_bytes = 0
      @mutex = Mutex.new
    end

    # Return an already-loaded artifact without requiring artifact bytes.
    # A hit touches the LRU; a miss returns nil. Production cache coordinators
    # use this to avoid even a remote-cache lookup on the hottest path.
    def get(key)
      @mutex.synchronize do
        touch_entry(key)
      end
    end

    # Check whether an artifact is resident without changing LRU order. Cache
    # coordinators use this to filter preload manifests without turning the
    # preload probe itself into evidence of use.
    def resident?(key)
      @mutex.synchronize { @entries.key?(key) }
    end

    # Fetch the loaded artifact for `key`, loading (and caching) `blob` on a
    # miss or when the blob content changed. `blob` may also be supplied
    # lazily via the block, so callers can skip the memcache fetch on a hit:
    #
    #   cache.fetch(key) { memcache.get(key) }.render(assigns)
    #
    def fetch(key, blob = nil)
      blob_identity = Artifact.identity(blob) if blob
      flight = nil

      @mutex.synchronize do
        entry = @entries[key]
        if entry
          if blob.nil? || blob_identity == entry.digest
            return touch_entry(key)
          end
          # Blob changed under the same key — drop the stale entry
          delete_entry(key)
        end

        if (flight = @flights[key])
          flight.waiters += 1
          begin
            flight.condition.wait(@mutex) until flight.done
            raise flight.error if flight.error

            return flight.artifact
          ensure
            flight.waiters -= 1
            if flight.done && flight.waiters.zero? && @flights[key].equal?(flight)
              @flights.delete(key)
            end
          end
        end

        flight = Flight.new(ConditionVariable.new, false, nil, nil, 0)
        @flights[key] = flight
      end

      begin
        blob ||= yield if block_given?
        raise ArgumentError, "no artifact blob for cache miss on #{key.inspect}" if blob.nil?

        # Envelope verification, JSON/Marshal decoding, ISeq loading and eval
        # can all be expensive. They deliberately happen outside the global
        # LRU mutex; concurrent callers for this key wait on `flight` while
        # unrelated cache hits and loads continue.
        artifact = Artifact.load_compiled(blob)
      rescue StandardError, ScriptError => error
        finish_flight(key, flight, error: error)
        raise
      end

      finish_flight(key, flight, artifact: artifact)
    end

    # Insert an artifact whose callable already exists in this process (for
    # example, the proc produced by a fresh compile). This avoids immediately
    # decoding and loading the ISeq that was just serialized for the remote
    # cache. An identical resident artifact wins so callers converge on one
    # process-local object.
    def store(key, artifact)
      unless artifact.is_a?(CompiledArtifact)
        raise ArgumentError, "expected a LiquidIL::CompiledArtifact"
      end

      @mutex.synchronize do
        if (entry = @entries[key]) && entry.digest == artifact.digest
          return touch_entry(key)
        end

        delete_entry(key) if @entries.key?(key)
        insert_entry(key, artifact)
        artifact
      end
    end

    # The one-call production pattern: load-or-reuse, then render.
    def render(key, blob, assigns = {}, registers: nil, **extra_assigns)
      assigns = assigns.merge(extra_assigns) unless extra_assigns.empty?
      fetch(key, blob).render(assigns, registers: registers)
    end

    def size = @mutex.synchronize { @entries.size }
    def bytes = @mutex.synchronize { @total_bytes }

    def clear
      @mutex.synchronize do
        @entries.clear
        @total_bytes = 0
      end
    end

    private

    def finish_flight(key, flight, artifact: nil, error: nil)
      @mutex.synchronize do
        # `store` can populate the LRU while a load is in progress. Reuse an
        # identical resident object; otherwise the completed load becomes the
        # current value for this content-addressed key.
        if artifact
          resident = @entries[key]
          if resident&.digest == artifact.digest
            artifact = touch_entry(key)
          else
            delete_entry(key) if resident
            insert_entry(key, artifact)
          end
        end

        flight.artifact = artifact
        flight.error = error
        flight.done = true
        flight.condition.broadcast
        @flights.delete(key) if flight.waiters.zero? && @flights[key].equal?(flight)
        artifact
      end
    end

    # Caller holds @mutex.
    def touch_entry(key)
      entry = @entries.delete(key)
      @entries[key] = entry if entry
      entry
    end

    # Caller holds @mutex.
    def delete_entry(key)
      entry = @entries.delete(key)
      @total_bytes -= entry.byte_size if entry
      entry
    end

    # Caller holds @mutex.
    def insert_entry(key, artifact)
      return if @max_bytes.zero? || artifact.byte_size > @max_bytes

      @entries[key] = artifact
      @total_bytes += artifact.byte_size
      evict_over_budget
    end

    # Caller holds @mutex. Hash insertion order = LRU order (oldest first).
    def evict_over_budget
      while @total_bytes > @max_bytes && !@entries.empty?
        key, = @entries.first
        delete_entry(key)
      end
    end
  end
end
