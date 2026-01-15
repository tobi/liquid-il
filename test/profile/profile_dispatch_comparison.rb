# frozen_string_literal: true

# Compare dispatch mechanisms for VM optimization

# Simulate opcodes
module SymbolOpcodes
  WRITE_RAW = :WRITE_RAW
  WRITE_VALUE = :WRITE_VALUE
  FIND_VAR = :FIND_VAR
  LOOKUP_KEY = :LOOKUP_KEY
  LABEL = :LABEL
  JUMP = :JUMP
  HALT = :HALT
end

module IntegerOpcodes
  WRITE_RAW = 0
  WRITE_VALUE = 1
  FIND_VAR = 2
  LOOKUP_KEY = 3
  LABEL = 4
  JUMP = 5
  HALT = 6
end

# Simulated instructions (mixed workload)
SYMBOL_INSTRUCTIONS = [
  [:WRITE_RAW, "hello"],
  [:FIND_VAR, "name"],
  [:LOOKUP_KEY, "title"],
  [:WRITE_VALUE],
  [:LABEL, 1],
  [:JUMP, 0],
  [:WRITE_RAW, " world"],
  [:HALT]
] * 100

INTEGER_INSTRUCTIONS = SYMBOL_INSTRUCTIONS.map do |inst|
  case inst[0]
  when :WRITE_RAW then [0, inst[1]]
  when :WRITE_VALUE then [1]
  when :FIND_VAR then [2, inst[1]]
  when :LOOKUP_KEY then [3, inst[1]]
  when :LABEL then [4, inst[1]]
  when :JUMP then [5, inst[1]]
  when :HALT then [6]
  end
end

# Pre-stripped instructions (no LABELs)
NO_LABEL_INSTRUCTIONS = INTEGER_INSTRUCTIONS.reject { |i| i[0] == 4 }

# Approach 1: Symbol case/when (current)
def run_symbol_case(instructions)
  pc = 0
  count = 0
  while pc < instructions.length
    inst = instructions[pc]
    case inst[0]
    when :WRITE_RAW then count += 1
    when :WRITE_VALUE then count += 1
    when :FIND_VAR then count += 1
    when :LOOKUP_KEY then count += 1
    when :LABEL then nil
    when :JUMP then nil
    when :HALT then break
    end
    pc += 1
  end
  count
end

# Approach 2: Integer case/when
def run_integer_case(instructions)
  pc = 0
  count = 0
  while pc < instructions.length
    inst = instructions[pc]
    case inst[0]
    when 0 then count += 1  # WRITE_RAW
    when 1 then count += 1  # WRITE_VALUE
    when 2 then count += 1  # FIND_VAR
    when 3 then count += 1  # LOOKUP_KEY
    when 4 then nil         # LABEL
    when 5 then nil         # JUMP
    when 6 then break       # HALT
    end
    pc += 1
  end
  count
end

# Approach 3: Dispatch table (array of lambdas)
DISPATCH_TABLE = [
  ->(inst, state) { state[:count] += 1; state[:pc] += 1 },  # 0: WRITE_RAW
  ->(inst, state) { state[:count] += 1; state[:pc] += 1 },  # 1: WRITE_VALUE
  ->(inst, state) { state[:count] += 1; state[:pc] += 1 },  # 2: FIND_VAR
  ->(inst, state) { state[:count] += 1; state[:pc] += 1 },  # 3: LOOKUP_KEY
  ->(inst, state) { state[:pc] += 1 },                      # 4: LABEL
  ->(inst, state) { state[:pc] += 1 },                      # 5: JUMP
  ->(inst, state) { state[:halt] = true },                  # 6: HALT
].freeze

def run_dispatch_table(instructions)
  state = { pc: 0, count: 0, halt: false }
  while state[:pc] < instructions.length && !state[:halt]
    inst = instructions[state[:pc]]
    DISPATCH_TABLE[inst[0]].call(inst, state)
  end
  state[:count]
end

# Approach 4: Integer case with no labels (pre-stripped)
def run_integer_no_labels(instructions)
  pc = 0
  count = 0
  while pc < instructions.length
    inst = instructions[pc]
    case inst[0]
    when 0 then count += 1  # WRITE_RAW
    when 1 then count += 1  # WRITE_VALUE
    when 2 then count += 1  # FIND_VAR
    when 3 then count += 1  # LOOKUP_KEY
    when 5 then nil         # JUMP
    when 6 then break       # HALT
    end
    pc += 1
  end
  count
end

# Approach 5: Direct method calls via send (method dispatch)
class MethodDispatchVM
  def initialize
    @count = 0
    @pc = 0
    @halt = false
  end

  def op_0(inst) = (@count += 1; @pc += 1)  # WRITE_RAW
  def op_1(inst) = (@count += 1; @pc += 1)  # WRITE_VALUE
  def op_2(inst) = (@count += 1; @pc += 1)  # FIND_VAR
  def op_3(inst) = (@count += 1; @pc += 1)  # LOOKUP_KEY
  def op_4(inst) = (@pc += 1)               # LABEL
  def op_5(inst) = (@pc += 1)               # JUMP
  def op_6(inst) = (@halt = true)           # HALT

  def run(instructions)
    @count = 0
    @pc = 0
    @halt = false
    while @pc < instructions.length && !@halt
      inst = instructions[@pc]
      send(:"op_#{inst[0]}", inst)
    end
    @count
  end
end

METHOD_VM = MethodDispatchVM.new

def run_method_dispatch(instructions)
  METHOD_VM.run(instructions)
end

puts "Comparing VM dispatch mechanisms"
puts "Instructions: #{SYMBOL_INSTRUCTIONS.length} (with labels)"
puts "Instructions: #{NO_LABEL_INSTRUCTIONS.length} (without labels)"
puts

ITERATIONS = 10_000

def measure(name)
  GC.start
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "#{name.ljust(22)} #{(elapsed * 1000).round(2)}ms (#{(elapsed / ITERATIONS * 1_000_000).round(1)}µs/iter)"
  elapsed
end

results = {}
results[:symbol] = measure("symbol case/when") { ITERATIONS.times { run_symbol_case(SYMBOL_INSTRUCTIONS) } }
results[:integer] = measure("integer case/when") { ITERATIONS.times { run_integer_case(INTEGER_INSTRUCTIONS) } }
results[:dispatch] = measure("dispatch table") { ITERATIONS.times { run_dispatch_table(INTEGER_INSTRUCTIONS) } }
results[:method] = measure("method dispatch") { ITERATIONS.times { run_method_dispatch(INTEGER_INSTRUCTIONS) } }
results[:no_labels] = measure("int case no labels") { ITERATIONS.times { run_integer_no_labels(NO_LABEL_INSTRUCTIONS) } }

puts
puts "Speedup vs symbol case/when:"
puts "  integer case/when: #{(results[:symbol] / results[:integer]).round(2)}x"
puts "  dispatch table:    #{(results[:symbol] / results[:dispatch]).round(2)}x"
puts "  method dispatch:   #{(results[:symbol] / results[:method]).round(2)}x"
puts "  int + no labels:   #{(results[:symbol] / results[:no_labels]).round(2)}x"
