# frozen_string_literal: true

require "set"

module LiquidIL
  # Forloop drop - provides iteration metadata
  class ForloopDrop
    attr_reader :name, :length, :parentloop
    attr_accessor :index0

    def initialize(name, length, parentloop = nil)
      @name = name
      @length = length
      @parentloop = parentloop
      @index0 = 0
    end

    # 1-based index
    def index
      @index0 + 1
    end

    # Reverse 1-based index (n, n-1, ..., 1)
    def rindex
      @length - @index0
    end

    # Reverse 0-based index (n-1, n-2, ..., 0)
    def rindex0
      @length - @index0 - 1
    end

    def first
      @index0 == 0
    end

    def last
      @index0 == @length - 1
    end

    def increment
      @index0 += 1
    end

    # Property access for lookups
    def [](key)
      case key.to_s
      when "name" then @name
      when "index" then index
      when "index0" then @index0
      when "rindex" then rindex
      when "rindex0" then rindex0
      when "first" then first
      when "last" then last
      when "length" then @length
      when "parentloop" then @parentloop
      else nil
      end
    end

    def key?(key)
      %w[name index index0 rindex rindex0 first last length parentloop].include?(key.to_s)
    end

    def to_s
      "ForloopDrop"
    end

    def liquid_method_missing(method)
      nil
    end
  end

  # Tablerow forloop - extends forloop with row/col info
  class TablerowloopDrop < ForloopDrop
    attr_reader :cols, :col, :row

    def initialize(name, length, cols, parentloop = nil, cols_explicit_nil = false)
      super(name, length, parentloop)
      @cols = cols
      @cols_explicit_nil = cols_explicit_nil  # true when cols:nil was explicitly written
      @col = 0
      @row = 0
    end

    def col
      (@index0 % @cols) + 1
    end

    def col0
      @index0 % @cols
    end

    def row
      (@index0 / @cols) + 1
    end

    def col_first
      col0 == 0
    end

    def col_last
      # When cols:nil is explicitly written, col_last is always false
      return false if @cols_explicit_nil
      # col_last is only true when at the last column position (cols-1 in 0-indexed)
      col0 == @cols - 1
    end

    def [](key)
      case key.to_s
      when "col" then col
      when "col0" then col0
      when "row" then row
      when "col_first" then col_first
      when "col_last" then col_last
      else super
      end
    end
  end

  # Base class for custom drops — the safe gateway for Ruby objects in templates.
  #
  # Only methods defined on the subclass are accessible from templates.
  # All methods inherited from Object/Kernel/Drop base are blacklisted.
  # This prevents templates from calling send, instance_eval, class, system, etc.
  #
  # Compatible with Liquid::Drop's security model:
  #   - invokable_methods = subclass public methods - Drop base methods - Object methods
  #   - [] routes through invoke_drop which checks the whitelist
  #   - to_liquid returns self
  #   - liquid_method_missing called for undefined properties
  #
  # Usage:
  #   class ProductDrop < LiquidIL::Drop
  #     def name; @product.name; end
  #     def price; @product.price; end
  #   end
  #
  #   # In template: {{ product.name }} works, {{ product.class }} returns nil
  #
  class Drop
    attr_writer :context

    def initialize
      @context = nil
    end

    # Called when a property is not in the whitelist.
    # Override to provide custom fallback behavior.
    def liquid_method_missing(method)
      nil
    end

    # Safe property access — only whitelisted methods are callable.
    def invoke_drop(method_or_key)
      if self.class.invokable?(method_or_key)
        send(method_or_key)
      else
        liquid_method_missing(method_or_key)
      end
    end

    def key?(_name)
      true
    end

    def inspect
      self.class.to_s
    end

    def to_liquid
      self
    end

    def to_s
      self.class.name
    end

    # [] is the only entry point for template property access.
    # Routes through invoke_drop for security.
    alias_method :[], :invoke_drop

    # --- Class-level security machinery ---

    # Check if a method name is safe to call from templates
    def self.invokable?(method_name)
      invokable_methods.include?(method_name.to_s)
    end

    # Compute the set of safe methods for this Drop subclass.
    # Blacklist: all methods from Drop base class + Object + Kernel + Enumerable.
    # Whitelist: only methods defined on the subclass itself.
    def self.invokable_methods
      @invokable_methods ||= begin
        # Everything from the Drop base class and its ancestors is blacklisted
        blacklist = LiquidIL::Drop.public_instance_methods + [:each]

        # If the drop includes Enumerable, blacklist those too
        # but keep the useful ones that Liquid allows
        if include?(Enumerable)
          blacklist += Enumerable.public_instance_methods
          blacklist -= [:sort, :count, :first, :min, :max]
        end

        # Whitelist = subclass public methods minus blacklist, plus to_liquid
        whitelist = [:to_liquid] + (public_instance_methods - blacklist)
        Set.new(whitelist.map(&:to_s))
      end
    end
  end

  # Wraps a Liquid::Drop for use in LiquidIL.
  # Delegates property access through Liquid's own invoke_drop security.
  # This means existing Liquid::Drop subclasses work unchanged.
  module LiquidDropCompat
    # Call this on a value to make it safe for template use.
    # - Liquid::Drop subclasses: wrapped to use their invoke_drop
    # - LiquidIL::Drop subclasses: already safe
    # - Hashes, Arrays, Strings, Numbers, nil, bool: safe as-is
    # - Other objects with to_liquid: call to_liquid
    # - Unknown objects: return nil (reject)
    def self.sanitize(value)
      case value
      when nil, true, false, String, Integer, Float, Hash, Array
        value
      when LiquidIL::Drop, LiquidIL::ForloopDrop
        value
      when LiquidIL::RangeValue
        value
      else
        # Check for to_liquid (Liquid::Drop, custom objects)
        if value.respond_to?(:to_liquid)
          liquid_value = value.to_liquid
          # If to_liquid returns self, the object is a drop — it handles its own security
          # via invoke_drop. If it returns something else, sanitize that.
          liquid_value.equal?(value) ? value : sanitize(liquid_value)
        else
          # Unknown object type — not safe to expose to templates
          nil
        end
      end
    end
  end
end
