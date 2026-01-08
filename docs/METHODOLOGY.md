# Methodology: Building with AI + Test Suites

How to replicate the LiquidIL approach for other projects.

## Prerequisites

### 1. A Comprehensive Test Suite

The most important ingredient. Your test suite should:

- **Cover all behavior**, not just happy paths
- **Be executable**, not prose descriptions
- **Be isolated**, so tests can run independently
- **Have clear output**, so failures are understandable
- **Be fast**, so iteration is quick

For LiquidIL, [liquid-spec](https://github.com/Shopify/liquid-spec) provided 4,424 tests covering:
- Basic syntax (variables, tags, filters)
- Edge cases (empty inputs, nil values, type coercion)
- Error conditions (syntax errors, runtime errors)
- Complex scenarios (nested loops, recursive templates)

### 2. An AI Coding Agent

[Claude Code](https://claude.com/claude-code) was used for LiquidIL. Key capabilities:
- Can run shell commands (tests)
- Can read and write files
- Can iterate based on feedback
- Maintains context across interactions

### 3. A Simple Adapter

A thin layer that connects your test framework to your implementation:

```ruby
# adapter.rb for liquid-spec
LiquidSpec.compile do |ctx, source, options|
  ctx[:template] = MyImpl.parse(source)
end

LiquidSpec.render do |ctx, assigns, options|
  ctx[:template].render(assigns)
end
```

The adapter is the contract. As long as it works, internals don't matter.

## The Process

### Step 1: Initial Prompt

```
Run the test suite against the adapter. Make all tests pass.
Don't read any existing implementations. Just make the tests pass.
```

Key points:
- **Don't read reference code.** This ensures a clean-room implementation.
- **Focus on tests.** Tests are the specification.
- **Allow emergence.** Don't prescribe architecture.

### Step 2: Iteration Loop

The AI enters a loop:

```
1. Run tests
2. Read failures
3. Analyze expected vs actual
4. Write code to fix
5. Commit
6. Repeat until all pass
```

**Don't interrupt during this loop.** Let the AI find its own path. Intervention should be rare.

### Step 3: Human Review Points

Intervene only for:

| Situation | Action |
|-----------|--------|
| Major architecture decision | Discuss options, let AI choose |
| Non-obvious semantic choice | Ask AI to explain reasoning |
| Performance concerns | Note but don't block progress |
| Stuck on a test | Provide hints about expected behavior |

**Avoid:**
- Prescribing implementation details
- Suggesting "better" approaches mid-flow
- Premature optimization discussions

### Step 4: Polish Phase

Once tests pass:
- Review commit history
- Clean up any hacks
- Add documentation
- Optimize if needed

## Tips for Success

### 1. Trust the Tests

If a test fails, the implementation is wrong. Don't question the test (unless it's obviously buggy).

The AI should treat tests as ground truth:
```
Test says: hash.first returns key
My output: hash.first returns [key, value]
→ My understanding of hash.first is wrong. Fix it.
```

### 2. Small Commits

One fix per commit. This creates a traceable history:

```
10:17 - Fix hash.last and array bracket notation
10:19 - Fix integer key lookups
10:21 - Add lax parsing for fat arrow
```

If something breaks later, you can bisect.

### 3. Let Architecture Emerge

Don't specify:
```
"Build an AST interpreter with visitor pattern"
```

Instead:
```
"Make the tests pass"
```

The AI will choose the simplest thing that works. Often that's better than what you'd prescribe.

### 4. Fast Feedback Loop

Test runs should be fast. For LiquidIL:
- Full suite: ~5 seconds
- Single test: instant

If tests are slow, provide filtering:
```bash
bundle exec liquid-spec run adapter.rb -n "for_loop"
```

### 5. Good Error Messages

Test failures should clearly show:
- What was expected
- What was received
- Where the difference is

```
Expected: "Hello World"
Actual:   "Hello World\n"
          Extra newline at end
```

## Common Patterns

### Pattern: The First Working Version

Phase 1 is about making things work, not making them elegant:

```ruby
# First version: ugly but works
def lookup(key)
  if key == "size" && @value.respond_to?(:size)
    @value.size
  elsif key == "first" && @value.respond_to?(:first)
    @value.first
  # ... 20 more elsif branches
  end
end
```

That's fine. Refactor later.

### Pattern: Edge Case Discovery

Tests reveal edge cases you wouldn't think of:

```
Test: {{ "0x10" | to_integer }}
Expected: 0
```

The AI learns: Ruby's `to_i` extracts leading digits. It didn't know this rule—it discovered it from the test.

### Pattern: Error Recovery

Tests might show the system should continue after errors:

```
Template: {{ undefined_var }}more text
Expected: Liquid error: undefined variable 'undefined_var'\nmore text
```

The AI learns: Errors are captured and execution continues.

## Scaling Up

### For Larger Projects

- Break test suite into features/modules
- Work on one module at a time
- Integrate incrementally

### For Multiple AIs

Different AI sessions can work on:
- Different features (if test suites are separate)
- Different implementations (then compare)
- Different optimization strategies

### For Ongoing Maintenance

Once the implementation exists:
- New tests drive new features
- Failing tests indicate regressions
- The loop continues

## Anti-Patterns

### Don't: Over-Specify

❌ "Build a two-pass compiler with SSA form and register allocation"

✅ "Make the tests pass"

### Don't: Optimize Early

❌ "This loop is O(n²), fix it before continuing"

✅ Let it pass tests first, optimize later

### Don't: Intervene Constantly

❌ "Actually, I think you should use a different data structure here"

✅ Let the AI try its approach. If tests fail, it'll adapt.

### Don't: Skip Tests

❌ "That test seems wrong, skip it"

✅ Trust the test suite. If truly wrong, fix the test.

## Checklist

Before starting:
- [ ] Test suite is comprehensive and fast
- [ ] Adapter interface is defined
- [ ] AI agent has shell/file access
- [ ] Clean directory with no reference code

During:
- [ ] Let AI iterate without interruption
- [ ] Review commits periodically
- [ ] Intervene only for major decisions

After:
- [ ] All tests pass
- [ ] Code is reviewed
- [ ] Documentation added
- [ ] Consider optimization pass

---

## Example Session Start

```
> Run `bundle exec liquid-spec run adapter.rb` against the empty adapter.
> For each failing test, implement the minimum code to make it pass.
> Don't look at any existing Liquid implementations.
> Make one commit per logical fix.
> Continue until all tests pass.
```

Then let it run.
