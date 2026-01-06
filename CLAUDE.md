# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LiquidIL is a high-performance Liquid template implementation that compiles Liquid templates to an Intermediate Language (IL) for optimized execution. The project prioritizes:

1. **Zero-allocation hot paths** - Use StringScanner `skip` instead of `scan`, byte lookup tables, deferred string extraction
2. **Solving problems at the right level** - Parse-time decisions in lexer/parser, compile-time optimizations via IL passes, runtime only when necessary
3. **Code that tenderlove would be proud of** - Performance-conscious Ruby following the patterns in the ruby skill's performance resources

## Commands

```bash
# Run the liquid-spec test suite
bundle exec liquid-spec run adapter.rb

# Run tests matching a pattern
bundle exec liquid-spec run adapter.rb -n "for"
bundle exec liquid-spec run adapter.rb -n "/test_.*filter/"

# Quick test a single template
bundle exec liquid-spec eval adapter.rb -l "{{ 'hi' | upcase }}"

# List available specs
bundle exec liquid-spec run adapter.rb --list
```

## Architecture

The compilation pipeline flows: **Source → Lexer → Parser → IL → Linker → VM**

### Two-Stage Lexing

1. **TemplateLexer** (`lexer.rb`) - Stage 1: Splits template into RAW, TAG, VAR tokens with whitespace trim tracking
2. **ExpressionLexer** (`lexer.rb`) - Stage 2: Tokenizes tag/variable markup with byte lookup tables for O(1) punctuation dispatch

### Direct IL Emission

The **Parser** (`parser.rb`) is a recursive descent parser that emits IL directly—no AST intermediate. It uses `IL::Builder` to construct instruction sequences with symbolic labels.

### IL Instruction Set

Instructions in `il.rb` are simple arrays (`[:OPCODE, arg1, arg2]`) for minimal allocation. Key categories:
- **Output**: `WRITE_RAW`, `WRITE_VALUE`
- **Constants**: `CONST_NIL`, `CONST_INT`, `CONST_STRING`, etc.
- **Lookups**: `FIND_VAR`, `LOOKUP_KEY`, `LOOKUP_CONST_KEY`, `LOOKUP_COMMAND`
- **Control flow**: `LABEL`, `JUMP`, `JUMP_IF_FALSE`, `JUMP_IF_TRUE`, `JUMP_IF_EMPTY`
- **Loops**: `FOR_INIT`, `FOR_NEXT`, `FOR_END`, `PUSH_FORLOOP`, `POP_FORLOOP`
- **Interrupts**: `PUSH_INTERRUPT`, `POP_INTERRUPT`, `JUMP_IF_INTERRUPT`

`IL.link()` resolves symbolic labels to instruction indices after parsing.

### Compiler Optimization Passes

The **Compiler** (`compiler.rb`) wraps the parser and can run optimization passes:
- Merge consecutive `WRITE_RAW` instructions
- Remove unreachable code after unconditional jumps
- (Future: constant folding, filter inlining, loop unrolling)

### Stack-Based VM

The **VM** (`vm.rb`) executes IL with:
- Value stack for expression evaluation
- Program counter for control flow
- Iterator stack for nested loops
- Interrupt stack for break/continue propagation

### Core Abstractions (from liquid-spec)

- **to_output**: Convert any value to output string (handles `to_liquid`)
- **to_iterable**: Convert value to array for for loops
- **is_truthy**: Liquid semantics—only `nil` and `false` are falsy
- **is_empty/is_blank**: For `== empty` and `== blank` comparisons

### Drop Protocol

Objects can implement:
- `to_liquid` - Called before output rendering
- `to_liquid_value` - Called for truthiness checks and comparisons
- `[]` - Property access

## Performance Patterns

From the ruby skill's performance guidance:

```ruby
# Use skip instead of scan (avoids allocation)
len = @scanner.skip(/\w+/)
value = @doc.byteslice(@scanner.pos - len, len)  # only when needed

# Byte lookup tables for O(1) dispatch
PUNCT_TABLE = []
PUNCT_TABLE["|".ord] = :PIPE
byte = @source.getbyte(@scanner.pos)
if (punct = PUNCT_TABLE[byte])
  # handle punctuation
end

# Free array optimizations
[x, y].max  # No allocation!
[x, y].min  # No allocation!
```

## Problem-Solving Hierarchy

1. **Lexer/Parser time** - Constant folding, static analysis, syntax validation
2. **IL optimization passes** - Dead code elimination, instruction merging, loop optimizations
3. **Link time** - Label resolution, jump target calculation
4. **Runtime (VM)** - Only dynamic lookups, filter calls, and interrupt handling

## Design Decisions

This project involves many architectural and implementation decisions. When facing choices about:
- IL instruction design
- Optimization strategies
- Performance vs. complexity tradeoffs
- How to handle edge cases
- Where in the pipeline to solve a problem

Use the `AskUserQuestion` tool to get direction. The goal is to build something excellent, not just functional.
