# frozen_string_literal: true

module LiquidIL
  # Lightweight scope for isolated render - avoids full Scope overhead
  class RenderScope
    attr_accessor :file_system
    attr_reader :registers

    def initialize(static_environments, render_depth, file_system)
      @static_environments = static_environments
      @locals = {}
      @render_depth = render_depth
      @file_system = file_system
      @registers = {
        "for" => {},
        "for_stack" => [],
        "counters" => {},
        "cycles" => {},
        "temps" => [],
        "capture_stack" => []
      }
      @interrupts = []
    end

    def disable_include = true

    def lookup(key)
      key = key.to_s
      return @locals[key] if @locals.key?(key)
      @static_environments&.[](key)
    end

    def assign(key, value)
      @locals[key.to_s] = value
    end

    def assign_local(key, value)
      @locals[key.to_s] = value
    end

    def push_scope(scope = {}) = nil
    def pop_scope = nil

    def push_render_depth
      @render_depth += 1
    end

    def pop_render_depth
      @render_depth -= 1 if @render_depth > 0
    end

    def render_depth_exceeded?(strict: false)
      strict ? @render_depth >= 100 : @render_depth > 100
    end

    def render_depth = @render_depth

    def isolated
      RenderScope.new(@static_environments, @render_depth, @file_system)
    end

    # Interrupt handling
    def push_interrupt(type) = @interrupts.push(type)
    def pop_interrupt = @interrupts.pop
    def has_interrupt? = !@interrupts.empty?
    def peek_interrupt = @interrupts.last

    # Forloop stack
    def for_stack = @registers["for_stack"]
    def push_forloop(f) = for_stack.push(f)
    def pop_forloop = for_stack.pop
    def current_forloop = for_stack.last
    def parent_forloop = for_stack.length < 2 ? nil : for_stack[-2]

    # Counters
    def increment(name)
      @registers["counters"][name] ||= 0
      r = @registers["counters"][name]
      @registers["counters"][name] += 1
      r
    end

    def decrement(name)
      @registers["counters"][name] ||= 0
      @registers["counters"][name] -= 1
    end

    # Cycles
    def cycle_step(identity, values)
      return nil if values.empty?
      @registers["cycles"][identity] ||= 0
      idx = @registers["cycles"][identity] % values.length
      @registers["cycles"][identity] += 1
      values[idx]
    end

    # For offset tracking
    def for_offset(name) = @registers["for"][name] || 0
    def set_for_offset(name, offset) = @registers["for"][name] = offset

    # Temps
    def store_temp(i, v) = @registers["temps"][i] = v
    def load_temp(i) = @registers["temps"][i]

    # Capture
    def push_capture = @registers["capture_stack"].push(String.new)
    def pop_capture = @registers["capture_stack"].pop || ""
    def current_capture = @registers["capture_stack"].last
    def capturing? = !@registers["capture_stack"].empty?
  end

  # Internal execution state with scope stack and registers
  # (Public API uses Context - this is the VM's internal state)
  class Scope
    attr_reader :registers, :scopes, :interrupts, :strict_errors, :static_environments
    attr_accessor :file_system, :disable_include

    MAX_RENDER_DEPTH = 100

    def initialize(assigns = {}, registers: {}, strict_errors: false, static_environments: nil)
      @static_environments = stringify_keys(static_environments || assigns)
      @scopes = [stringify_keys(assigns)]
      @registers = registers.dup
      @interrupts = []
      @strict_errors = strict_errors
      @file_system = nil
      @disable_include = false  # Set to true inside render tag to disallow include
      @assigned_vars = {}  # Track explicitly assigned variables (take precedence over counters)
      @render_depth = 0  # Track render/include nesting depth

      # Initialize special registers
      @registers["for"] ||= {}      # offset:continue tracking
      @registers["for_stack"] ||= [] # forloop stack for parentloop
      @registers["counters"] ||= {} # increment/decrement counters
      @registers["cycles"] ||= {}   # cycle state
      @registers["temps"] ||= []    # temporary storage
      @registers["capture_stack"] ||= [] # capture buffers
    end

    # --- Render depth tracking ---

    def push_render_depth
      @render_depth += 1
      @render_depth
    end

    def render_depth_exceeded?(strict: false)
      # include uses >= (strict), render uses > (allows one more level)
      strict ? @render_depth >= MAX_RENDER_DEPTH : @render_depth > MAX_RENDER_DEPTH
    end

    def pop_render_depth
      @render_depth -= 1 if @render_depth > 0
    end

    def render_depth
      @render_depth
    end

    # --- Scope management ---

    def push_scope(scope = {})
      @scopes.unshift(stringify_keys(scope))
    end

    def pop_scope
      @scopes.shift if @scopes.length > 1
    end

    def lookup(key)
      key = key.to_s
      # Check if this was explicitly assigned - assigned vars take precedence over counters
      if @assigned_vars[key]
        @scopes.each do |scope|
          return scope[key] if scope.key?(key)
        end
      end
      # Check counters - they shadow environment variables (but not assigned ones)
      counters = @registers["counters"]
      return counters[key] if counters&.key?(key)
      # Check scope chain for environment variables
      @scopes.each do |scope|
        return scope[key] if scope.key?(key)
      end
      # Check static_environments (shared with render)
      return @static_environments[key] if @static_environments&.key?(key)
      nil
    end

    def assign(key, value)
      key = key.to_s
      # Track that this was explicitly assigned (takes precedence over counters)
      @assigned_vars[key] = true
      # Liquid assigns to the root/environment scope, not the current scope
      @scopes.last[key] = value
    end

    # Assign to current (top) scope - used for loop variables that should be local
    def assign_local(key, value)
      key = key.to_s
      @scopes.first[key] = value
    end

    def [](key)
      lookup(key)
    end

    def []=(key, value)
      assign(key, value)
    end

    # --- Interrupt handling ---

    def push_interrupt(type)
      @interrupts.push(type)
    end

    def pop_interrupt
      @interrupts.pop
    end

    def has_interrupt?
      !@interrupts.empty?
    end

    def peek_interrupt
      @interrupts.last
    end

    # --- Forloop stack ---

    def for_stack
      @registers["for_stack"]
    end

    def push_forloop(forloop)
      for_stack.push(forloop)
    end

    def pop_forloop
      for_stack.pop
    end

    def current_forloop
      for_stack.last
    end

    def parent_forloop
      return nil if for_stack.length < 2
      for_stack[-2]
    end

    # --- Counter management ---

    def increment(name)
      counters = @registers["counters"]
      counters[name] ||= 0
      result = counters[name]
      counters[name] += 1
      result
    end

    def decrement(name)
      counters = @registers["counters"]
      counters[name] ||= 0
      counters[name] -= 1
      counters[name]
    end

    # --- Cycle management ---

    def cycle_step(identity, values)
      return nil if values.empty?
      cycles = @registers["cycles"]
      cycles[identity] ||= 0
      idx = cycles[identity] % values.length
      cycles[identity] += 1
      values[idx]
    end

    # --- Offset:continue tracking ---

    def for_offset(loop_name)
      @registers["for"][loop_name] || 0
    end

    def set_for_offset(loop_name, offset)
      @registers["for"][loop_name] = offset
    end

    # --- Temp storage ---

    def store_temp(index, value)
      @registers["temps"][index] = value
    end

    def load_temp(index)
      @registers["temps"][index]
    end

    # --- Ifchanged state ---

    def get_ifchanged_state(tag_id)
      @registers["ifchanged"] ||= {}
      @registers["ifchanged"][tag_id]
    end

    def set_ifchanged_state(tag_id, value)
      @registers["ifchanged"] ||= {}
      @registers["ifchanged"][tag_id] = value
    end

    # --- Capture ---

    def push_capture
      @registers["capture_stack"].push(String.new)
    end

    def pop_capture
      @registers["capture_stack"].pop || ""
    end

    def current_capture
      @registers["capture_stack"].last
    end

    def capturing?
      !@registers["capture_stack"].empty?
    end

    # --- Isolation for render ---

    def isolated
      RenderScope.new(@static_environments, @render_depth, @file_system)
    end

    private

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)
      result = {}
      hash.each do |k, v|
        result[k.to_s] = v
      end
      result
    end
  end

  # Empty literal - used for `== empty` comparisons
  class EmptyLiteral
    def self.instance
      @instance ||= new
    end

    def ==(other)
      case other
      when EmptyLiteral then true
      when String then other.empty?
      when Array then other.empty?
      when Hash then other.empty?
      else false
      end
    end

    def to_s
      ""
    end
  end

  # Blank literal - used for `== blank` comparisons
  class BlankLiteral
    def self.instance
      @instance ||= new
    end

    def ==(other)
      case other
      when BlankLiteral then true
      when nil then true
      when false then true
      when String then other.empty? || other.strip.empty?
      when Array then other.empty?
      when Hash then other.empty?
      else false
      end
    end

    def to_s
      ""
    end
  end

  # Range value for ranges
  class RangeValue
    attr_reader :start_val, :end_val

    def initialize(start_val, end_val)
      @start_val = start_val.to_i
      @end_val = end_val.to_i
    end

    def to_a
      (@start_val..@end_val).to_a
    end

    def to_s
      "#{@start_val}..#{@end_val}"
    end

    def each(&block)
      (@start_val..@end_val).each(&block)
    end

    def length
      [@end_val - @start_val + 1, 0].max
    end

    alias_method :size, :length

    def first
      @start_val
    end

    def last
      @end_val
    end

    def ==(other)
      case other
      when RangeValue
        @start_val == other.start_val && @end_val == other.end_val
      when Range
        @start_val == other.begin && @end_val == other.end && !other.exclude_end?
      else
        false
      end
    end

    def eql?(other)
      self == other
    end

    def hash
      [@start_val, @end_val].hash
    end
  end
end
