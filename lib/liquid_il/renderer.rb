# frozen_string_literal: true

require "digest"
require "json"

module LiquidIL
  # Process-long-lived production renderer. It coordinates a loaded-proc LRU,
  # an optional memcache-like remote cache, named source lookup, and per-request
  # RenderSession objects.
  #
  #   renderer = LiquidIL::Renderer.new(remote_cache: Rails.cache,
  #     namespace: "storefront:deploy-42")
  #
  #   renderer.session(templates: theme, preload_key: "route:product") do |session|
  #     session.render("layout/theme", assigns)
  #   end
  #
  # `templates` must answer #digest(name), #read(name) (or
  # #read_template_file), and preferably #bytesize(name). It may additionally
  # answer #canonical_name, #external?, or #inline?.
  class Renderer
    PLAN_VERSION = 1
    MAX_LOCAL_HEADS = 10_000
    DEFAULT_PRELOAD_KEYS = 256
    LOCK_STRIPES = 64

    attr_reader :namespace, :context_options, :remote_cache_options, :max_preload_keys,
      :max_local_heads

    def initialize(remote_cache: nil, max_local_bytes: 64 * 1024 * 1024,
                   namespace: "liquid-il", context_options: {},
                   remote_cache_options: {}, max_preload_keys: DEFAULT_PRELOAD_KEYS,
                   max_local_heads: MAX_LOCAL_HEADS, instrumenter: nil,
                   collect_stats: true, template_metadata_compiler: nil,
                   template_metadata_compiler_key: nil)
      @remote = RemoteCache.new(remote_cache, remote_cache_options)
      @live = TemplateCache.new(max_bytes: max_local_bytes)
      @namespace = namespace.to_s.freeze
      @context_options = context_options.dup.freeze
      @remote_cache_options = remote_cache_options.dup.freeze
      @max_preload_keys = Integer(max_preload_keys)
      raise ArgumentError, "max_preload_keys must not be negative" if @max_preload_keys.negative?
      @max_local_heads = Integer(max_local_heads)
      raise ArgumentError, "max_local_heads must not be negative" if @max_local_heads.negative?
      @instrumenter = instrumenter
      @collect_stats = !!collect_stats
      if template_metadata_compiler && template_metadata_compiler_key.to_s.empty?
        raise ArgumentError, "template_metadata_compiler_key is required with template_metadata_compiler"
      end
      @template_metadata_compiler = template_metadata_compiler
      @template_metadata_compiler_key = template_metadata_compiler_key&.to_s&.freeze
      @heads = {}
      @heads_mutex = Mutex.new
      @locks = Array.new(LOCK_STRIPES) { Mutex.new }
      @runtime_stamp = [
        Artifact::VERSION, Artifact::RUNTIME_ABI, Artifact::COMPILER_ABI,
        Artifact::RUBY_STAMP,
      ].join("/").freeze
      @configuration_digest = digest_key(canonical_json([
        @context_options,
        Tags.compilation_cache_fingerprint,
        @template_metadata_compiler_key,
      ]))
    end

    # With a block, closes the request session automatically and returns the
    # block's value. Without a block, the caller must invoke #close.
    def session(templates:, preload_key: nil, fingerprint: nil, parse_options: {}, cache_vary: nil,
                remote_cache: nil, remote_cache_options: nil, source_snapshot: nil,
                trust_source_snapshot: false)
      if preload_key && fingerprint && preload_key != fingerprint
        raise ArgumentError, "preload_key and fingerprint disagree"
      end
      remote = if remote_cache
        RemoteCache.new(remote_cache, remote_cache_options || @remote_cache_options)
      else
        @remote
      end
      session = RenderSession.new(
        self,
        templates: templates,
        preload_key: preload_key || fingerprint,
        parse_options: parse_options,
        cache_vary: cache_vary,
        remote: remote,
        source_snapshot: source_snapshot,
        trust_source_snapshot: trust_source_snapshot,
      )
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end

    def local_artifact(key)
      @live.get(key)
    end

    def local_artifact_resident?(key)
      @live.resident?(key)
    end

    def load_local_artifact(key, bytes)
      @live.fetch(key, bytes)
    end

    def store_local_artifact(key, artifact)
      @live.store(key, artifact)
    end

    def local_head(key)
      return if @max_local_heads.zero?

      @heads_mutex.synchronize do
        plan = @heads.delete(key)
        @heads[key] = plan if plan
        plan
      end
    end

    def local_head_resident?(key)
      return false if @max_local_heads.zero?

      @heads_mutex.synchronize { @heads.key?(key) }
    end

    def local_key_resident?(key)
      if key.start_with?("lqil:head:")
        local_head_resident?(key)
      elsif key.start_with?("lqil:artifact:")
        local_artifact_resident?(key)
      else
        local_head_resident?(key) || local_artifact_resident?(key)
      end
    end

    def store_local_head(key, plan)
      return plan if @max_local_heads.zero?

      @heads_mutex.synchronize do
        @heads.delete(key)
        @heads.shift if @heads.size >= @max_local_heads
        @heads[key] = plan
      end
    end

    def delete_local_head(key)
      return if @max_local_heads.zero?

      @heads_mutex.synchronize { @heads.delete(key) }
    end

    def synchronize(key, &block)
      @locks[key.hash % @locks.length].synchronize(&block)
    end

    def remote_read(key)
      @remote.read(key)
    end

    def remote_write(key, value)
      @remote.write(key, value)
    end

    def remote_read_multi(keys)
      @remote.read_multi(keys)
    end

    def instrument(event, payload = {})
      return unless @instrumenter

      name = "liquid_il.#{event}"
      if @instrumenter.respond_to?(:instrument)
        @instrumenter.instrument(name, payload)
      else
        @instrumenter.call(name, payload)
      end
    rescue StandardError
      # Observability must never take down rendering.
      nil
    end

    def instrumented?
      !@instrumenter.nil?
    end

    def collect_stats?
      @collect_stats
    end

    def compile_template_metadata(template, parse_options)
      return template unless @template_metadata_compiler && template.template_metadata

      template.transform_template_metadata! do |metadata|
        @template_metadata_compiler.call(metadata, parse_options)
      end
    end

    def head_key(name, root_digest, vary, source_snapshot = nil)
      cache_key("head", [name, root_digest, vary, source_snapshot])
    end

    def artifact_key(name, root_digest, vary, dependencies)
      embedded = dependencies.sort_by { |dep| dep.fetch("name") }.map do |dep|
        if dep.fetch("disposition") == "external"
          [dep.fetch("name"), "external"]
        else
          [dep.fetch("name"), dep.fetch("disposition"), dep.fetch("digest")]
        end
      end
      cache_key("artifact", [name, root_digest, vary, embedded])
    end

    def preload_storage_key(preload_key, vary = nil)
      cache_key("preload", [preload_key.to_s, vary])
    end

    def parse_vary(parse_options, explicit)
      return digest_key(explicit.to_s) unless explicit.nil?

      digest_key(canonical_json(parse_options))
    end

    def encode_plan(plan)
      JSON.generate(plan)
    end

    def decode_plan(bytes)
      value = JSON.parse(bytes, create_additions: false)
      return nil unless value.is_a?(Hash) && value["version"] == PLAN_VERSION
      return nil unless value["artifact_key"].is_a?(String)
      return nil unless value["dependencies"].is_a?(Array)

      value
    rescue JSON::ParserError, TypeError
      nil
    end

    def encode_preload(keys)
      JSON.generate({ "version" => PLAN_VERSION, "keys" => keys.first(@max_preload_keys) })
    end

    def decode_preload(bytes)
      value = JSON.parse(bytes, create_additions: false)
      return [] unless value.is_a?(Hash) && value["version"] == PLAN_VERSION

      Array(value["keys"]).grep(String).first(@max_preload_keys)
    rescue JSON::ParserError, TypeError
      []
    end

    private

    def cache_key(kind, value)
      preimage = canonical_json([
        @namespace, @runtime_stamp, @configuration_digest, kind, value,
      ])
      "lqil:#{kind}:#{digest_key(preimage)}"
    end

    def digest_key(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value))
    rescue JSON::GeneratorError, TypeError => e
      raise ArgumentError, "cache-varying options must be JSON-safe (or supply cache_vary): #{e.message}"
    end

    def canonical_value(value)
      case value
      when Hash
        value.map { |key, child| [key.to_s, canonical_value(child)] }
          .sort_by(&:first).to_h
      when Array
        value.map { |child| canonical_value(child) }
      when Symbol
        value.to_s
      when String, Integer, Float, TrueClass, FalseClass, NilClass
        value
      else
        raise TypeError, "unsupported cache-key value #{value.class}"
      end
    end

    # Normalizes Rails.cache-like and Dalli-like clients. Remote cache failures
    # are treated as misses; compilation and rendering remain available.
    class RemoteCache
      def initialize(cache, write_options)
        @cache = cache
        @write_options = write_options
      end

      def read(key)
        return nil unless @cache
        @cache.respond_to?(:read) ? @cache.read(key) : @cache.get(key)
      rescue StandardError
        nil
      end

      def write(key, value)
        return false unless @cache
        if @cache.respond_to?(:write)
          @cache.write(key, value, **@write_options)
        elsif @write_options.empty?
          @cache.set(key, value)
        else
          @cache.set(key, value, **@write_options)
        end
      rescue StandardError
        false
      end

      def read_multi(keys)
        return {} unless @cache && !keys.empty?
        result = if @cache.respond_to?(:read_multi)
          begin
            @cache.read_multi(*keys)
          rescue ArgumentError
            @cache.read_multi(keys)
          end
        elsif @cache.respond_to?(:get_multi)
          @cache.get_multi(*keys)
        else
          keys.to_h { |key| [key, read(key)] }.compact
        end
        result || {}
      rescue StandardError
        {}
      end
    end
  end

  # One request/render-session. Sessions are intentionally not thread-safe;
  # create one per request and share the parent Renderer across threads.
  class RenderSession
    attr_reader :stats

    def initialize(renderer, templates:, preload_key:, parse_options:, cache_vary:, remote:,
                   source_snapshot:, trust_source_snapshot:)
      @renderer = renderer
      @remote = remote
      @source = TemplateSource.new(templates, self)
      @preload_key = preload_key&.to_s
      @parse_options = parse_options.dup.freeze
      @vary = renderer.parse_vary(@parse_options, cache_vary)
      @source_snapshot = source_snapshot&.to_s&.freeze
      @trust_source_snapshot = !!trust_source_snapshot
      if @trust_source_snapshot && @source_snapshot.nil?
        raise ArgumentError, "trust_source_snapshot requires source_snapshot"
      end
      @memo = {}
      @preloaded = EMPTY_HASH
      @preload_loaded = false
      @preload_manifest_loaded = false
      @preload_manifest_keys = EMPTY_ARRAY
      @touched = [] if @preload_key
      @collect_stats = renderer.collect_stats?
      @instrument = renderer.instrumented?
      @stats = @collect_stats ? Hash.new(0) : EMPTY_HASH
      @closed = false
      @provider = ->(name, _baked_digest) { fetch_artifact(name) }
      emit("session.start", preload_key: @preload_key) if @instrument
    end

    # Look up a named template and return a session-bound renderable. This is
    # useful for an individual template lookup or explicit prewarming.
    def fetch(name, around_compile: nil)
      SessionTemplate.new(fetch_artifact(name, around_compile:), @provider)
    end
    alias template fetch

    def render(name, assigns = {}, **options)
      started = monotonic if @instrument
      output = fetch_artifact(name).render(assigns, **options.merge(partial_provider: @provider))
      @stats[:renders] += 1 if @collect_stats
      if @instrument
        emit("render", template: canonical_name(name), duration: monotonic - started)
      end
      output
    end

    def render!(name, assigns = {}, **options)
      render(name, assigns, **options.merge(render_errors: false))
    end

    def render_to_output_buffer(name, assigns = {}, output = +"", **options)
      fetch_artifact(name).render_to_output_buffer(
        assigns, output, **options.merge(partial_provider: @provider)
      )
    end

    def close
      return @stats if @closed
      @closed = true

      # Never introduce remote I/O solely to maintain the manifest: a request
      # satisfied entirely by the local head/artifact LRUs must remain entirely
      # local. Cold and remote paths load the manifest in #ensure_preloaded!,
      # and only those sessions merge their observed keys back into it.
      if @preload_manifest_loaded && @touched&.any? && @renderer.max_preload_keys.positive?
        touched = @touched.uniq
        merged = (touched + @preload_manifest_keys).uniq.first(@renderer.max_preload_keys)
        unless merged == @preload_manifest_keys
          bytes = @renderer.encode_preload(merged)
          write_remote(preload_storage_key, bytes, kind: :preload)
          @preload_manifest_keys = merged
        end
      end
      emit("session.finish", stats: @stats.dup) if @instrument
      @stats
    end

    # Internal hooks used by TemplateSource for complete lookup telemetry.
    def source_lookup(name, kind)
      @stats[:"source_#{kind}"] += 1 if @collect_stats
      emit("source.lookup", template: name, kind: kind) if @instrument
    end

    private

    def fetch_artifact(raw_name, around_compile: nil)
      raise "render session is closed" if @closed
      name = canonical_name(raw_name)
      root_digest = @source.digest(name)
      raise LiquidIL::Error, "template #{name.inspect} was not found" if root_digest.nil?

      memo_key = [name, root_digest]
      if (artifact = @memo[memo_key])
        lookup(:request, true, name)
        return artifact
      end
      lookup(:request, false, name)

      head_key = @renderer.head_key(name, root_digest, @vary, @source_snapshot)
      artifact = resolve_from_plan(name, root_digest, head_key, @renderer.local_head(head_key), :local)
      artifact ||= resolve_remote(name, root_digest, head_key)
      artifact ||= @renderer.synchronize(head_key) do
        # Another thread may have populated either tier while this request was
        # waiting on the singleflight stripe.
        resolve_from_plan(name, root_digest, head_key, @renderer.local_head(head_key), :local) ||
          resolve_remote(name, root_digest, head_key) ||
          compile(name, root_digest, head_key, around_compile:)
      end

      @memo[memo_key] = artifact
    end

    def resolve_remote(name, root_digest, head_key)
      ensure_preloaded!
      bytes, tier = cached_bytes(head_key)
      unless bytes
        bytes = read_remote(head_key, kind: :head, template: name)
        tier = :remote
      end
      plan = bytes && @renderer.decode_plan(bytes)
      lookup(tier || :remote, !plan.nil?, name, kind: :head)
      resolve_from_plan(name, root_digest, head_key, plan, tier || :remote)
    end

    def resolve_from_plan(name, root_digest, head_key, plan, tier)
      return nil unless plan
      unless valid_plan?(plan, name, root_digest)
        @renderer.delete_local_head(head_key)
        @stats[:stale_plans] += 1 if @collect_stats
        emit("cache.stale", tier: tier, kind: :head, template: name) if @instrument
        return nil
      end

      @renderer.store_local_head(head_key, plan) unless tier == :local
      artifact_key = plan.fetch("artifact_key")
      touch(head_key)
      touch(artifact_key)

      if (artifact = @renderer.local_artifact(artifact_key))
        lookup(:local, true, name, kind: :artifact)
        return artifact
      end
      lookup(:local, false, name, kind: :artifact)

      ensure_preloaded!
      bytes, bytes_tier = cached_bytes(artifact_key)
      bytes ||= read_remote(artifact_key, kind: :artifact, template: name)
      return nil unless bytes

      begin
        artifact = @renderer.load_local_artifact(artifact_key, bytes)
        lookup(bytes_tier || :remote, true, name, kind: :artifact)
        artifact
      rescue StaleArtifactError, CorruptArtifactError, ArgumentError, TypeError
        @stats[:invalid_artifacts] += 1 if @collect_stats
        if @instrument
          emit("artifact.invalid", template: name, tier: bytes_tier || :remote)
        end
        nil
      end
    end

    def valid_plan?(plan, name, root_digest)
      return false unless plan["name"] == name && plan["root_digest"] == root_digest
      return false unless plan["vary"] == @vary
      return false unless plan["source_snapshot"] == @source_snapshot
      return true if @trust_source_snapshot

      plan.fetch("dependencies").all? do |dep|
        dep_name = dep["name"]
        digest = @source.digest(dep_name)
        next false if digest.nil?

        external = @source.external?(dep_name, digest)
        if dep["disposition"] == "external"
          external
        else
          !external && dep["digest"] == digest
        end
      end
    rescue KeyError, TypeError
      false
    end

    def compile(name, expected_digest, head_key, around_compile: nil)
      if around_compile
        return around_compile.call do
          compile(name, expected_digest, head_key)
        end
      end

      attempts = 0
      begin
        attempts += 1
        started = monotonic if @instrument
        body = @source.read(name)
        raise LiquidIL::Error, "template #{name.inspect} was not found" if body.nil?
        raise SourceChanged if @source.digest(name) != expected_digest

        context_options = @renderer.context_options.dup
        error_mode = @parse_options[:error_mode] || @parse_options["error_mode"] ||
          context_options.delete(:error_mode) || context_options.delete("error_mode") || :strict2
        context_options.delete(:file_system)
        context_options.delete("file_system")
        context_options.delete(:partial_index)
        context_options.delete("partial_index")
        context = Context.new(
          **context_options.transform_keys(&:to_sym),
          file_system: @source,
          partial_index: @source,
          error_mode: error_mode.to_sym,
        )
        parser_options = @parse_options.reject { |key, _| key.to_s == "error_mode" }
        template = context.parse(body, **parser_options.transform_keys(&:to_sym), template_name: name)
        @renderer.compile_template_metadata(template, @parse_options)
        dependencies = normalize_dependencies(template.partial_dependencies)
        raise SourceChanged unless compile_snapshot_valid?(name, expected_digest, dependencies)

        artifact_key = @renderer.artifact_key(name, expected_digest, @vary, dependencies)
        artifact_bytes = template.to_artifact
        plan = {
          "version" => Renderer::PLAN_VERSION,
          "name" => name,
          "root_digest" => expected_digest,
          "vary" => @vary,
          "source_snapshot" => @source_snapshot,
          "artifact_key" => artifact_key,
          "dependencies" => dependencies,
        }

        # Publish data before the pointer. Readers can safely treat a missing
        # artifact as a cache miss while concurrent writers race.
        write_remote(artifact_key, artifact_bytes, kind: :artifact, template: name)
        write_remote(head_key, @renderer.encode_plan(plan), kind: :head, template: name)
        @renderer.store_local_head(head_key, plan)
        artifact = @renderer.store_local_artifact(
          artifact_key,
          template.to_compiled_artifact(artifact_bytes),
        )
        touch(head_key)
        touch(artifact_key)
        @stats[:compiles] += 1 if @collect_stats
        if @instrument
          emit("compile", template: name, duration: monotonic - started,
            artifact_bytes: artifact_bytes.bytesize, dependencies: dependencies.length)
        end
        artifact
      rescue SourceChanged
        expected_digest = @source.digest(name)
        if expected_digest
          head_key = @renderer.head_key(name, expected_digest, @vary, @source_snapshot)
        end
        retry if expected_digest && attempts < 3
        raise LiquidIL::Error, "template #{name.inspect} changed repeatedly while compiling"
      end
    end

    def normalize_dependencies(dependencies)
      return [] unless dependencies

      dependencies.map do |name, info|
        digest = @source.digest(name)
        {
          "name" => canonical_name(name),
          "digest" => digest,
          "disposition" => info.fetch(:disposition).to_s,
        }
      end.sort_by { |dep| dep.fetch("name") }
    end

    def compile_snapshot_valid?(name, root_digest, dependencies)
      return false unless @source.digest(name) == root_digest
      return true if @trust_source_snapshot

      dependencies.all? do |dep|
        digest = @source.digest(dep.fetch("name"))
        next false unless digest == dep.fetch("digest")

        external = @source.external?(dep.fetch("name"), digest)
        (dep.fetch("disposition") == "external") == external
      end
    end

    def ensure_preloaded!
      return if @preload_loaded
      @preload_loaded = true
      return unless @preload_key
      return if @renderer.max_preload_keys.zero?

      ensure_preload_manifest!
      keys = @preload_manifest_keys.reject { |key| @renderer.local_key_resident?(key) }
      @preloaded = @remote.read_multi(keys)
      @stats[:preload_keys] += @preloaded.size if @collect_stats
      if @instrument
        emit("cache.preload", key_count: keys.length, hit_count: @preloaded.size)
      end
    end

    def ensure_preload_manifest!
      return if @preload_manifest_loaded
      @preload_manifest_loaded = true
      return unless @preload_key

      bytes = read_remote(preload_storage_key, kind: :preload)
      @preload_manifest_keys = bytes ? @renderer.decode_preload(bytes) : EMPTY_ARRAY
    end

    def preload_storage_key
      @preload_storage_key ||= @renderer.preload_storage_key(@preload_key, @vary)
    end

    def cached_bytes(key)
      return [nil, nil] unless @preloaded.key?(key)

      [@preloaded[key], :preload]
    end

    def read_remote(key, kind:, template: nil)
      bytes = @remote.read(key)
      @stats[bytes ? :remote_hits : :remote_misses] += 1 if @collect_stats
      if @instrument
        emit("cache.lookup", tier: :remote, kind: kind, hit: !bytes.nil?, template: template)
      end
      bytes
    end

    def write_remote(key, bytes, kind:, template: nil)
      written = @remote.write(key, bytes)
      if @collect_stats
        @stats[written ? :remote_writes : :remote_write_failures] += 1
        @stats[:remote_bytes_written] += bytes.bytesize if written
      end
      if @instrument
        emit("cache.write", kind: kind, success: !!written, bytes: bytes.bytesize,
          template: template)
      end
      written
    end

    def lookup(tier, hit, template, kind: :template)
      return unless @collect_stats || @instrument

      @stats[:"#{tier}_#{hit ? 'hits' : 'misses'}"] += 1 if @collect_stats
      emit("cache.lookup", tier: tier, kind: kind, hit: hit, template: template) if @instrument
    end

    def touch(key)
      @touched << key if @touched
    end

    def emit(event, payload = {})
      return unless @instrument

      payload[:session_id] = object_id
      @renderer.instrument(event, payload)
    end

    def canonical_name(name)
      @source.canonical_name(name)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class SourceChanged < StandardError; end
  end

  # Binds a loaded artifact to its session's external-partial provider so an
  # individual #fetch remains safe to render directly.
  class SessionTemplate
    attr_reader :artifact

    def initialize(artifact, provider)
      @artifact = artifact
      @provider = provider
    end

    def render(assigns = {}, **options)
      @artifact.render(assigns, **options.merge(partial_provider: @provider))
    end

    def render!(assigns = {}, **options)
      render(assigns, **options.merge(render_errors: false))
    end

    def render_to_output_buffer(assigns = {}, output = +"", **options)
      @artifact.render_to_output_buffer(assigns, output,
        **options.merge(partial_provider: @provider))
    end

    # Execute this cached artifact against a host-owned Scope. The session's
    # provider is still installed so compile-time planned external partials
    # use the same request cache and source as the entry template.
    def render_scope(scope, output: nil)
      scope.partial_provider = @provider
      @artifact.render_scope(scope, output: output)
    end

    def render_scope!(scope, output: nil)
      scope.render_errors = false
      render_scope(scope, output: output)
    end
  end

  # Normalizes the named source/index protocol and doubles as the compiler's
  # file_system and partial_index.
  class TemplateSource
    def initialize(source, session)
      @source = source
      @session = session
      unless @source.respond_to?(:digest)
        raise ArgumentError, "templates must respond to #digest(name)"
      end
      unless @source.respond_to?(:read) || @source.respond_to?(:read_template_file)
        raise ArgumentError, "templates must respond to #read(name) or #read_template_file(name)"
      end
    end

    def canonical_name(name)
      value = @source.respond_to?(:canonical_name) ? @source.canonical_name(name) : name.to_s
      value = value.to_s
      raise ArgumentError, "template name contains a NUL byte" if value.include?("\0")
      value
    end

    def digest(name)
      name = canonical_name(name)
      @session.source_lookup(name, :digest)
      value = @source.digest(name)
      value&.to_s
    end

    def bytesize(name)
      name = canonical_name(name)
      @session.source_lookup(name, :bytesize)
      @source.respond_to?(:bytesize) ? @source.bytesize(name) : nil
    end

    def read(name)
      name = canonical_name(name)
      @session.source_lookup(name, :read)
      if @source.respond_to?(:read)
        @source.read(name)
      else
        begin
          @source.read_template_file(name)
        rescue ArgumentError
          @source.read_template_file(name, nil)
        end
      end
    end
    alias read_template_file read

    def external?(name, known_digest = nil)
      name = canonical_name(name)
      return false if known_digest.nil? && digest(name).nil?
      if @source.respond_to?(:external?)
        !!@source.external?(name)
      elsif @source.respond_to?(:inline?)
        !@source.inline?(name)
      elsif @source.respond_to?(:bytesize)
        size = bytesize(name)
        size.nil? || size > RubyCompiler::PartialEmitter::INLINE_BODY_MAX_BYTES
      else
        true
      end
    end

    def inline?(name)
      !external?(name, digest(name))
    end
  end
end
