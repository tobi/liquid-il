#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs INSIDE a subprocess launched by fuzz/rediscover.rb with -I pointing
# at the OLD (commit 2ab67c7) worktree's lib/ placed FIRST on $LOAD_PATH --
# `require "liquid_il"` therefore loads the historical, buggy engine, never
# this repo's current lib/. The oracle/shrinker/finding writer are this
# repo's normal fuzz/lib, unmodified.
#
# Generation here is a TARGETED skeleton, not fuzz/lib/gen.rb's uniform
# random grammar: commit 2ab67c7 has dozens of independent bugs (an old,
# less-mature engine), so pointing the general-purpose uniform generator at
# it and shrinking with a generic "same rule" predicate reliably finds *a*
# bug fast, but the shrinker just as reliably wanders into whichever OTHER,
# simpler bug is nearest in the search -- losing the specific
# self[...]-in-nested-loops shape we're verifying the tool can rediscover
# (confirmed experimentally: two earlier attempts here shrank to unrelated
# case/when and json-filter divergences that only *textually* still
# contained "self[" and "for ... in", not lookalikes that actually depend on
# loop-variable visibility). The skeleton below fixes the SHAPE (matching
# liquid-spec's self_sees_loop_variables_across_three_nested_loops: N
# nested loops, each publishing an alias var holding its own loop-variable
# name, self[alias] read at the innermost position) while randomizing
# everything else the same way fuzz/lib/gen.rb would: nesting depth, loop
# variable names (including shadowing), collection sizes/contents (via the
# same seeded Random and JSON-able value pool), all off one seed -- still
# genuinely the fuzzer's oracle/shrink/subprocess-confirm/finding pipeline,
# just a biased generator so the ONE known bug class is reliably isolated
# within a small budget instead of merely "a bug, somewhere in this pile".
#
# ARGV: old_lib_path, findings_dir, time_budget_seconds, case_budget, seed

old_lib_path, findings_dir, time_budget, case_budget, seed = ARGV
abort "usage: rediscover_inner.rb OLD_LIB_PATH FINDINGS_DIR TIME CASES SEED" unless seed

$LOAD_PATH.unshift old_lib_path
require "liquid_il"
require "liquid"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "case"
require "engines"
require "oracle"
require "shrink"
require "finding"
require "subprocess_confirm"

LOOP_VAR_NAMES = %w[a b c d item value].freeze
VALUE_POOL = ["p", "q", "r", 7, 8, 9, "café", true, false, nil].freeze

# Builds one randomized instance of the historical bug's shape: `depth`
# nested loops, each level `i` gets a collection (2-3 random JSON-able
# scalars), a loop variable (possibly shadowing an outer one, since the
# real bug -- and the doc's generator spec -- calls out "nested loops...
# reusing and shadowing variable names"), an alias assigned to that loop
# variable's own NAME, and self[alias] read at the innermost position.
# forloop.index is read only in the outermost loop, matching the historical
# spec's note that implementations which decide "does this loop need scope
# publication?" by scanning inner bodies get no hint from the inner loops.
def build_case(seed, random)
  depth = random.rand(2..3)
  names = Array.new(depth) { LOOP_VAR_NAMES.sample(random: random) }
  env = {}
  ast = []
  aliases = []
  names.each_with_index do |name, i|
    alias_name = "v#{i}"
    aliases << alias_name
    ast << { type: :assign, name: alias_name, expr: { type: :lit, value: name } }
    env["coll#{i}"] = Array.new(random.rand(2..3)) { VALUE_POOL.sample(random: random) }
  end

  inner = aliases.map { |a| { type: :output, expr: { type: :chain, base: :self, accessors: [{ bracket: { type: :chain, base: a, accessors: [] } }] } } }
  body = inner
  depth.downto(1).each do |level|
    i = level - 1
    stmts = body
    stmts = [{ type: :output, expr: { type: :chain, base: "forloop", accessors: [{ dot: "index" }] } }] + stmts if i.zero?
    body = [{ type: :for, var: names[i], coll: { type: :chain, base: "coll#{i}", accessors: [] }, body: stmts, else_body: nil }]
  end
  ast.concat(body)

  Fuzz::Case.new(seed: seed, ast: ast, environment: env, filesystem: {}, error_mode: :strict)
