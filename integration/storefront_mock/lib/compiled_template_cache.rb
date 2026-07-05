# frozen_string_literal: true

require "digest"

module StorefrontMock
  # File system handed to the LiquidIL compiler. Reads partial bodies from the
  # theme (counting each fetch) and records the set of partials it inlined.
  # That recorded set is the entry artifact's dependency list — the mock's
  # stand-in for the storefront's `partial_cache_deps` tracking. Its digests are
  # folded into the cache key (composite key), so a partial-body edit changes
  # the key at EVERY tier.
  #
  # TODO(external-partials branch): when the compiler accepts a digest index +
  # PartialProvider (name -> content_digest at compile time, callable at render
  # time), the census would split partials into INLINE (fetched here, folded
  # into the composite key) vs EXTERNAL (never fetched here — a provider call
  # site emitted, the partial its own per-file artifact loaded lazily and warmed
  # by the fingerprint preloader). This recorder is the inline half of that split.
  class RecordingFileSystem
    def initialize(theme)
      @theme = theme
      @inlined = {}
    end

    # Names of the partials inlined into the entry, sorted for determinism.
    def inlined_names
      @inlined.keys.sort
    end

    def read_template_file(name, _context = nil)
      digest = @theme.digest_for(name) or
        raise LiquidIL::Error, "partial #{name.inspect} not in theme #{@theme.id}"
      @inlined[name] = digest
      @theme.load_body(digest) # counts a body fetch on the shared store
    end
  end

  # Reference-liquid file system for the control engine (no digest tracking —
  # the reference gem has no compiled cache).
  class RubyThemeFileSystem
    def initialize(theme)
      @theme = theme
    end

    def read_template_file(name, *)
      @theme.load_named(name)
    end
  end

  # Coder for the LiquidIL engine. The cache VALUE is the framed artifact itself
  # (Artifact.encode/decode); invalidation lives entirely in the composite cache
  # KEY (entry digest + sorted inlined-partial digests), so no separate deps
  # sidecar/validation is needed. RUBY_VERSION+platform are folded into the key
  # by CompiledTemplateCache (ISeq binaries are not portable across Ruby versions).
  class LiquidIlCoder
    SLUG = "liquid-il"
    FORMAT_EPOCH = 1
    # Codegen/pack version analog (GLOBAL_BUST + PACK_DIGEST). A codegen change
    # bumps LiquidIL::Artifact::VERSION and busts every key.
    FORMAT_DIGEST = Digest::SHA1.hexdigest("liquid-il-codegen/#{LiquidIL::Artifact::VERSION}")[0, 12]

    def cacheable? = true
    def slug = SLUG
    def format_epoch = FORMAT_EPOCH
    def format_digest = FORMAT_DIGEST

    # Entry body digest — from assets_by_name metadata, NO body fetch.
    def entry_digest(ref)
      ref.theme.digest_for(ref.name) or
        raise LiquidIL::Error, "unknown entry #{ref.name.inspect} in theme #{ref.theme.id}"
    end

    # Composite content digest = entry digest + the current digests of every
    # inlined partial (all from metadata, no body fetch). Cross-shop-stable:
    # identical entry + identical partial bodies -> identical key.
    def composite_digest(entry_digest, ref, inlined_names)
      pairs = inlined_names.sort.map { |name| [name, ref.theme.digest_for(name)] }
      Digest::SHA1.hexdigest("#{entry_digest}|#{pairs.inspect}")[0, 16]
    end

    def vary_key(parse_options)
      normalized = parse_options.to_a.sort_by { |k, _| k.to_s }.inspect
      Digest::SHA1.hexdigest(normalized)[0, 8]
    end

    # Returns [artifact_bytes, inlined_names]. artifact_bytes is BOTH the KV
    # value and the live-proc blob.
    def compile(ref, parse_options)
      body = ref.theme.load_named(ref.name) # counts the entry body fetch
      fs = RecordingFileSystem.new(ref.theme)
      ctx = LiquidIL::Context.new(file_system: fs, error_mode: parse_options[:error_mode] || :lax)
      template = ctx.parse(body)
      [template.to_artifact, fs.inlined_names]
    end

    def load(artifact_bytes)
      LiquidIL.load_artifact(artifact_bytes)
    end
  end

  # Coder for the reference `liquid` gem control engine: no compiled caching —
  # parse each time. The honest comparison (the reference gem ships no cache).
  class LiquidRubyCoder
    SLUG = "liquid-ruby"

    def cacheable? = false
    def slug = SLUG

    def compile_uncached(ref, _parse_options)
      fs = RubyThemeFileSystem.new(ref.theme)
      env = Liquid::Environment.build(file_system: fs)
      body = ref.theme.load_named(ref.name)
      Liquid::Template.parse(body, environment: env)
    end
  end

  # The generalized bytecode-cache, engine-parameterized by a coder. Key:
  #
  #   {slug}:{format_epoch}:{format_digest}:{RUBY_VERSION}-{RUBY_PLATFORM}:{composite_digest}:{vary_key}
  #
  # Request-scoped layers, in order: preloaded (previous request's fingerprint,
  # one batch read_multi, capped) -> memoized -> tiered store -> compile. A
  # process-global live-proc tier (LiquidIL::TemplateCache) sits ABOVE them so a
  # hot template renders from a resident proc with zero KV traffic.
  #
  # The composite key needs the inlined-partial set, which is a pure function of
  # the entry body. That set is stored as a tiny "manifest" (partial names) and
  # memoized process-globally by entry digest, so a hot request computes the key
  # and serves the live proc without any KV read.
  class CompiledTemplateCache
    MAX_PRELOAD_KEYS = 256

    def initialize(coder:, store:, live: nil)
      @coder = coder
      @store = store
      @live = live
      @manifest_memo = {} # entry_digest -> [partial names] (process-global, stable)
      reset_request!
    end

    attr_reader :coder

    def begin_request(fingerprint_key = nil)
      reset_request!
      @fingerprint_key = fingerprint_key
      return unless fingerprint_key && @coder.cacheable?

      raw = @store.get(fingerprint_storage_key(fingerprint_key))
      return unless raw

      keys = Marshal.load(raw).first(MAX_PRELOAD_KEYS)
      @preloaded = @store.read_multi(keys) unless keys.empty?
    end

    def end_request
      if @fingerprint_key && @coder.cacheable?
        @store.set(fingerprint_storage_key(@fingerprint_key), Marshal.dump(@touched_keys.uniq))
      end
      @events
    end

    def last_events
      @events
    end

    def fetch(ref, parse_options = {})
      unless @coder.cacheable?
        @events[:parse] += 1
        return @coder.compile_uncached(ref, parse_options)
      end

      entry_digest = @coder.entry_digest(ref)
      vary = @coder.vary_key(parse_options)
      names = manifest_names(entry_digest)

      if names
        key = build_key(@coder.composite_digest(entry_digest, ref, names), vary)
        @touched_keys << key
        return @live.fetch(key) { resolve_blob(key, ref, parse_options, entry_digest, vary) } if @live

        return @coder.load(resolve_blob(key, ref, parse_options, entry_digest, vary))
      end

      # Manifest unknown -> compile to discover the inlined-partial set.
      key, blob = compile_and_store(ref, parse_options, entry_digest, vary)
      @touched_keys << key
      return @live.fetch(key, blob) if @live

      @coder.load(blob)
    end

    private

    def reset_request!
      @memoized = {}
      @preloaded = {}
      @touched_keys = []
      @events = Hash.new(0)
      @fingerprint_key = nil
    end

    # The inlined-partial name set for an entry: process memo -> store manifest.
    def manifest_names(entry_digest)
      return @manifest_memo[entry_digest] if @manifest_memo.key?(entry_digest)

      mkey = manifest_key(entry_digest)
      raw = read_layered(mkey)
      @touched_keys << mkey
      return nil unless raw

      names = Marshal.load(raw)
      @manifest_memo[entry_digest] = names
      names
    end

    # Return the framed artifact bytes for a known composite key: layered read,
    # else compile. A composite-key miss means a partial changed (its digest is
    # in the key) or first sight — either way, recompile exactly this unit.
    def resolve_blob(key, ref, parse_options, entry_digest, vary)
      stored = read_layered(key)
      if stored
        @events[:store_hit] += 1
        return stored
      end

      @events[:stale] += 1 if @manifest_memo.key?(entry_digest)
      _key, blob = compile_and_store(ref, parse_options, entry_digest, vary)
      blob
    end

    # Compile, persist the manifest (stable per entry) and the artifact (under
    # the composite key), and return [key, artifact_bytes].
    def compile_and_store(ref, parse_options, entry_digest, vary)
      @events[:compile] += 1
      blob, inlined_names = @coder.compile(ref, parse_options)
      names = inlined_names.sort

      if @manifest_memo[entry_digest] != names
        mkey = manifest_key(entry_digest)
        @store.set(mkey, Marshal.dump(names))
        @memoized[mkey] = Marshal.dump(names)
        @touched_keys << mkey
      end
      @manifest_memo[entry_digest] = names

      key = build_key(@coder.composite_digest(entry_digest, ref, names), vary)
      @store.set(key, blob)
      @memoized[key] = blob
      [key, blob]
    end

    def read_layered(key)
      return @memoized[key] if @memoized.key?(key)

      if @preloaded.key?(key)
        value = @preloaded[key]
        @memoized[key] = value
        return value
      end

      value = @store.get(key)
      @memoized[key] = value if value
      value
    end

    def build_key(content_digest, vary_key)
      "#{@coder.slug}:#{@coder.format_epoch}:#{@coder.format_digest}:" \
        "#{RUBY_VERSION}-#{RUBY_PLATFORM}:#{content_digest}:#{vary_key}"
    end

    def manifest_key(entry_digest)
      "man:#{@coder.slug}:#{@coder.format_epoch}:#{entry_digest}"
    end

    def fingerprint_storage_key(fingerprint_key)
      "fpx:#{@coder.slug}:#{fingerprint_key}"
    end
  end
end
