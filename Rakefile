# frozen_string_literal: true

require "shellwords"
require "fileutils"

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
  test/dynamic_partials_runtime_test.rb
  test/dynamic_partials_performance_test.rb
  test/iseq_cache_test.rb
  test/iseq_persistence_test.rb
  test/liquid_vm_optional_test.rb
].freeze

require_relative "lib/liquid_il/passes"

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

  def run_liquid_spec!(*argv)
    liquid_spec_root = Gem.loaded_specs.fetch("liquid-spec").full_gem_path
    command = [
      "bundle", "exec", "ruby",
      "-I#{File.join(liquid_spec_root, "lib")}",
      File.join(liquid_spec_root, "bin", "liquid-spec"),
      *argv.flatten.map(&:to_s),
    ]
    puts "(cd #{path.shellescape} && #{command.shelljoin})"
    system(bundle_env.merge(env), *command, chdir: path) || abort("command failed: #{command.shelljoin}")
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
desc "Benchmark vs reference liquid (liquid-spec suite, warm + artifact load, comparison)"
task :bench do
  system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER}") || exit(1)
end

namespace :bench do
  desc "Benchmark the local partial-heavy suite (specs/partials) vs reference liquid"
  task :partials do
    system("RUBY_YJIT_ENABLE=1 bundle exec liquid-spec bench #{ADAPTER} -s partials") || exit(1)
  end

  desc "Cold-path stage breakdown: envelope decode / ISeq load / eval / first render (validated vs reference gem)"
  task :cold do
    system("RUBY_YJIT_ENABLE=1 bundle exec ruby bench/cold_bench.rb") || exit(1)
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
end

desc "Show available optimization passes"
task :passes do
  system "bin/liquidil passes"
end
