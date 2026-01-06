# AGENTS.md

Instructions for AI coding agents working on this repository.

**Architecture:** See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed pipeline documentation.

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

Pipeline: **Source → Lexer → Parser → IL → Linker → VM**

See [ARCHITECTURE.md](ARCHITECTURE.md) for complete details on:
- Two-stage lexing (TemplateLexer + ExpressionLexer)
- IL instruction set and encoding
- VM execution model
- Drop protocol

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
