# frozen_string_literal: true

module Fuzz
  # Structural shrinker (goal 02 doc, "Shrinker"). Operates directly on the
  # generator's AST + environment/filesystem Hashes -- never on template
  # text -- because dropping a child node and re-rendering is both more
  # effective and much cheaper than any textual minimization.
  #
  # The whole (ast, environment, filesystem) tree is treated generically:
  # every Array is a ddmin target (drop elements), every Hash is a ddmin
  # target over its key/value pairs (drop whole entries), and every
  # surviving child is recursed into -- so shrinking "unwraps" an `if`'s
  # branches, drops filter args, drops unnecessary loop nesting, drops
  # unused env keys / array elements, and drops whole unused partials, all
  # through the same mechanism. A candidate is only kept when re-rendering
  # both engines through the oracle still reproduces the finding, so the
  # result is always still a genuine repro -- just a smaller one.
  module Shrink
    MAX_PASSES = 6

    # `fails` is called with a candidate Case and must return true iff it
    # still reproduces the divergence (same overall verdict shape as when
    # shrinking started -- callers typically check `verdict.status ==
    # :finding` or `:hang`, not signature equality, since minimization
    # legitimately changes surface details like line numbers).
    def self.minimize(kase, &fails)
      ast, env, fs = kase.ast, kase.environment, kase.filesystem
      # Each of the three top-level parts is reduced against its OWN root
      # (never wrapped together) -- wrapping them in one shared Array/Hash
      # would let ddmin drop an entire part (e.g. the whole environment) as
      # just another "element", which breaks Case#with's fixed shape.
      MAX_PASSES.times do
        new_ast = reduce_in_place(ast) { |cand| fails.call(kase.with(ast: cand, environment: env, filesystem: fs)) }
        new_env = reduce_in_place(env) { |cand| fails.call(kase.with(ast: new_ast, environment: cand, filesystem: fs)) }
        new_fs = reduce_in_place(fs) { |cand| fails.call(kase.with(ast: new_ast, environment: new_env, filesystem: cand)) }
        break if new_ast == ast && new_env == env && new_fs == fs

        ast, env, fs = new_ast, new_env, new_fs
      end
      kase.with(ast: ast, environment: env, filesystem: fs)
    end

    # `test` verifies the FULL root with `value` substituted at this
    # position -- passed down as a closure so every candidate, at any
    # depth, is checked against the whole tree, never in isolation.
    def self.reduce_in_place(value, &test)
      case value
      when Array
        reduced = ddmin(value) { |cand| safe_call(cand, &test) }
        reduced.each_index do |i|
          reduced[i] = reduce_in_place(reduced[i]) do |child|
            candidate = reduced.dup
            candidate[i] = child
            test.call(candidate)
          end
        end
        reduced
      when Hash
        pairs = value.to_a
        reduced_pairs = ddmin(pairs) { |cand| safe_call(cand.to_h, &test) }
        reduced = reduced_pairs.to_h
        reduced.each_key do |k|
          reduced[k] = reduce_in_place(reduced[k]) do |child|
            candidate = reduced.dup
            candidate[k] = child
            test.call(candidate)
          end
        end
        reduced
      else
        value
      end
    end

    def self.safe_call(candidate, &test)
      test.call(candidate)
    rescue StandardError, ScriptError
      false
    end

    # Classic delta-debugging ddmin: shrinks `list` to a locally-minimal
    # sublist such that `ok.call(sublist)` still holds, by trying to remove
    # ever-smaller chunks. `ok.call(list)` is assumed true on entry (the
    # caller only shrinks things that currently still reproduce).
    def self.ddmin(list, &ok)
      list = list.dup
      return list if list.empty?

      n = 2
      loop do
        chunk_size = (list.length / n.to_f).ceil
        break if chunk_size < 1

        removed = false
        start = 0
        while start < list.length
          stop = [start + chunk_size, list.length].min
          complement = list[0...start] + list[stop...list.length]
          if complement.length < list.length && ok.call(complement)
            list = complement
            n = [n - 1, 2].max
            removed = true
            break
          end
          start += chunk_size
        end
        next if removed
        break if n >= list.length

        n = [n * 2, list.length].min
      end
      list
    end
  end
end
