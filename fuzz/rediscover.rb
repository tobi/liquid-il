#!/usr/bin/env ruby
# frozen_string_literal: true

# Rediscovery verification (goal 02 doc, "Verification"): check out commit
# 2ab67c7 (the last commit before the self[...]-in-nested-loops fix) into a
# git worktree, point a subprocess's $LOAD_PATH at ITS lib/ instead of this
# repo's, and confirm the fuzzer -- oracle, shrinker, subprocess-confirm,
# finding writer, all unmodified -- rediscovers the bug within a small
# budget. See fuzz/rediscover_inner.rb for what actually runs and why it
# uses a targeted (not uniform-random) generator for this specific check.
#
# Usage: bundle exec ruby fuzz/rediscover.rb   (rake fuzz:rediscover)

require "fileutils"

FUZZ_ROOT = File.expand_path(__dir__)
REPO_ROOT = File.expand_path("..", FUZZ_ROOT)
COMMIT = "2ab67c7"
WORKTREE_PATH = "/tmp/liquidil-fuzz-#{COMMIT}"
FINDINGS_DIR = File.join(REPO_ROOT, "tmp", "fuzz_rediscovery_#{COMMIT}")

def sh!(*cmd)
  puts cmd.join(" ")
  system(*cmd) || abort("command failed: #{cmd.join(" ")}")
end

unless File.directory?(File.join(WORKTREE_PATH, ".git")) || File.exist?(File.join(WORKTREE_PATH, ".git"))
  puts "Creating worktree for #{COMMIT} at #{WORKTREE_PATH}..."
  sh!("git", "-C", REPO_ROOT, "worktree", "add", "--detach", WORKTREE_PATH, COMMIT)
end
old_lib = File.join(WORKTREE_PATH, "lib")
abort "worktree lib/ not found at #{old_lib}" unless File.directory?(old_lib)

FileUtils.rm_rf(FINDINGS_DIR)
FileUtils.mkdir_p(FINDINGS_DIR)

seed = ENV["SEED"] || Random.new_seed.to_s
time_budget = ENV.fetch("TIME", "30")
case_budget = ENV.fetch("CASES", "5000")

puts "Rediscovery check: LiquidIL @ #{COMMIT} vs reference liquid, seed=#{seed}, budget=#{time_budget}s/#{case_budget} cases"
ok = system(
  { "RUBY_YJIT_ENABLE" => "0" },
  "bundle", "exec", "ruby", "-I#{File.join(FUZZ_ROOT, "lib")}",
  File.join(FUZZ_ROOT, "rediscover_inner.rb"),
  old_lib, FINDINGS_DIR, time_budget, case_budget, seed,
)

if ok
  puts
  puts "PASS: rediscovered the self[...]-in-nested-loops divergence against #{COMMIT}."
  puts "Finding recorded at #{FINDINGS_DIR} (NOT under fuzz/findings/ -- this is a historical, " \
       "already-fixed-on-main bug being used to validate the tool, not a current finding)."
  exit 0
else
  puts
  puts "FAIL: did not rediscover the divergence within budget. Increase TIME=/CASES= and retry."
  exit 1
end
