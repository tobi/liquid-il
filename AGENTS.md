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

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
bd ready              # Show issues ready to work (no blockers)
bd list --status=open # All open issues
bd show <id>          # Full issue details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id> --reason="Completed"
bd close <id1> <id2>  # Close multiple issues at once
bd sync               # Commit and push changes
```

### Workflow Pattern

1. **Start**: Run `bd ready` to find actionable work
2. **Claim**: Use `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `bd close <id>`
5. **Sync**: Always run `bd sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
bd sync                 # Commit beads changes
git commit -m "..."     # Commit code
bd sync                 # Commit any new beads changes
git push                # Push to remote
```

### Best Practices

- Check `bd ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `bd create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `bd sync` before ending session

<!-- end-bv-agent-instructions -->
