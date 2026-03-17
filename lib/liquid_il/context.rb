# frozen_string_literal: true

module LiquidIL
  # Minimal scope for isolated render - just locals + static_environments
  # Optimized for hot-path performance with direct ivars instead of hash lookups
  class RenderScope
    attr_accessor :file_system, :render_errors, :current_file
    attr_reader :strict_errors

    def initialize(static_environments, file_system, depth = 0, strict_errors: false, render_errors: true)
      @static_environments = static_environments
      @locals = {}  # Always needed (assigns happen immediately)
      @file_system = file_system
      @depth = depth
      @strict_errors = strict_errors
      @render_errors = render_errors
      @current_file = nil
      # Lazy-init everything else
      @interrupts = nil
      @capture_stack = nil
      @for_stack = nil
      @temps = nil
      @for_offsets = nil
      @counters = nil
      @cycles = nil
    end

    def disable_include = true

    def lookup(key)
      key = key.to_s unless key.is_a?(String)
      if @locals.key?(key)
        @locals[key]
      else
        @static_environments&.[](key)
      end
    end

    # Alias for cleaner generated code
    alias [] lookup

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
      scope = RenderScope.new(@static_environments, @file_system, @depth, strict_errors: @strict_errors, render_errors: @render_errors)
      scope.current_file = @current_file
      scope
    end

    # Legacy registers accessor for compatibility
    def registers
      @registers ||= {
        "for" => (@for_offsets ||= {}),
        "for_stack" => (@for_stack ||= []),
        "counters" => (@counters ||= {}),
        "cycles" => (@cycles ||= {}),
        "temps" => (@temps ||= []),
        "capture_stack" => (@capture_stack ||= [])
      }
    end

    # Interrupt handling - lazy init
    def push_interrupt(type) = (@interrupts ||= []).push(type)
    def pop_interrupt = @interrupts&.pop
    def has_interrupt? = @interrupts ? !@interrupts.empty? : false
    def peek_interrupt = @interrupts&.last

    # Forloop - lazy init
    def for_stack = (@for_stack ||= [])
    def push_forloop(f) = (@for_stack ||= []).push(f)
    def pop_forloop = @for_stack&.pop
    def current_forloop = @for_stack&.last
    def parent_forloop = (@for_stack && @for_stack.length >= 2) ? @for_stack[-2] : nil

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

    # Temps - lazy init
    def store_temp(i, v) = (@temps ||= [])[i] = v
    def load_temp(i) = @temps ? @temps[i] : nil

    # Capture - lazy init
    def push_capture = (@capture_stack ||= []).push(String.new(capacity: 128))
    def pop_capture = @capture_stack ? (@capture_stack.pop || "") : ""
    def current_capture = @capture_stack&.last
    def capturing? = @capture_stack ? !@capture_stack.empty? : false
  end

  # Internal execution state with scope stack and registers
  # (Public API uses Context - this is the VM's internal state)
  class Scope
    attr_reader :strict_errors, :static_environments
    def scopes; @scopes || [@root_scope]; end
    attr_accessor :file_system, :disable_include, :render_errors, :current_file

    MAX_RENDER_DEPTH = 100


    def initialize(assigns = {}, registers: {}, strict_errors: false, static_environments: nil)
      if static_environments
        @static_environments = stringify_keys(static_environments)
        root_scope = stringify_keys(assigns)
      else
        # No explicit static_environments: assigns is both the initial context
        # and the mutable scope. We dup for static_environments so that
        # runtime assigns ({% assign %}) don't leak into isolated render scopes.
        all_strings = false
        if assigns.is_a?(Hash) && !assigns.empty?
          all_strings = true
          assigns.each_key { |k| unless k.is_a?(String); all_strings = false; break; end }
        end
        if all_strings
          root_scope = assigns
        else
          root_scope = stringify_keys(assigns)
        end
        @static_environments = root_scope.dup
      end
      @scopes = nil  # Lazy: only created on push_scope
      @root_scope = root_scope
      @top_scope = root_scope
      @strict_errors = strict_errors
      @render_errors = true
      @file_system = nil
      @disable_include = false
      @has_counters = false  # Fast flag: set true when increment/decrement used
      @render_depth = 0
      @current_file = nil
      # Lazy-init: only allocate when used
      @assigned_vars = nil
      @interrupts = nil
      @counters = nil
      @for_offsets = nil
      @for_stack_ref = nil
      @cycles = nil
      @temps = nil
      @capture_stack = nil
      # Pre-init from registers if provided (e.g. from render tag)
      unless registers.empty?
        r = registers.dup
        @for_offsets = r["for"] if r.key?("for")
        @for_stack_ref = r["for_stack"] if r.key?("for_stack")
        @counters = r["counters"] if r.key?("counters")
        @cycles = r["cycles"] if r.key?("cycles")
        @temps = r["temps"] if r.key?("temps")
        @capture_stack = r["capture_stack"] if r.key?("capture_stack")
      end
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

    def push_scope(scope = nil)
      new_scope = scope ? stringify_keys(scope) : {}
      # Lazy-create @scopes on first push
      @scopes ||= [@root_scope]
      @scopes.unshift(new_scope)
      @top_scope = new_scope
    end

    def pop_scope
      return unless @scopes && @scopes.length > 1
      @scopes.shift
      @top_scope = @scopes.first
    end

    def lookup(key)
      key = key.to_s unless key.is_a?(String)
      # Fast path: check top scope first (most common for loop vars, assigns)
      top = @top_scope
      if top.key?(key)
        # Ultra-fast path: no counters active (most common case)
        return top[key] unless @has_counters
        # But assigned vars take precedence over counters, check that
        return top[key] if (@assigned_vars && @assigned_vars[key]) || !@counters.key?(key)
      end
      # Check if this was explicitly assigned - assigned vars take precedence over counters
      if @has_counters && @assigned_vars && @assigned_vars[key]
        if @scopes
          @scopes.each do |scope|
            return scope[key] if scope.key?(key)
          end
        else
          return top[key] if top.key?(key)
        end
      end
      # Check counters - they shadow environment variables (but not assigned ones)
      return @counters[key] if @has_counters && @counters.key?(key)
      # Check remaining scopes (only when push_scope was called)
      if @scopes
        @scopes.each_with_index do |scope, i|
          next if i == 0 # already checked
          return scope[key] if scope.key?(key)
        end
      end
      # Check static_environments (shared with render)
      @static_environments[key] if @static_environments&.key?(key)
    end

    # Alias for cleaner generated code
    alias [] lookup

    def assign(key, value)
      key = key.to_s unless key.is_a?(String)
      # Track that this was explicitly assigned (takes precedence over counters)
      (@assigned_vars ||= {})[key] = true
      # Liquid assigns to the root/environment scope, not the current scope
      @root_scope[key] = value
    end

    # Assign to current (top) scope - used for loop variables that should be local
    def assign_local(key, value)
      @top_scope[key.is_a?(String) ? key : key.to_s] = value
    end

    def [](key)
      lookup(key)
    end

    def []=(key, value)
      assign(key, value)
    end

    # --- Interrupt handling ---

    def push_interrupt(type)
      (@interrupts ||= []).push(type)
    end

    def pop_interrupt
      @interrupts&.pop
    end

    def has_interrupt?
      @interrupts ? !@interrupts.empty? : false
    end

    def peek_interrupt
      @interrupts&.last
    end

    def interrupts
      @interrupts ||= []
    end

    # --- Forloop stack (using cached @for_stack_ref for performance) ---

    def for_stack
      @for_stack_ref ||= []
    end

    def push_forloop(forloop)
      (@for_stack_ref ||= []).push(forloop)
    end

    def pop_forloop
      @for_stack_ref&.pop
    end

    def current_forloop
      @for_stack_ref&.last
    end

    def parent_forloop
      return nil unless @for_stack_ref && @for_stack_ref.length >= 2
      @for_stack_ref[-2]
    end

    # --- Counter management ---

    def increment(name)
      @has_counters = true
      counters = (@counters ||= {})
      counters[name] ||= 0
      result = counters[name]
      counters[name] += 1
      result
    end

    def decrement(name)
      @has_counters = true
      counters = (@counters ||= {})
      counters[name] ||= 0
      counters[name] -= 1
      counters[name]
    end

    # --- Cycle management ---

    def cycle_step(identity, values)
      return nil if values.empty?
      cycles = (@cycles ||= {})
      cycles[identity] ||= 0
      idx = cycles[identity] % values.length
      cycles[identity] += 1
      values[idx]
    end

    # --- Offset:continue tracking ---

    def for_offset(loop_name)
      @for_offsets ? (@for_offsets[loop_name] || 0) : 0
    end

    def set_for_offset(loop_name, offset)
      (@for_offsets ||= {})[loop_name] = offset
    end

    # --- Temp storage ---

    def store_temp(index, value)
      (@temps ||= [])[index] = value
    end

    def load_temp(index)
      @temps ? @temps[index] : nil
    end

    # --- Ifchanged state ---

    def get_ifchanged_state(tag_id)
      @ifchanged ? @ifchanged[tag_id] : nil
    end

    def set_ifchanged_state(tag_id, value)
      (@ifchanged ||= {})[tag_id] = value
    end

    # --- Capture ---

    def push_capture
      (@capture_stack ||= []).push(String.new(capacity: 128))
    end

    def pop_capture
      @capture_stack.pop || ""
    end

    def current_capture
      @capture_stack&.last
    end

    def capturing?
      @capture_stack ? !@capture_stack.empty? : false
    end

    # Build registers hash on demand (for compatibility with code that reads it)
    def registers
      {
        "for" => (@for_offsets ||= {}),
        "for_stack" => (@for_stack_ref ||= []),
        "counters" => (@counters ||= {}),
        "cycles" => (@cycles ||= {}),
        "temps" => (@temps ||= []),
        "capture_stack" => (@capture_stack ||= [])
      }
    end

    # --- Isolation for render ---

    def isolated
      scope = RenderScope.new(@static_environments, @file_system, @render_depth, strict_errors: @strict_errors, render_errors: @render_errors)
      scope.current_file = @current_file
      scope
    end

    private

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)
      return hash.dup if hash.empty?
      # Check if all keys are already strings
      all_strings = true
      hash.each_key { |k| unless k.is_a?(String); all_strings = false; break; end }
      if all_strings
        hash.dup  # Must dup to avoid aliasing between static_environments and root_scope
      else
        result = {}
        hash.each { |k, v| result[k.to_s] = v }
        result
      end
    end
  end

  # Empty literal - used for `== empty` comparisons
  class EmptyLiteral
    def self.instance
      @instance ||= new
    end

    def ==(other)
      case other
      when EmptyLiteral, BlankLiteral then false  # empty/blank never equal each other
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
      when EmptyLiteral, BlankLiteral then false  # empty/blank never equal each other
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
      # Validate range bounds - floats are not allowed (matches Liquid Ruby behavior)
      if start_val.is_a?(Float) || end_val.is_a?(Float)
        raise LiquidIL::RuntimeError.new("invalid integer", line: 1)
      end
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
