# frozen_string_literal: true

require "shellwords"
require "fileutils"
require "json"
require "open3"
require "yaml"

task default: :test

ADAPTER = "spec/liquid_il.rb"
ADAPTER_VM = "spec/liquid_vm.rb"
ADAPTER_VM_SSA = "spec/liquid_vm_ssa.rb"
ADAPTER_RUBY = "spec/liquid_ruby_bench.rb"
LIQUID_VM_REPO = "https://github.com/Shopify/liquid-vm"
LIQUID_VM_DEFAULT_PATH = "/tmp/liquid-vm"
TEST_FILES = %w[
  test/liquid_il_test.rb
  test/ruby_compiler_test.rb
  test/optimization_passes_test.rb
  test/error_handling_test.rb
  test/case_when_semantics_test.rb
  test/blank_error_suppression_test.rb
  test/dynamic_partials_runtime_test.rb
  test/dynamic_partials_performance_test.rb
  test/concurrency_test.rb
  test/ractor_render_test.rb
  test/iseq_cache_test.rb
  test/iseq_persistence_test.rb
  test/artifact_self_consistency_test.rb
  test/liquid_vm_optional_test.rb
].freeze

module LiquidVmRake
  module_function

  def path
    File.expand_path(ENV.fetch("LIQUID_VM_PATH", LIQUID_VM_DEFAULT_PATH))
  end

  def repo
    ENV.fetch("LIQUID_VM_REPO", LIQUID_VM_REPO)
  end

  def adapter(backend = nil)
    if backend.nil?
      explicit = ENV["LIQUID_VM_ADAPTER"]
      return File.expand_path(explicit) if explicit && !explicit.empty?

      backend = ENV["LIQUID_VM_BACKEND"] == "ssa" ? :ssa : :vm
    end

    filename = backend.to_sym == :ssa ? "liquid_vm_ssa.rb" : "liquid_vm.rb"
    File.join(path, "test", "adapters", filename)
  end

  def adapters
    [adapter(:vm), adapter(:ssa)]
  end

  def gemfile
    File.join(path, "Gemfile")
  end

  def bundle_env
    {
      "BUNDLE_GEMFILE" => gemfile,
      "BUNDLE_WITHOUT" => ENV.fetch("BUNDLE_WITHOUT", "development"),
      "RUBY_YJIT_ENABLE" => "1",
    }
  end

  def env
    ruby_lib = [File.join(path, "gem", "lib"), ENV["RUBYLIB"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR)
    {
      "LIQUID_VM_PATH" => path,
      "LIQUID_VM_ADAPTER" => adapter(:vm),
      "LIQUID_VM_SSA_ADAPTER" => adapter(:ssa),
      "RUBYLIB" => ruby_lib,
    }
  end

  def extra_args
    args = Shellwords.split(ENV.fetch("LIQUID_SPEC_ARGS", ""))
    args += ["-n", ENV["NAME"]] if ENV["NAME"] && !ENV["NAME"].empty?
    args += ["-s", ENV["SUITE"]] if ENV["SUITE"] && !ENV["SUITE"].empty?
    args
  end

  def run!(*argv, extra_env: {})
    command = argv.flatten.map(&:to_s)
    puts command.shelljoin
    system(env.merge({ "RUBY_YJIT_ENABLE" => "1" }, extra_env), *command) || abort("command failed: #{command.shelljoin}")
  end

  def run_in_checkout!(*argv)
    command = argv.flatten.map(&:to_s)
    puts "(cd #{path.shellescape} && #{command.shelljoin})"
    system(bundle_env, *command, chdir: path) || abort("command failed: #{command.shelljoin}")
  end

  def liquid_spec_command(*argv)
    # loaded_specs only sees activated gems; fall back to the lockfile
    # resolution when liquid-spec hasn't been required in this process.
    liquid_spec_root = Gem.loaded_specs["liquid-spec"]&.full_gem_path ||
                       begin
                         require "bundler"
                         ::Bundler.load.specs.find { |s| s.name == "liquid-spec" }.full_gem_path
                       end
    [
      "bundle", "exec", "ruby",
      "-I#{File.join(liquid_spec_root, "lib")}",
      File.join(liquid_spec_root, "bin", "liquid-spec"),
      *argv.flatten.map(&:to_s),
    ]
  end

  def run_liquid_spec!(*argv)
    command = liquid_spec_command(*argv)
    puts "(cd #{path.shellescape} && #{command.shelljoin})"
    system(bundle_env.merge(env), *command, chdir: path) || abort("command failed: #{command.shelljoin}")
  end

  def capture_liquid_spec!(*argv)
    command = liquid_spec_command(*argv)
    puts "(cd #{path.shellescape} && #{command.shelljoin})"
    stdout, stderr, status = Open3.capture3(bundle_env.merge(env), *command, chdir: path)
    unless status.success?
      warn stderr unless stderr.empty?
      abort("command failed: #{command.shelljoin}")
    end
    warn stderr unless stderr.empty?
    stdout
  end

  def ensure_adapter!(path = adapter)
    return if File.file?(path)

    abort <<~MSG
      liquid-vm adapter not found: #{path}

      Run `bundle exec rake liquid_vm:setup` to clone Shopify/liquid-vm into #{self.path},
      or set LIQUID_VM_PATH=/path/to/liquid-vm / LIQUID_VM_ADAPTER=/path/to/adapter.rb.
    MSG
  end

  def ensure_adapters!
    adapters.each { |path| ensure_adapter!(path) }
  end
end

# The three core render scenarios (plus artifact size) that every benchmark
# reports. These are THE optimization and test scenarios for LiquidIL — see
# README.md "The three render scenarios" and AGENTS.md.
#
#   cache-miss  → render : parse + compile + render (template never seen)
#   remote-hit  → render : compiled artifact fetched as a string (memcache/DB)
#                          → load → render
#   in-process  → render : template already loaded in this process → render
#   artifact             : compiled artifact size (drives remote-hit load
#                          cost, ~3µs/KB)
module CacheScenarios
  module_function

  def capture_bench_jsonl!(*argv)
    command = ["bundle", "exec", "liquid-spec", "bench", *argv.flatten.map(&:to_s), "--jsonl"]
    puts command.shelljoin
    stdout, stderr, status = Open3.capture3({ "RUBY_YJIT_ENABLE" => "1" }, *command)
    unless status.success?
      warn stderr unless stderr.empty?
      abort("command failed: #{command.shelljoin}")
    end
    warn stderr unless stderr.empty?
    stdout
  end

  def print_table(jsonl)
    rows = jsonl.each_line.filter_map do |line|
      data = JSON.parse(line, symbolize_names: true) rescue nil
      data if data && data[:type] == "spec" && data[:status] == "success"
    end

    adapters = rows.map { |row| row[:adapter] }.uniq
    common = adapters.map do |adapter|
      rows.filter_map { |row| spec_name(row) if row[:adapter] == adapter }.uniq
    end.reduce(:&) || []

    puts "Cache scenario benchmark table"
    puts
    puts "  cache-miss → render : parse + compile + render (template never seen)"
    puts "  remote-hit → render : compiled artifact fetched as a string (memcache/DB) → load → render"
    puts "  in-process → render : template already loaded in this process → render"
    puts "  artifact            : compiled artifact size (drives remote-hit load cost, ~3µs/KB)"
    puts
    puts "Geomean across common successful specs (n=#{common.size})"
    print_rows(rows.select { |row| common.include?(spec_name(row)) })

    rows.group_by { |row| spec_name(row) }.sort_by(&:first).each do |name, spec_rows|
      puts
      puts name.sub(/\Abench_/, "")
      print_rows(spec_rows)
    end
  end

  def print_rows(rows)
    puts "| adapter | cache-miss | remote-hit | in-process | artifact | specs |"
    puts "|---|---:|---:|---:|---:|---:|"
    rows.group_by { |row| row[:adapter] }.sort_by(&:first).each do |adapter, adapter_rows|
      metrics = adapter_rows.map { |row| scenario_metrics(row) }
      puts "| #{adapter} | #{fmt_time(geomean(metrics.map { |m| m[:cache_miss] }))} | " \
           "#{fmt_time(geomean(metrics.map { |m| m[:remote_hit] }))} | " \
           "#{fmt_time(geomean(metrics.map { |m| m[:in_process] }))} | " \
           "#{fmt_bytes(geomean(metrics.map { |m| m[:artifact_bytes] }))} | #{adapter_rows.size} |"
    end
  end

  def scenario_metrics(row)
    parse = row.dig(:parse, :mean) || row[:parse_mean]
    render = row.dig(:render, :mean) || row[:render_mean]
    load = row.dig(:artifact, :load_mean) || row[:load_mean]
    bytes = row.dig(:artifact, :bytes) || row[:artifact_bytes]
    {
      cache_miss: parse && render && parse + render,
      remote_hit: load && render && load + render,
      in_process: render,
      artifact_bytes: bytes,
    }
  end

  def spec_name(row)
    row[:spec] || row[:spec_name]
  end

  def geomean(values)
    values = values.compact.select { |value| value.to_f.positive? }
    return nil if values.empty?

    Math.exp(values.sum { |value| Math.log(value.to_f) } / values.size)
  end

  def fmt_time(seconds)
    return "—" unless seconds

    if seconds < 0.001
      "%.0fµs" % (seconds * 1_000_000)
    elsif seconds < 1.0
      "%.2fms" % (seconds * 1_000)
    else
      "%.2fs" % seconds
    end
  end

  def fmt_bytes(bytes)
    return "—" unless bytes

    bytes < 1024 ? "%.0fB" % bytes : "%.1fKB" % (bytes / 1024.0)
  end
end

module ThreadScenarios
  module_function

  THREAD_COUNTS = [1, 2, 4, 8].freeze
  DEFAULT_ITERS = 4000

  class BenchFS
    def initialize(templates)
      @templates = templates || {}
    end

    def read_template_file(name, _context = nil)
      @templates[name.to_s]
    end
  end

  def run!
    specs = load_specs
    same = specs.find { |spec| spec["name"] == "bench_nested_partials" } || specs.first
    mixed = specs.first(4)
    iters = Integer(ENV.fetch("THREAD_BENCH_ITERS", DEFAULT_ITERS))

    liquid_il_same = build_liquid_il_entries([same])
    liquid_il_mixed = build_liquid_il_entries(mixed)
    liquid_ruby_same = build_liquid_ruby_entries([same])
    liquid_ruby_mixed = build_liquid_ruby_entries(mixed)

    puts "Thread render benchmark"
    puts
    puts "  Each template is parsed/compiled and loaded once before timing."
    puts "  Each worker thread renders with its own assigns hash."
    puts "  Iterations per thread: #{iters}"
    puts
    print_table("same template: #{same["name"]}", {
      "liquid_il" => liquid_il_same,
      "liquid_ruby" => liquid_ruby_same,
    }, iters)
    puts
    print_table("mixed templates: #{mixed.map { |s| s["name"] }.join(", ")}", {
      "liquid_il" => liquid_il_mixed,
      "liquid_ruby" => liquid_ruby_mixed,
    }, iters)
  end

  def load_specs
    yml = YAML.safe_load(File.read("specs/partials/partials.yml"), aliases: true)
    yml.fetch("specs").select { |spec| spec["name"]&.start_with?("bench_") && spec["template"] }
  end

  def build_liquid_il_entries(specs)
    require_relative "lib/liquid_il"
    specs.map do |spec|
      fs = BenchFS.new(spec["filesystem"])
      ctx = LiquidIL::Context.new(file_system: fs)
      template = ctx.parse(spec["template"])
      artifact = LiquidIL.load_artifact(template.to_artifact)
      assigns = deep_dup(spec["environment"] || {})
      expected = template.render(deep_dup(assigns))
      actual = artifact.render(deep_dup(assigns))
      abort "LiquidIL thread bench validation failed for #{spec["name"]}" unless actual == expected
      { name: spec["name"], renderer: artifact, assigns: assigns, type: :liquid_il }
    end
  end

  def build_liquid_ruby_entries(specs)
    require "liquid"
    specs.map do |spec|
      fs = BenchFS.new(spec["filesystem"])
      template = Liquid::Template.parse(spec["template"])
      assigns = deep_dup(spec["environment"] || {})
      actual = template.render(deep_dup(assigns), registers: { file_system: fs })
      abort "liquid_ruby thread bench validation failed for #{spec["name"]}" if actual.nil?
      { name: spec["name"], renderer: template, assigns: assigns, fs: fs, type: :liquid_ruby }
    end
  end

  def print_table(title, adapters, iters)
    puts title
    puts "| adapter | threads | renders/sec | scaling | elapsed |"
    puts "|---|---:|---:|---:|---:|"
    adapters.each do |adapter, entries|
      base = nil
      THREAD_COUNTS.each do |threads|
        elapsed = time_threads(entries, threads, iters)
        rps = (threads * iters) / elapsed
        base ||= rps
        puts "| #{adapter} | #{threads} | #{format('%.0f', rps)} | #{format('%.2fx', rps / base)} | #{format('%.3fs', elapsed)} |"
      end
    end
  end

  def time_threads(entries, thread_count, iters)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threads = thread_count.times.map do |tid|
      entry = entries[tid % entries.length]
      Thread.new do
        assigns = deep_dup(entry[:assigns])
        assigns["thread_id"] = tid
        iters.times do |i|
          assigns["iteration"] = i
          render_entry(entry, assigns)
        end
      end
    end
    threads.each(&:join)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def render_entry(entry, assigns)
    if entry[:type] == :liquid_il
      entry[:renderer].render(assigns)
    else
      entry[:renderer].render(assigns, registers: { file_system: entry[:fs] })
    end
  end

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end
end

desc "Run full test suite"
task :test do
  puts "\n#{"=" * 60}\nRunning unit tests\n#{"=" * 60}"
  TEST_FILES.each do |f|
    puts "\n--- #{f} ---"
    system("bundle exec ruby -Ilib #{f}") || exit(1)
  end

  puts "\n#{"=" * 60}\nRunning liquid-spec\n#{"=" * 60}"
  system("bash -c 'bundle exec liquid-spec run #{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'") || exit(1)

  puts "\n#{"=" * 60}\nALL TESTS PASSED\n#{"=" * 60}"
end

desc "Run unit tests only"
task :unit do
  TEST_FILES.each do |f|
    system("bundle exec ruby -Ilib #{f}") || exit(1)
  end
end

desc "Run liquid-spec"
task :spec do
  system "bash -c 'bundle exec liquid-spec run #{ADAPTER} 2> >(grep -v \"missing extensions\" >&2)'"
end

desc "Run spec matrix against reference Liquid"
task :matrix do
  adapters = "--adapters=liquid_ruby --adapter=#{ADAPTER}"
  adapters += " --adapter=#{ADAPTER_VM} --adapter=#{ADAPTER_VM_SSA}" if ENV["WITH_LIQUID_VM"] == "1"
  system "bash -c 'RUBY_YJIT_ENABLE=1 bundle exec liquid-spec matrix #{adapters} --no-max-failures 2> >(grep -v \"missing extensions\" >&2)'"
end

# Benchmarks run through liquid-spec's harness (GC-disciplined timing, real
# percentiles, allocs). The adapter implements the compiled-artifact protocol
# (LiquidSpec.dump_artifact / load_artifact), so every bench also reports the
# artifact stage: payload bytes, cold load, load+first-render, steady-state
# load — with a dump → load → render roundtrip check per spec.
desc "Benchmark vs reference liquid: the three core scenarios (cache-miss / remote-hit / in-process) + artifact size"
task :bench do
  jsonl = CacheScenarios.capture_bench_jsonl!(
    "--adapters=liquid_ruby",
    "--adapter=#{File.expand_path(ADAPTER)}"
  )
  FileUtils.mkdir_p("tmp")
  File.write("tmp/scenarios.jsonl", jsonl)
  CacheScenarios.print_table(jsonl)
  puts
  puts "Raw JSONL: tmp/scenarios.jsonl  (per-stage detail: rake bench:detail)"
end

# `rake scenarios` is the canonical name for the core comparison table
desc "Alias of rake bench: the three core scenarios vs reference liquid"
task scenarios: :bench

namespace :bench do
  desc "Detailed per-stage benchmark output (parse/render/load distributions, allocs, YJIT stats)"
  task :detail do
    system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER}") || exit(1)
  end

  desc "Benchmark the local partial-heavy suite (specs/partials) vs reference liquid"
  task :partials do
    system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER} -s partials") || exit(1)
  end

  desc "Cold-path stage breakdown: envelope decode / ISeq load / eval / first render (validated vs reference gem)"
  task :cold do
    system("RUBY_YJIT_ENABLE=1 bundle exec ruby bench/cold_bench.rb") || exit(1)
  end

  desc "Concurrent render throughput for loaded artifacts/templates across 1, 2, 4, and 8 threads"
  task :threads do
    ThreadScenarios.run!
  end

  desc "Artifact byte attribution: where compiled-artifact bytes come from, per codegen pattern"
  task :bytes do
    system("bundle exec ruby bench/bytes_bench.rb") || exit(1)
  end

  desc "Benchmark LiquidIL against optional Shopify/liquid-vm (cloned in /tmp by default)"
  task liquid_vm: "liquid_vm:bench"
