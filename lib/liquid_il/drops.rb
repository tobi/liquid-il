# frozen_string_literal: true

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
      %w[index index0 rindex rindex0 first last length parentloop].include?(key.to_s)
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

    def initialize(name, length, cols, parentloop = nil)
      super(name, length, parentloop)
      @cols = cols
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
      col0 == @cols - 1 || @index0 == @length - 1
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

  # Base class for custom drops (for user-defined objects)
  class Drop
    def [](key)
      respond_to?(key) ? send(key) : nil
    end

    def key?(key)
      respond_to?(key)
    end

    def liquid_method_missing(_method)
      nil
    end

    def to_liquid
      self
    end
  end
end
