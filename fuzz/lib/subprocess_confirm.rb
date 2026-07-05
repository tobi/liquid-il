# frozen_string_literal: true

require "open3"
require "json"

module Fuzz
  # Off-the-hot-path clean-subprocess confirmation (goal 02 doc). Spawns a
  # `bundle exec ruby` process that never requires "liquid_il" and re-renders
  # just the one candidate mismatch through reference liquid there. Its
  # output is the ground truth used in the recorded finding -- guaranteeing
  # no finding is an artifact of in-process coexistence (see fuzz/ref_check.rb).
  module SubprocessConfirm
    FUZZ_ROOT = File.expand_path("..", __dir__)

    # Returns [subprocess_result, agrees_with_inprocess_ref (bool or nil)].
    def self.confirm(kase, inprocess_ref)
      payload = {
        seed: kase.seed,
        template: kase.template_src,
        environment: kase.environment,
        filesystem: kase.filesystem,
        error_mode: kase.error_mode.to_s,
      }
      stdout, stderr, status = Open3.capture3(
        { "RUBY_YJIT_ENABLE" => "0" },
        "bundle", "exec", "ruby", File.join(FUZZ_ROOT, "ref_check.rb"),
        stdin_data: JSON.generate(payload),
        chdir: FUZZ_ROOT,
      )
      unless status.success?
        return [{ ok: false, error_class: "SubprocessError", message: stderr[0, 500] }, nil]
      end

      result = JSON.parse(stdout.lines.last.to_s, symbolize_names: true)
      agrees = result[:ok] == inprocess_ref[:ok] &&
        (!result[:ok] || result[:output] == inprocess_ref[:output]) &&
        !!result[:syntax_error] == !!inprocess_ref[:syntax_error]
      [result, agrees]
    rescue JSON::ParserError => e
      [{ ok: false, error_class: "SubprocessParseError", message: "#{e.message}: #{stdout}" }, nil]
    end
  end
end
