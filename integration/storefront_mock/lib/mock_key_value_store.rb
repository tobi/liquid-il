# frozen_string_literal: true

module StorefrontMock
  # Hash-backed key/value store with get/set/read_multi and hit/miss/read/write
  # counters. Two of these get composed into a TieredStore below (node_local ->
  # remote), mirroring the host renderer's two-tier (node-local + remote) memcached stack.
  class MockKeyValueStore
    attr_reader :name, :hits, :misses, :reads, :writes, :read_multi_calls

    def initialize(name)
      @name = name
      @data = {}
      reset_stats!
    end

    def get(key)
      @reads += 1
      if @data.key?(key)
        @hits += 1
        @data[key]
      else
        @misses += 1
        nil
      end
    end

    def set(key, value)
      @writes += 1
      @data[key] = value
    end

    # Batch fetch — the fingerprint preloader's primitive. Missing keys are
    # simply absent from the result hash. Counts BATCHES (not per-key reads) so
    # a test can prove the whole fingerprint warms in ONE round trip.
    def read_multi(keys)
      @read_multi_calls += 1
      out = {}
      keys.each do |k|
        @reads += 1
        if @data.key?(k)
          @hits += 1
          out[k] = @data[k]
        else
          @misses += 1
        end
      end
      out
    end

    def key?(key)
      @data.key?(key)
    end

    def reset_stats!
      @hits = 0
      @misses = 0
      @reads = 0
      @writes = 0
      @read_multi_calls = 0
    end

    def stats
      { name: @name, reads: @reads, writes: @writes, hits: @hits, misses: @misses }
    end
  end

  # Two KV instances composed as tiers, like the production node-local daemon
  # in front of the remote memcached cluster. Reads try node_local first and
  # backfill it from remote on a miss; writes fan out to both tiers.
  class TieredStore
    attr_reader :node_local, :remote

    def initialize(node_local, remote)
      @node_local = node_local
      @remote = remote
    end

    def get(key)
      v = @node_local.get(key)
      return v unless v.nil?

      v = @remote.get(key)
      @node_local.set(key, v) unless v.nil?
      v
    end

    def set(key, value)
      @node_local.set(key, value)
      @remote.set(key, value)
    end

    def read_multi(keys)
      out = @node_local.read_multi(keys)
      missing = keys - out.keys
      unless missing.empty?
        remote = @remote.read_multi(missing)
        remote.each do |k, v|
          @node_local.set(k, v)
          out[k] = v
        end
      end
      out
    end

    def total_reads
      @node_local.reads + @remote.reads
    end

    def reset_stats!
      @node_local.reset_stats!
      @remote.reset_stats!
    end
  end
end
