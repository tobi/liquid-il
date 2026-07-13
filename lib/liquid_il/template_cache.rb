# frozen_string_literal: true

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
    attr_reader :byte_size, :digest, :partial_constants, :partial_dependencies

    def initialize(compiled_proc, partial_constants, byte_size, digest, partial_dependencies = nil)
      @proc = compiled_proc
      @partial_constants = partial_constants
      @byte_size = byte_size
      @digest = digest
      # {name => {digest:, disposition:}} — only external entries are persisted
      # (see Artifact); nil for artifacts with no external partials.
      @partial_dependencies = partial_dependencies
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
  # the entry is transparently reloaded. Thread-safe (single mutex).
  class TemplateCache
    attr_reader :max_bytes

    def initialize(max_bytes: 64 * 1024 * 1024)
      @max_bytes = max_bytes
      @entries = {}      # key => CompiledArtifact (Hash preserves LRU order)
      @total_bytes = 0
      @mutex = Mutex.new
    end

    # Return an already-loaded artifact without requiring artifact bytes.
    # A hit touches the LRU; a miss returns nil. Production cache coordinators
    # use this to avoid even a remote-cache lookup on the hottest path.
    def get(key)
      @mutex.synchronize do
        entry = @entries.delete(key)
        @entries[key] = entry if entry
        entry
      end
    end

    # Fetch the loaded artifact for `key`, loading (and caching) `blob` on a
    # miss or when the blob content changed. `blob` may also be supplied
    # lazily via the block, so callers can skip the memcache fetch on a hit:
    #
    #   cache.fetch(key) { memcache.get(key) }.render(assigns)
    #
    def fetch(key, blob = nil)
      @mutex.synchronize do
        entry = @entries[key]
        if entry
          if blob.nil? || Artifact.identity(blob) == entry.digest
            # LRU touch: move to the most-recently-used end
            @entries.delete(key)
            @entries[key] = entry
            return entry
          end
          # Blob changed under the same key — drop the stale entry
          @entries.delete(key)
          @total_bytes -= entry.byte_size
        end

        blob ||= yield if block_given?
        raise ArgumentError, "no artifact blob for cache miss on #{key.inspect}" if blob.nil?

        artifact = Artifact.load_compiled(blob)
        if artifact.byte_size <= @max_bytes
          @entries[key] = artifact
          @total_bytes += artifact.byte_size
          evict_over_budget
        end
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

    # Caller holds @mutex. Hash insertion order = LRU order (oldest first).
    def evict_over_budget
      while @total_bytes > @max_bytes && !@entries.empty?
        key, artifact = @entries.first
        @entries.delete(key)
        @total_bytes -= artifact.byte_size
      end
    end
  end
end
