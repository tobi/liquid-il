# frozen_string_literal: true

module LiquidIL
  # Minimal scope for isolated render - just locals + static_environments
  # Optimized for hot-path performance with direct ivars instead of hash lookups
  class RenderScope
    attr_accessor :file_system

    def initialize(static_environments, file_system, depth = 0)
      @static_environments = static_environments
      @locals = {}
      @file_system = file_system
      @depth = depth
      # Eagerly initialize hot-path arrays as direct ivars
      @interrupts = []
      @capture_stack = []
      @for_stack = []
      @temps = []
      # Lazy-init hashes (less frequently accessed)
      @for_offsets = nil
      @counters = nil
      @cycles = nil
    end

    def disable_include = true

    def lookup(key)
      key = key.to_s unless key.is_a?(String)
      @locals[key] || @static_environments&.[](key)
    end

    def assign(key, value)
      key = key.to_s unless key.is_a?(String)
      @locals[key] = value
    end

    alias assign_local assign

    def push_scope(scope = {}) = nil
    def pop_scope = nil

    # Render depth - needed for nested render calls
    def push_render_depth = @depth += 1
    def pop_render_depth; @depth -= 1 if @depth > 0; end
    def render_depth_exceeded?(strict: false) = strict ? @depth >= 100 : @depth > 100

    def isolated
      RenderScope.new(@static_environments, @file_system, @depth)
    end

    # Legacy registers accessor for compatibility
    def registers
      @registers ||= {
        "for" => (@for_offsets ||= {}),
        "for_stack" => @for_stack,
        "counters" => (@counters ||= {}),
        "cycles" => (@cycles ||= {}),
        "temps" => @temps,
        "capture_stack" => @capture_stack
      }
    end

    # Interrupt handling - direct ivar access (hot path)
    def push_interrupt(type) = @interrupts.push(type)
    def pop_interrupt = @interrupts.pop
    def has_interrupt? = !@interrupts.empty?
    def peek_interrupt = @interrupts.last

    # Forloop - direct ivar access (hot path)
    def for_stack = @for_stack
    def push_forloop(f) = @for_stack.push(f)
    def pop_forloop = @for_stack.pop
    def current_forloop = @for_stack.last
    def parent_forloop = @for_stack.length < 2 ? nil : @for_stack[-2]

    # Counters - lazy hash init
    def increment(n)
      counters = (@counters ||= {})
      (counters[n] ||= 0).tap { counters[n] += 1 }
    end

    def decrement(n)
      counters = (@counters ||= {})
      counters[n] = (counters[n] || 0) - 1
    end

    # Cycles - lazy hash init
    def cycle_step(id, vals)
      return nil if vals.empty?
      cycles = (@cycles ||= {})
      cycles[id] ||= 0
      vals[cycles[id] % vals.length].tap { cycles[id] += 1 }
    end

    # For offset - lazy hash init
    def for_offset(n) = (@for_offsets ||= {})[n] || 0
    def set_for_offset(n, o) = (@for_offsets ||= {})[n] = o

    # Temps - direct ivar access
    def store_temp(i, v) = @temps[i] = v
    def load_temp(i) = @temps[i]

    # Capture - direct ivar access (hot path)
    # Pre-allocate with small capacity to reduce reallocations
    def push_capture = @capture_stack.push(String.new(capacity: 128))
    def pop_capture = @capture_stack.pop || ""
    def current_capture = @capture_stack.last
    def capturing? = !@capture_stack.empty?
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

      # Cache hot-path references for performance
      @capture_stack = @registers["capture_stack"]
      @for_stack_ref = @registers["for_stack"]
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
      key = key.to_s unless key.is_a?(String)
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
      @static_environments[key] if @static_environments&.key?(key)
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

    # --- Forloop stack (using cached @for_stack_ref for performance) ---

    def for_stack
      @for_stack_ref
    end

    def push_forloop(forloop)
      @for_stack_ref.push(forloop)
    end

    def pop_forloop
      @for_stack_ref.pop
    end

    def current_forloop
      @for_stack_ref.last
    end

    def parent_forloop
      return nil if @for_stack_ref.length < 2
      @for_stack_ref[-2]
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

    # --- Capture (using cached @capture_stack for performance) ---

    def push_capture
      @capture_stack.push(String.new(capacity: 128))
    end

    def pop_capture
      @capture_stack.pop || ""
    end

    def current_capture
      @capture_stack.last
    end

    def capturing?
      !@capture_stack.empty?
    end

    # --- Isolation for render ---

    def isolated
      RenderScope.new(@static_environments, @file_system, @render_depth)
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
