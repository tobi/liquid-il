# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Performance smoke tests for runtime-compiled dynamic partials.
# These are intentionally coarse to catch catastrophic regressions.
class DynamicPartialsPerformanceTest < Minitest::Test
  class FS
    attr_reader :reads

    def initialize(templates)
      @templates = templates
      @reads = Hash.new(0)
    end

    def read_template_file(name, _context = nil)
      @reads[name.to_s] += 1
      @templates[name.to_s]
    end
  end

  def test_dynamic_include_runtime_path_smoke
    fs = FS.new("item" => "[{{ item }}]")
    ctx = LiquidIL::Context.new(file_system: fs)
    template = ctx.parse("{% include tpl for items %}")

    assigns = { "tpl" => "item", "items" => (1..60).to_a }

    # Warmup
    5.times { template.render(assigns) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    120.times { template.render(assigns) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # 120 renders * 60 items = 7200 dynamic partial executions.
    # Keep threshold generous to avoid flake; catches order-of-magnitude regressions.
    assert_operator elapsed, :<, 3.0, "dynamic partial runtime path too slow: #{elapsed.round(3)}s"
    assert_operator fs.reads["item"], :>=, 7_200
  end

  def test_dynamic_include_vs_static_include_order_of_magnitude
    fs = FS.new("item" => "[{{ item }}]")
    ctx = LiquidIL::Context.new(file_system: fs)

    dynamic_t = ctx.parse("{% include tpl for items %}")
    static_t = ctx.parse("{% include 'item' for items %}")
    assigns = { "tpl" => "item", "items" => (1..50).to_a }

    5.times do
      dynamic_t.render(assigns)
      static_t.render(assigns)
    end

    dyn_s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times { dynamic_t.render(assigns) }
    dyn = Process.clock_gettime(Process::CLOCK_MONOTONIC) - dyn_s

    stc_s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times { static_t.render(assigns) }
    stc = Process.clock_gettime(Process::CLOCK_MONOTONIC) - stc_s

    # Dynamic path will be slower, but should stay in same order of magnitude.
    ratio = dyn / [stc, 0.0001].max
    assert_operator ratio, :<, 80.0, "dynamic/static ratio too high: #{ratio.round(2)}x"
  end
end