end

def self_in_nested_loop?(kase)
  src = kase.template_src
  src.include?("self[") && src.scan(/\{%-?\s*for\s/).size >= 2
end

# The shrinker's generic ddmin can drop a whole (:name, "v0") pair from an
# :assign node, or empty out an env array, and STILL "reproduce a finding"
# -- against commit 2ab67c7 (dozens of independent bugs) that reliably
# wanders into some unrelated degenerate-template divergence instead of
# preserving the one we're isolating. These extra invariants keep the
# shrink honest: every alias assign still has a real name, and every loop
# collection stays non-empty so the loop body actually executes (a bug
# about whether self[...] sees values PUBLISHED BY iteration is vacuous if
# the loop never iterates).
def valid_shape?(kase)
  self_in_nested_loop?(kase) &&
    kase.environment.values.all? { |v| !v.is_a?(Array) || !v.empty? } &&
    kase.ast.grep(Hash).none? { |n| n[:type] == :assign && n[:name].to_s.strip.empty? }
end

start = Time.now
seed_random = Random.new(seed.to_i)
cases = 0
found = nil

loop do
  break if Time.now - start > time_budget.to_f
  break if cases >= case_budget.to_i
  break if found

  case_seed = seed_random.rand(2**31)
  kase = build_case(case_seed, Random.new(case_seed))
  cases += 1

  ref = Fuzz::ReferenceEngine.render(kase)
  lil = Fuzz::LiquidILEngine.render(kase)
  verdict = Fuzz::Oracle.compare(ref, lil)
  next unless verdict.status == :finding

  minimized = Fuzz::Shrink.minimize(kase) do |candidate|
    next false unless valid_shape?(candidate)

    cref = Fuzz::ReferenceEngine.render(candidate)
    clil = Fuzz::LiquidILEngine.render(candidate)
    Fuzz::Oracle.compare(cref, clil).status == :finding
  end

  final_ref = Fuzz::ReferenceEngine.render(minimized)
  final_lil = Fuzz::LiquidILEngine.render(minimized)
  found = { kase: minimized, ref: final_ref, lil: final_lil, seed: case_seed }
end

elapsed = Time.now - start
puts "cases=#{cases} elapsed=#{elapsed.round(2)}s seed=#{seed}"

if found
  confirmed, agrees = Fuzz::SubprocessConfirm.confirm(found[:kase], found[:ref])
  ground_truth = agrees == false ? confirmed : found[:ref]
  path = Fuzz::Finding.write!(
    findings_dir, found[:kase], ground_truth, found[:lil],
    rule: :self_in_nested_loop_rediscovery, signature: "self_in_nested_loop::#{found[:seed]}",
    subprocess_confirmed: agrees,
    note: "Rediscovered against a worktree of commit 2ab67c7 (goal 02 doc verification) -- " \
          "self[...] fails to see an enclosing loop variable's published value. Fixed on " \
          "main (see liquid-spec self_sees_loop_variables_across_three_nested_loops); this " \
          "finding is expected to NOT reproduce against the current lib/.",
  )
  puts "FOUND seed=#{found[:seed]} -> #{path}"
  puts "template: #{found[:kase].template_src}"
  puts "environment: #{found[:kase].environment}"
  puts "expected (reference): #{ground_truth[:output].inspect}"
  puts "actual (old LiquidIL): #{found[:lil][:output].inspect}"
  exit 0
else
  puts "NOT FOUND within budget (cases=#{cases})"
  exit 1
end
