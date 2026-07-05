# frozen_string_literal: true

require "digest"

module StorefrontMock
  # File system handed to the LiquidIL compiler — the INLINE half of the census.
  # Reads the bodies of the SMALL partials the compiler decides to inline (a
  # `partial_index` externalizes the large ones without ever calling here). Every
  # fetch is counted; the inlined set is the entry artifact's inline-dependency
  # list — its digests fold into the composite cache key, so a small-partial edit
  # changes the key at EVERY tier. Large/EXTERNAL partials are never fetched here
  # (see ThemePartialIndex + PartialProvider): they become their own per-file
  # artifacts, loaded lazily at render and warmed by the fingerprint preloader.
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

  # The EXTERNAL half of the census: the LiquidIL `partial_index`. It answers,
  # from theme metadata alone (NO body fetch), which partials exist (digest) and
  # how big they are (bytesize). The compiler's default policy inlines partials
  # whose body is <= RubyCompiler::INLINE_BODY_MAX_BYTES and EXTERNALIZES the
  # larger ones — the exact "small snippets inline, big sections version on their
  # own" split the storefront wants. A name the index does not know (digest nil)
  # is not externalized: it falls through to the file_system path unchanged.
  class ThemePartialIndex
    def initialize(theme)
      @theme = theme
    end

    def digest(name)
      @theme.digest_for(name)
    end

    def bytesize(name)
      @theme.bytesize_for(name)
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
    # value and the live-proc blob. The `partial_index` is built from theme
    # metadata (name -> digest/bytesize, NO body fetch), so the compiler splits
    # partials into INLINE (small — body fetched via RecordingFileSystem, folded
    # into the composite key) and EXTERNAL (large — never fetched here; a
    # provider call site is emitted). Only the INLINE digests belong in the
    # composite key; external partials version independently as their own
    # per-file artifacts (see #compile_partial / CompiledTemplateCache).
    def compile(ref, parse_options)
      body = ref.theme.load_named(ref.name) # counts the entry body fetch
      fs = RecordingFileSystem.new(ref.theme)
      index = ThemePartialIndex.new(ref.theme)
      ctx = LiquidIL::Context.new(file_system: fs, partial_index: index,
                                  error_mode: parse_options[:error_mode] || :lax)
      template = ctx.parse(body)
      [template.to_artifact, inlined_names(template)]
    end

    # The set of partials baked INTO this entry artifact (inline + shared
    # lambda) — the digests that belong in the composite key. Read from
    # Template#partial_dependencies, the compiler's authoritative disposition
    # record; external partials are deliberately excluded (they are not in the
    # key — that is what lets them version on their own).
    def inlined_names(template)
      deps = template.partial_dependencies
      return [] unless deps
      deps.reject { |_name, info| info[:disposition] == :external }.keys.sort
    end

    # Current digest of an external partial, from theme metadata — NO body
    # fetch. This is the identity the provider keys its per-file artifact on, so
    # a partial edit (new digest -> new key) is picked up at render time WITHOUT
    # touching the entry artifact or its composite key.
    def partial_digest(theme, name)
      theme.digest_for(name)
    end

    # Compile ONE external partial into its own per-file artifact (fetching its
    # body — the lazy cost paid only when its call site actually runs). Uses the
    # same index so a nested large partial would externalize too.
    def compile_partial(theme, name, parse_options)
      body = theme.load_named(name) # counts the (lazy) body fetch
      fs = RecordingFileSystem.new(theme)
      index = ThemePartialIndex.new(theme)
      ctx = LiquidIL::Context.new(file_system: fs, partial_index: index,
                                  error_mode: parse_options[:error_mode] || :lax)
      ctx.parse(body).to_artifact
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

    # Build the request's PartialProvider: a `->(name, digest) -> artifact`
    # resolving external partials through the SAME tier stack as entries
    # (live-proc -> preloaded -> memoized -> tiered KV -> compile-on-miss). It is
    # called ONLY when an external `{% render/include %}` site actually executes,
    # so a partial behind a dead branch is never asked for and never fetched. The
    # keys it touches join @touched_keys, so the fingerprint warms entry AND its
    # external partials in one read_multi next request. Returns nil for engines
    # that do not compile per-file partials (the reference control engine).
    def partial_provider(ref, parse_options = {})
      return nil unless @coder.cacheable? && @coder.respond_to?(:compile_partial)

      vary = @coder.vary_key(parse_options)
      lambda do |name, _baked_digest|
        # Resolve against the CURRENT theme metadata, not the digest baked into
        # the caller at entry-compile time: external partials version on their
        # own, so an edited body is picked up here even though the entry artifact
        # (and its composite key) is unchanged.
        digest = @coder.partial_digest(ref.theme, name)
        next nil unless digest

        key = build_key(digest, vary)
        @touched_keys << key
        if @live
          @live.fetch(key) { resolve_partial_blob(key, ref.theme, name, parse_options) }
        else
          @coder.load(resolve_partial_blob(key, ref.theme, name, parse_options))
        end
      end
    end

    private

    # Framed bytes for one external partial's per-file artifact: layered read,
    # else compile-on-miss (fetch body, compile, write back to KV). A key miss
    # means first sight or an edited body (its digest is in the key) — recompile
    # exactly this partial, nothing else.
    def resolve_partial_blob(key, theme, name, parse_options)
      stored = read_layered(key)
      if stored
        @events[:partial_store_hit] += 1
        return stored
      end

      @events[:partial_compile] += 1
      blob = @coder.compile_partial(theme, name, parse_options)
      @store.set(key, blob)
      @memoized[key] = blob
      blob
    end

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
