# frozen_string_literal: true

module LiquidIL
  # Internal execution state with scope stack and registers
  # (Public API uses Context - this is the VM's internal state)
  class Scope
    attr_reader :registers, :scopes, :interrupts, :strict_errors
    attr_accessor :file_system

    def initialize(assigns = {}, registers: {}, strict_errors: false)
      @scopes = [stringify_keys(assigns)]
      @registers = registers.dup
      @interrupts = []
      @strict_errors = strict_errors
      @file_system = nil

      # Initialize special registers
      @registers["for"] ||= {}      # offset:continue tracking
      @registers["for_stack"] ||= [] # forloop stack for parentloop
      @registers["counters"] ||= {} # increment/decrement counters
      @registers["cycles"] ||= {}   # cycle state
      @registers["temps"] ||= []    # temporary storage
      @registers["capture_stack"] ||= [] # capture buffers
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
      @scopes.each do |scope|
        return scope[key] if scope.key?(key)
      end
      # Fall back to increment/decrement counters
      counters = @registers["counters"]
      return counters[key] if counters&.key?(key)
      nil
    end

    def assign(key, value)
      # Liquid assigns to the root/environment scope, not the current scope
      @scopes.last[key.to_s] = value
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
      iso = Scope.new({}, registers: {}, strict_errors: @strict_errors)
      iso.file_system = @file_system
      # Copy environment but not registers
      iso.scopes[0] = @scopes.last.dup
      iso
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
