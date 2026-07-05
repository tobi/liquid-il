#!/usr/bin/env ruby
# frozen_string_literal: true

# Differential fuzzer entrypoint -- see .goals/02-differential-fuzzer.md.
#
#   bundle exec ruby fuzz/run.rb              # rake fuzz:  60s or 2000 cases
#   TIME=600 CASES=100000 bundle exec ruby fuzz/run.rb   # rake fuzz:long
#   SEED=12345 bundle exec ruby fuzz/run.rb   # reproduce a specific run
#
# Exits nonzero iff a NEW unique finding was recorded this run (gates CI --
# already-known findings under fuzz/findings/ are accepted debt and do not
# fail subsequent runs; see fuzz/lib/finding.rb#known?).

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "liquid_il"
require "liquid"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "runner"

time_budget = (ENV["TIME"] || 60).to_i
case_budget = (ENV["CASES"] || 2000).to_i
seed = ENV["SEED"]&.to_i

puts "Differential fuzzer: LiquidIL vs reference liquid (in-process, subprocess-confirmed on mismatch)"
puts "budget: #{time_budget}s / #{case_budget} cases  seed=#{seed || "(random -- printed below)"}"

runner = Fuzz::Runner.new(seed: seed, time_budget: time_budget, case_budget: case_budget)
report = runner.run

puts
puts report.summary
puts "rule_counts=#{report.rule_counts}" unless report.rule_counts.empty?
if report.new_findings.any?
  puts
  puts "NEW findings this run (see fuzz/findings/):"
  report.new_findings.each { |sig| puts "  #{sig}" }
end

exit(report.new_findings.empty? ? 0 : 1)
