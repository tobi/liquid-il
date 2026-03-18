# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/liquid_il"

class IseqPersistenceTest < Minitest::Test
  class MemoryFS
    attr_reader :reads

    def initialize(templates)
      @templates = templates
      @reads = Hash.new(0)
    end

    def read_template_file(name, _context = nil)
      key = name.to_s
      @reads[key] += 1
      @templates[key]
    end
  end

  def test_write_and_load_raw_iseq
    template = LiquidIL.parse("Hello {{ name }}")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "greeting.iseq")
      template.write_iseq(path)

      restored = LiquidIL::Template.load_iseq(path, source: "Hello {{ name }}")
      assert_equal "Hello World", restored.render("name" => "World")
    end
  end

  def test_write_and_load_full_cache
    template = LiquidIL.parse("{{ x | plus: 1 }}")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "calc.ilc")
      template.write_cache(path)

      restored = LiquidIL::Template.load_cache(path)
      assert_equal "6", restored.render("x" => 5)
    end
  end

  def test_raw_iseq_is_a_proc_and_callable_directly
    template = LiquidIL.parse("Hello {{ name }}")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "direct.iseq")
      template.write_iseq(path)

      proc_obj = RubyVM::InstructionSequence.load_from_binary(File.binread(path)).eval
      assert_kind_of Proc, proc_obj

      scope = LiquidIL::Scope.new({ "name" => "Ruby" })
      out = proc_obj.call(scope, template.spans, template.source)
      assert_equal "Hello Ruby", out
    end
  end

  def test_write_ruby_with_static_partials_renders_without_file_system
    fs = MemoryFS.new(
      "outer" => "OUT[{% render 'inner', who: who %}]",
      "inner" => "IN:{{ who }}"
    )

    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% render 'outer', who: name %}")
    assert_equal "OUT[IN:Ada]", template.render("name" => "Ada")

    Dir.mktmpdir do |dir|
      ruby_path = File.join(dir, "compiled_with_partials.rb")
      module_name = "CompiledWithPartials"

      template.write_ruby(ruby_path, module_name: module_name)

      Object.send(:remove_const, module_name.to_sym) if Object.const_defined?(module_name)
      load ruby_path

      mod = Object.const_get(module_name)
      assert_equal "OUT[IN:Grace]", mod.render({ "name" => "Grace" })

      # The standalone module must not need runtime file-system access.
      # All static partials should already be embedded in generated Ruby.
      assert_operator fs.reads["outer"], :>=, 1
      assert_operator fs.reads["inner"], :>=, 1
    ensure
      Object.send(:remove_const, module_name.to_sym) if Object.const_defined?(module_name)
    end
  end
end