end

namespace :liquid_vm do
  desc "Clone or update optional Shopify/liquid-vm into LIQUID_VM_PATH (default: /tmp/liquid-vm)"
  task :clone do
    path = LiquidVmRake.path
    if File.directory?(File.join(path, ".git"))
      system("git", "-C", path, "pull", "--ff-only") || abort("failed to update #{path}")
    elsif File.exist?(path)
      abort "#{path} exists but is not a git checkout; set LIQUID_VM_PATH or remove it"
    else
      FileUtils.mkdir_p(File.dirname(path))
      system("git", "clone", LiquidVmRake.repo, path) || abort("failed to clone #{LiquidVmRake.repo}")
    end
  end

  desc "Install the optional liquid-vm bundle"
  task bundle: :clone do
    LiquidVmRake.run_in_checkout!("bundle", "install")
  end

  desc "Build the optional liquid-vm native extension"
  task compile: :bundle do
    unless system("which", "cargo", out: File::NULL)
      abort "cargo is required to build Shopify/liquid-vm; install Rust/Cargo and rerun `bundle exec rake liquid_vm:setup`"
    end

    LiquidVmRake.run_in_checkout!("bundle", "exec", "rake", "compile")
  end

  desc "Clone/update liquid-vm, install its bundle, and build its native extension"
  task setup: :compile

  desc "Run liquid-spec matrix for liquid_ruby, LiquidIL, liquid-vm, and liquid-vm SSA"
  task spec: :setup do
    LiquidVmRake.ensure_adapters!
    LiquidVmRake.run_liquid_spec!(
      "matrix",
      "--adapters=liquid_ruby",
      "--adapter=#{File.expand_path(ADAPTER)}",
      "--adapter=#{File.expand_path(ADAPTER_VM)}",
      "--adapter=#{File.expand_path(ADAPTER_VM_SSA)}",
      "--no-max-failures",
      LiquidVmRake.extra_args
    )
  end

  desc "Benchmark liquid_ruby, LiquidIL, liquid-vm, and liquid-vm SSA"
  task bench: :setup do
    LiquidVmRake.ensure_adapters!
    LiquidVmRake.run_liquid_spec!(
      "bench",
      "--adapters=liquid_ruby",
      "--adapter=#{File.expand_path(ADAPTER)}",
      "--adapter=#{File.expand_path(ADAPTER_VM)}",
      "--adapter=#{File.expand_path(ADAPTER_VM_SSA)}",
      LiquidVmRake.extra_args
    )
  end

  desc "The three core scenarios (cache-miss / remote-hit / in-process) for LiquidIL, reference liquid, and optional liquid-vm"
  task scenarios: :setup do
    LiquidVmRake.ensure_adapters!
    jsonl = LiquidVmRake.capture_liquid_spec!(
      "bench",
      "--adapters=liquid_ruby",
      "--adapter=#{File.expand_path(ADAPTER)}",
      "--adapter=#{File.expand_path(ADAPTER_VM)}",
      "--adapter=#{File.expand_path(ADAPTER_VM_SSA)}",
      "--jsonl",
      LiquidVmRake.extra_args
    )
    FileUtils.mkdir_p("tmp")
    File.write("tmp/liquid_vm_scenarios.jsonl", jsonl)
    CacheScenarios.print_table(jsonl)
    puts
    puts "Raw JSONL: tmp/liquid_vm_scenarios.jsonl"
  end
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end

