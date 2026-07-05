#!/usr/bin/env ruby
# frozen_string_literal: true

# Clean-subprocess reference confirmation (goal 02 doc, "SUBPROCESS
# CONFIRMATION", off the hot path -- only invoked once per candidate
# mismatch, never in the main fuzz loop).
#
# This process NEVER requires "liquid_il" -- it is the control that proves
# a recorded finding isn't an artifact of LiquidIL's core_ext.rb monkeypatches
# coexisting with reference liquid in one process. If this process's output
# ever disagrees with the in-process reference render for the same case,
# that is itself a distinct, important finding about core_ext (see
# fuzz/findings/core_ext/) -- not evidence about LiquidIL's engine at all.
#
# Usage: bundle exec ruby -Ilib -Ifuzz/lib fuzz/ref_check.rb < case.json
# Reads one JSON object {template:, environment:, filesystem:, error_mode:}
# from STDIN, writes one JSON result {ok:, output:|error_class:,message:,
# syntax_error:,hang:} to STDOUT.

require "json"
require "liquid"
require_relative "lib/case"
require_relative "lib/engines"

payload = JSON.parse($stdin.read)
kase = Fuzz::Case.literal(
  seed: payload["seed"],
  template_src: payload["template"],
  environment: payload["environment"] || {},
  filesystem: payload["filesystem"] || {},
  error_mode: (payload["error_mode"] || "strict").to_sym,
)

result = Fuzz::ReferenceEngine.render(kase)
puts JSON.generate(result.reject { |_, v| v.nil? })
