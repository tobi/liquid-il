# frozen_string_literal: true

require "digest"

module StorefrontMock
  # Content-addressed body store, SHARED across themes ("shops"). Mirrors the
  # storefront's `theme_template_bodies` (cache_by_shop_id: false): the same
  # body bytes have the same digest regardless of which shop references them,
  # so one hot theme-store snippet is ONE stored body serving thousands of
  # shops. `load_body` is the ONLY path that materializes a body and it counts
  # every fetch, so laziness can be asserted.
  #
  # Digest is a content-hash stand-in: a SHA1 prefix (fast, stable, collision-safe
  # enough for a mock).
  class BodyStore
    def initialize
      @by_digest = {}
      @fetches = []
    end

    attr_reader :fetches

    def self.digest(body)
      Digest::SHA1.hexdigest(body)[0, 16]
    end

    # Store a body, returning its content digest. Idempotent for equal bodies
    # (content addressing) — that is exactly what makes cross-shop sharing work.
    def put(body)
      digest = self.class.digest(body)
      @by_digest[digest] = body
      digest
    end

    def load_body(digest)
      @fetches << digest
      @by_digest.fetch(digest) { raise KeyError, "no body for digest #{digest.inspect}" }
    end

    def fetch_count
      @fetches.length
    end

    def reset_fetches!
      @fetches = []
    end
  end

  # A theme: metadata (asset name -> content digest) plus a handle on the
  # shared BodyStore. `assets_by_name` is available WITHOUT any body fetch
  # (mirrors Theme#assets_by_name, preloaded per theme per request). Editing an
  # asset re-hashes only that body; unrelated assets keep their digests.
  class MockTheme
    attr_reader :id, :bodies

    def initialize(id, bodies)
      @id = id
      @bodies = bodies
      @names_to_digest = {}
      @names_to_bytesize = {}
    end

    # Register/replace an asset body; returns its (new) digest. The byte size is
    # recorded alongside the digest — both are metadata a real theme carries at
    # publish time (Theme#assets_by_name, asset content_length), so the
    # inline-vs-external census can SIZE a partial without fetching its body.
    def set_asset(name, body)
      @names_to_bytesize[name] = body.bytesize
      @names_to_digest[name] = @bodies.put(body)
    end

    # Metadata index — name -> digest — with NO body materialization.
    def assets_by_name
      @names_to_digest.dup
    end

    def digest_for(name)
      @names_to_digest[name]
    end

    # Byte size of an asset from metadata — NO body fetch. Feeds the census's
    # size threshold (small -> inline, large -> external per-file artifact).
    def bytesize_for(name)
      @names_to_bytesize[name]
    end

    def asset?(name)
      @names_to_digest.key?(name)
    end

    # Fetch a body by digest (counts a fetch on the shared store).
    def load_body(digest)
      @bodies.load_body(digest)
    end

    # Fetch a body by asset name (counts a fetch).
    def load_named(name)
      digest = digest_for(name) or raise KeyError, "theme #{id} has no asset #{name.inspect}"
      load_body(digest)
    end
  end

  # A parse target: a theme + the entry asset name. This is the `template_obj`
  # the AdapterInterface#parse contract receives.
  EntryRef = Struct.new(:theme, :name) do
    def content_digest
      theme.digest_for(name)
    end
  end
end
