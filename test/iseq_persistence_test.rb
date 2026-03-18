# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/liquid_il"

class IseqPersistenceTest < Minitest::Test
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
end
