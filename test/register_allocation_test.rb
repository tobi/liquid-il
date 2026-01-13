# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# Test suite for register allocation optimization (US-006)
#
# These tests verify the temp register reuse behavior:
# - Sequential non-overlapping temps are reused
# - Overlapping live ranges prevent reuse
# - Temps used in loops maintain correctness
# - Nested temp usage is handled correctly
class RegisterAllocationTest < Minitest::Test
  # Helper to create IL instructions directly
  def build_instructions(&block)
    builder = LiquidIL::IL::Builder.new
    builder.instance_eval(&block)
    builder.instructions
  end

  # Helper to extract temp indices from STORE_TEMP/LOAD_TEMP instructions
  def extract_temp_indices(instructions, opcode)
    instructions.select { |inst| inst[0] == opcode }.map { |inst| inst[1] }
  end

  # ============================================================
  # Test: Sequential non-overlapping temps are reused
  # ============================================================

  def test_sequential_non_overlapping_temps_reuse_slots
    # Pattern: store t0, load t0, store t1, load t1
    # Expected: t0 and t1 should share the same slot since they don't overlap
    instructions = build_instructions do
      const_int(1)
      store_temp(0)
      load_temp(0)
      write_value

      const_int(2)
      store_temp(1)
      load_temp(1)
      write_value
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    # After allocation, both temps should use slot 0
    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    load_indices = extract_temp_indices(instructions, LiquidIL::IL::LOAD_TEMP)

    assert_equal [0, 0], store_indices, "Non-overlapping temps should reuse slot 0"
    assert_equal [0, 0], load_indices, "Non-overlapping temps should reuse slot 0"
    assert_equal 1, allocator.peak_usage, "Peak usage should be 1 for non-overlapping temps"
  end

  def test_sequential_three_temps_share_slot
    # Pattern: store t0, load t0 | store t1, load t1 | store t2, load t2
    # All three temps should share slot 0
    instructions = build_instructions do
      const_int(1)
      store_temp(0)
      load_temp(0)
      pop

      const_int(2)
      store_temp(1)
      load_temp(1)
      pop

      const_int(3)
      store_temp(2)
      load_temp(2)
      pop
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    assert_equal [0, 0, 0], store_indices, "All three non-overlapping temps should share slot 0"
    assert_equal 1, allocator.peak_usage
  end

  def test_interleaved_but_non_overlapping_temps
    # t0 used, then t1 used, then t0 used again via a new store
    # This should result in t0(new) reusing slot 0 after t1 finishes
    instructions = build_instructions do
      const_int(1)
      store_temp(0)
      load_temp(0)
      write_value

      const_int(2)
      store_temp(1)
      load_temp(1)
      write_value

      const_int(3)
      store_temp(2)  # New temp, should get slot 0 (reused)
      load_temp(2)
      write_value
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    assert_equal [0, 0, 0], store_indices, "Sequential temps should all reuse slot 0"
    assert_equal 1, allocator.peak_usage
  end

  # ============================================================
  # Test: Overlapping live ranges prevent reuse
  # ============================================================

  def test_overlapping_temps_get_separate_slots
    # Pattern: store t0, store t1, load t1, load t0
    # t0 and t1 are live simultaneously, so they need separate slots
    instructions = build_instructions do
      const_int(1)
      store_temp(0)

      const_int(2)
      store_temp(1)

      load_temp(1)  # t1 loaded first
      write_value

      load_temp(0)  # t0 still live when t1 was stored
      write_value
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    # t0 gets slot 0, t1 gets slot 1 (they overlap)
    assert_equal [0, 1], store_indices, "Overlapping temps need separate slots"
    assert_equal 2, allocator.peak_usage, "Peak usage should be 2 for overlapping temps"
  end

  def test_three_overlapping_temps
    # All three temps are live at the same time
    instructions = build_instructions do
      const_int(1)
      store_temp(0)

      const_int(2)
      store_temp(1)

      const_int(3)
      store_temp(2)

      # All three are now live
      load_temp(0)
      write_value

      load_temp(1)
      write_value

      load_temp(2)
      write_value
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    assert_equal [0, 1, 2], store_indices, "Three overlapping temps need three slots"
    assert_equal 3, allocator.peak_usage
  end

  def test_partial_overlap_mixed_reuse
    # t0 and t1 overlap, but t2 starts after t0 ends
    # t0 -> slot 0
    # t1 -> slot 1 (overlaps with t0)
    # t2 -> slot 0 (reuses after t0 is dead)
    instructions = build_instructions do
      const_int(1)
      store_temp(0)

      const_int(2)
      store_temp(1)

      load_temp(0)  # t0 ends here
      write_value

      const_int(3)
      store_temp(2)  # Should reuse slot 0

      load_temp(1)  # t1 ends
      write_value

      load_temp(2)  # t2 ends
      write_value
    end

    allocator = LiquidIL::TempAllocator.new(instructions)
    allocator.allocate!

    store_indices = extract_temp_indices(instructions, LiquidIL::IL::STORE_TEMP)
    # t0 -> 0, t1 -> 1, t2 -> 0 (reused from t0)
    assert_equal [0, 1, 0], store_indices, "t2 should reuse slot 0 after t0 is dead"
    assert_equal 2, allocator.peak_usage
  end

  # ============================================================
  # Test: Temps used in loops maintain correctness
  # ============================================================

  def test_temp_in_loop_body
    # A temp used inside a loop should maintain correctness across iterations
    # This tests that the register allocator doesn't incorrectly optimize across loops
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% for i in (1..3) %}{{ i | plus: 10 }}{% endfor %}", optimize: true)

    result = template.render
    assert_equal "111213", result, "Temps in loop body should work correctly"
  end

  def test_nested_loops_with_temps
    # Multiple nested loops each using temps
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% for i in (1..2) %}{% for j in (1..2) %}{{ i }}-{{ j }},{% endfor %}{% endfor %}", optimize: true)

    result = template.render
    assert_equal "1-1,1-2,2-1,2-2,", result, "Temps in nested loops should work correctly"
  end

  def test_loop_with_filter_chain
    # Loop with filter chains that may use temp registers
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% for item in items %}{{ item | upcase | append: '!' }}{% endfor %}", optimize: true)

    result = template.render(items: %w[a b c])
    assert_equal "A!B!C!", result, "Filter chains in loops should maintain correctness"
  end

  def test_loop_with_conditional
    # Loop with conditionals that use temps
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% for n in (1..5) %}{% if n > 2 %}{{ n }}{% endif %}{% endfor %}", optimize: true)

    result = template.render
    assert_equal "345", result, "Conditionals in loops should work correctly"
  end

  # ============================================================
  # Test: Nested temp usage is handled correctly
  # ============================================================

  def test_nested_filter_calls
    # Nested filter calls may create multiple temps
    ctx = LiquidIL::Context.new
    template = ctx.parse("{{ 'hello' | append: ' ' | append: 'world' | upcase }}", optimize: true)

    result = template.render
    assert_equal "HELLO WORLD", result, "Nested filter chains should work correctly"
  end

  def test_complex_expression_with_temps
    # Complex expression with multiple subexpressions using temps
    ctx = LiquidIL::Context.new
    template = ctx.parse("{{ a | plus: b | times: c }}", optimize: true)

    result = template.render(a: 2, b: 3, c: 4)
    assert_equal "20", result, "Complex arithmetic expressions should work correctly"
  end

  def test_nested_conditionals_with_temps
    # Nested conditionals that may create temp usage patterns
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% if a %}{% if b %}both{% else %}just a{% endif %}{% else %}neither{% endif %}", optimize: true)

    assert_equal "both", template.render(a: true, b: true)
    assert_equal "just a", template.render(a: true, b: false)
    assert_equal "neither", template.render(a: false, b: true)
  end

  def test_capture_with_temps
    # Capture blocks that may interact with temp registers
    ctx = LiquidIL::Context.new
    template = ctx.parse("{% capture x %}{{ 'hello' | upcase }}{% endcapture %}{{ x | append: '!' }}", optimize: true)

    result = template.render
    assert_equal "HELLO!", result, "Captures with filter chains should work correctly"
  end

  def test_multiple_outputs_with_temps
    # Multiple output statements each potentially using temps
    ctx = LiquidIL::Context.new
    template = ctx.parse("{{ a | plus: 1 }}-{{ b | plus: 2 }}-{{ c | plus: 3 }}", optimize: true)

    result = template.render(a: 10, b: 20, c: 30)
    assert_equal "11-22-33", result, "Multiple outputs with temps should work correctly"
  end

  # ============================================================
  # TempLiveness unit tests
  # ============================================================

  def test_temp_liveness_last_use
    instructions = build_instructions do
      const_int(1)
      store_temp(0)  # idx 1
      load_temp(0)   # idx 2
      write_value

      const_int(2)
      store_temp(1)  # idx 5
      load_temp(1)   # idx 6 - first load
      load_temp(1)   # idx 7 - second load (last use)
      write_value
    end

    liveness = LiquidIL::TempLiveness.new(instructions)

    assert_equal 2, liveness.last_use(0), "temp 0 last used at index 2"
    assert_equal 7, liveness.last_use(1), "temp 1 last used at index 7 (second load)"
  end

  def test_temp_liveness_dead_after
    instructions = build_instructions do
      const_int(1)
      store_temp(0)  # idx 1
      const_int(2)
      store_temp(1)  # idx 3
      load_temp(0)   # idx 4 - t0 last use
      load_temp(1)   # idx 5 - t1 last use
      halt
    end

    liveness = LiquidIL::TempLiveness.new(instructions)

    # t0 is dead after index 4
    refute liveness.dead_after?(0, 3), "t0 is still live at index 3"
    assert liveness.dead_after?(0, 4), "t0 is dead after index 4"
    assert liveness.dead_after?(0, 5), "t0 is dead after index 5"

    # t1 is dead after index 5
    refute liveness.dead_after?(1, 4), "t1 is still live at index 4"
    assert liveness.dead_after?(1, 5), "t1 is dead after index 5"
  end

  def test_temp_liveness_live_at
    instructions = build_instructions do
      const_int(1)
      store_temp(0)  # idx 1
      const_int(2)
      store_temp(1)  # idx 3
      load_temp(0)   # idx 4
      load_temp(1)   # idx 5
      halt
    end

    liveness = LiquidIL::TempLiveness.new(instructions)

    # At index 2, both t0 and t1 are live (t1 not stored yet, but t0 is)
    live = liveness.live_at(2)
    assert_includes live, 0, "t0 should be live at index 2"

    # At index 4 (after t0 is loaded), only t1 is live
    live = liveness.live_at(4)
    assert_includes live, 1, "t1 should be live at index 4"
  end

  # ============================================================
  # RegisterAllocator.optimize API tests
  # ============================================================

  def test_register_allocator_optimize_api
    instructions = build_instructions do
      const_int(1)
      store_temp(0)
      load_temp(0)
      write_value

      const_int(2)
      store_temp(1)
      load_temp(1)
      write_value
    end

    result = LiquidIL::RegisterAllocator.optimize(instructions)

    # Should return the (modified) instructions array
    assert_kind_of Array, result
    assert_equal instructions.object_id, result.object_id, "optimize should return same array (in-place modification)"

    # Verify the optimization happened
    store_indices = extract_temp_indices(result, LiquidIL::IL::STORE_TEMP)
    assert_equal [0, 0], store_indices, "Non-overlapping temps should be optimized"
  end

  def test_register_allocator_handles_empty_instructions
    instructions = []
    result = LiquidIL::RegisterAllocator.optimize(instructions)
    assert_equal [], result
  end

  def test_register_allocator_handles_no_temps
    instructions = build_instructions do
      const_int(1)
      write_value
      halt
    end

    result = LiquidIL::RegisterAllocator.optimize(instructions)
    assert_equal 3, result.length  # const_int, write_value, halt
  end

  # ============================================================
  # Integration tests with the full compilation pipeline
  # ============================================================

  def test_optimized_context_uses_register_allocation
    ctx = LiquidIL::Context.new
    opt = LiquidIL::Optimizer.optimize(ctx)

    # Template with multiple filter chains that would create temps
    template = opt.parse("{{ x | plus: 1 | plus: 2 | plus: 3 }}")

    # Verify correctness
    result = template.render(x: 10)
    assert_equal "16", result
  end

  def test_complex_template_with_register_allocation
    ctx = LiquidIL::Context.new
    opt = LiquidIL::Optimizer.optimize(ctx)

    template = opt.parse(<<~LIQUID)
      {% for item in items %}
        {% if item.active %}
          {{ item.name | upcase | append: ': ' | append: item.value }}
        {% endif %}
      {% endfor %}
    LIQUID

    items = [
      { "name" => "a", "value" => "1", "active" => true },
      { "name" => "b", "value" => "2", "active" => false },
      { "name" => "c", "value" => "3", "active" => true }
    ]

    result = template.render(items: items).gsub(/\s+/, " ").strip
    assert_equal "A: 1 C: 3", result
  end
end