# Differential fuzzer vs reference liquid -- see .goals/02-differential-fuzzer.md
# and fuzz/README.md. Pure tooling: never touches engine code, and both
# engines run in-process for throughput (subprocess confirmation is only
# used off the hot path, per mismatch, before a finding is recorded).
desc "Differential fuzzer smoke run: 60s or 2000 cases vs reference liquid (exits nonzero on a NEW finding)"
task :fuzz do
  sh({ "RUBY_YJIT_ENABLE" => "1" }, "bundle", "exec", "ruby", "fuzz/run.rb")
end

namespace :fuzz do
  desc "Differential fuzzer long run: 10 minutes or 100,000 cases (override with TIME=/CASES=)"
  task :long do
    env = { "RUBY_YJIT_ENABLE" => "1", "TIME" => ENV.fetch("TIME", "600"), "CASES" => ENV.fetch("CASES", "100000") }
    sh(env, "bundle", "exec", "ruby", "fuzz/run.rb")
  end

  desc "Calibration: fuzzer must report ZERO mismatches on 50 unmutated liquid-spec templates"
  task :calibrate do
    sh({ "RUBY_YJIT_ENABLE" => "1" }, "bundle", "exec", "ruby", "fuzz/calibrate.rb")
  end

  desc "Rediscovery check: verify the fuzzer finds the known self[...]-in-nested-loops bug against a worktree of commit 2ab67c7"
  task :rediscover do
    sh({ "RUBY_YJIT_ENABLE" => "1" }, "bundle", "exec", "ruby", "fuzz/rediscover.rb")
  end

  desc "RAW export of fuzz/findings/ for editorial triage (fuzz/triage/raw_export.yml). spec/fuzz.yml is curated by hand — never overwrite it mechanically"
  task :export do
    sh("bundle", "exec", "ruby", "fuzz/export_spec.rb")
  end
end
