# frozen_string_literal: true

require "yaml"
require "digest/sha1"
require "fileutils"

module Fuzz
  # Minimized-divergence signature + liquid-spec-format YAML writer (goal 02
  # doc, "Shrinker" step 4: dedupe by (first divergent construct kind,
  # error class / first-divergence context) -- without dedupe, one bug
  # produces thousands of raw case "findings").
  module Finding
    def self.signature(kase, ref, lil, rule)
      return "#{rule}::hang:#{ref[:hang] ? "ref" : "lil"}" if ref[:hang] || lil[:hang]

      # Dedupe by the SHAPE of the divergence, not by where in the template
      # it happened or what surrounds it -- the same root cause recurs
      # under wildly different generated ASTs (e.g. a `to_s` bug fires
      # identically regardless of what statement precedes it), so neither
      # "top-level AST node types" nor "text preceding the diff" are stable
      # keys. Using the diverging CONTENT itself is.
      case rule
      when :parse_disagreement
        "#{rule}::#{parse_disagreement_reason(ref[:message])}"
      when :runtime_error_mismatch, :ok_mismatch
        "#{rule}::#{ref[:error_class]}|#{lil[:error_class]}"
      else
        # One systemic root cause -- LiquidIL always prefixes embedded
        # runtime-error text with "(line N)"; reference omits it for some
        # error paths (e.g. filter arity errors, numeric coercion errors)
        # -- otherwise fragments into one finding file per filter/construct
        # it happens to surface under, since structural_key legitimately
        # treats different filters/constructs as different bugs. Caught
        # BEFORE the structural fallback so all instances collapse to one.
        return "#{rule}::line_number_prefix_format" if line_number_prefix_only_diff?(ref[:output], lil[:output])

        # The minimized template's STRUCTURAL shape (node types/operators,
        # with literal payloads collapsed to their Ruby class) -- one bug
        # (e.g. "cycle drops a falsy value") shrinks to near-identical ASTs
        # across many different original literal payloads; deduping by
        # exact output content alone would record one finding file per
        # distinct payload for what is really a single root cause.
        "#{rule}::#{structural_key(kase.ast).inspect}"
      end
    end

    # Collapses identifier-ish strings (variable/partial/arg names -- pure
    # generator entropy) to a placeholder while preserving node :type,
    # comparison/logical :op, and filter :name (the actual filter identity,
    # not entropy) so two cases hitting the same bug with different random
    # variable names still produce the same key.
    def self.structural_key(node)
      case node
      when Hash
        node.map do |k, v|
          if k == :value
            [k, v.class.name]
          elsif v.is_a?(String) && k != :op && !(k == :name && node[:type] == :filter)
            [k, "id"]
          else
            [k, structural_key(v)]
          end
        end.to_h
      when Array
        node.map { |n| structural_key(n) }
      else
        node
      end
    end

    LINE_PREFIX_RE = /\s?\([^()]*?line \d+\)/

    def self.line_number_prefix_only_diff?(ref_output, lil_output)
      return false unless ref_output.is_a?(String) && lil_output.is_a?(String)
      return false if ref_output == lil_output

      ref_output.gsub(LINE_PREFIX_RE, "") == lil_output.gsub(LINE_PREFIX_RE, "")
    end

    def self.parse_disagreement_reason(message)
      msg = message.to_s
      case msg
      when /was not properly terminated/ then "unterminated_tag_markup"
      when /Expected end_of_string but found (\w+)/ then "unexpected_#{Regexp.last_match(1)}"
      when /Unexpected character/ then "unexpected_character"
      when /tag .* was never closed|never closed/ then "unclosed_block_tag"
      else msg[0, 40]
      end
    end

    def self.digest(signature)
      Digest::SHA1.hexdigest(signature)[0, 12]
    end

    # True if a finding with this signature is already recorded on disk --
    # used by `rake fuzz` to decide whether a mismatch is "new" (and should
    # fail the build) or already-known/accepted debt.
    def self.known?(dir, signature)
      File.exist?(File.join(dir, "#{digest(signature)}.yml"))
    end

    def self.write!(dir, kase, ref, lil, rule:, signature:, note: nil, subprocess_confirmed: nil)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{digest(signature)}.yml")
      data = {
        "name" => "fuzz_#{digest(signature)}",
        "_metadata" => {
          "doc" => "fuzz/README or goal 02 doc (.goals/02-differential-fuzzer.md)",
          "hint" => note || "Minimized by fuzz/lib/shrink.rb from seed #{kase.seed}. Rule: #{rule}.",
          "signature" => signature,
          "seed" => kase.seed,
          "subprocess_confirmed" => subprocess_confirmed,
        }.compact,
        "template" => kase.template_src,
        "environment" => kase.environment,
        "expected" => ref[:output],
        "complexity" => 100,
      }
      data["filesystem"] = kase.filesystem unless kase.filesystem.empty?
      data["error_mode"] = kase.error_mode.to_s unless kase.error_mode == :strict
      data["_liquidil_actual"] = lil[:output] if lil[:ok]
      data["_liquidil_error"] = "#{lil[:error_class]}: #{lil[:message]}" unless lil[:ok]
      data["_reference_error"] = "#{ref[:error_class]}: #{ref[:message]}" unless ref[:ok]
      File.write(path, "# Differential fuzzer finding -- see .goals/02-differential-fuzzer.md\n" + YAML.dump(data))
      path
    end
  end
end
