# frozen_string_literal: true

# Pure-Ruby polyfill for StringView::Strict
# Drop-in replacement when the C extension (string_view gem) is unavailable.
# Provides a zero-copy view into a source string using offset + length.
#
# This polyfill implements only the API surface used by LiquidIL:
#   .new(source, offset, length), .materialize, .empty?, .length/.bytesize,
#   .getbyte, .include?, .==, .hash, .rstrip, .lstrip, .freeze, .inspect,
#   .to_s (raises WouldAllocate in Strict mode)

class StringView
  class WouldAllocate < StandardError; end

  attr_reader :length

  def initialize(source, offset, length)
    @source = source
    @offset = offset
    @length = length
  end

  # Materialize to a real String (the only sanctioned way to get a String)
  def materialize
    @source.byteslice(@offset, @length)
  end

  alias_method :bytesize, :length
  alias_method :size, :length

  def empty?
    @length == 0
  end

  def getbyte(index)
    return nil if index < 0 || index >= @length
    @source.getbyte(@offset + index)
  end

  def include?(str)
    # Use byteindex for fast search within our region
    str_bytes = str.bytesize
    return true if str_bytes == 0
    return false if str_bytes > @length

    limit = @offset + @length - str_bytes
    pos = @source.byteindex(str, @offset)
    pos != nil && pos <= limit
  end

  def ==(other)
    case other
    when String
      other.bytesize == @length && materialize == other
    when StringView
      @length == other.length && materialize == other.materialize
    else
      false
    end
  end
  alias_method :eql?, :==

  def hash
    materialize.hash
  end

  def rstrip
    pos = @offset + @length - 1
    while pos >= @offset
      b = @source.getbyte(pos)
      break unless b == 32 || b == 9 || b == 10 || b == 13  # space, tab, LF, CR
      pos -= 1
    end
    new_len = pos - @offset + 1
    new_len = 0 if new_len < 0
    self.class.new(@source, @offset, new_len)
  end

  def lstrip
    pos = @offset
    limit = @offset + @length
    while pos < limit
      b = @source.getbyte(pos)
      break unless b == 32 || b == 9 || b == 10 || b == 13
      pos += 1
    end
    self.class.new(@source, pos, limit - pos)
  end

  def strip
    lstrip.rstrip
  end

  def start_with?(*prefixes)
    materialize.start_with?(*prefixes)
  end

  def end_with?(*suffixes)
    materialize.end_with?(*suffixes)
  end

  def encoding
    @source.encoding
  end

  def to_s
    raise WouldAllocate,
      "#{self.class}#to_s would allocate a String — call .materialize to get a String, or use the view directly"
  end

  def inspect
    "#<StringView:0x#{object_id.to_s(16)} #{materialize.inspect} offset=#{@offset} length=#{@length}>"
  end

  def freeze
    # StringView is already effectively immutable (offset/length don't change)
    super
  end

  def <=>(other)
    materialize <=> (other.is_a?(StringView) ? other.materialize : other)
  end

  # Allow + with strings (materialize first)
  def +(other)
    materialize + (other.is_a?(StringView) ? other.materialize : other)
  end

  # Strict subclass — identical behavior, just a separate class for type identity
  class Strict < self; end
end
