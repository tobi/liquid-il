# I Asked Claude to Build Liquid From Scratch

*A 2.5-day experiment in AI-driven language implementation*

---

Last week I ran an experiment: Could an AI build a working Liquid template engine using only our test suite as specification?

**TL;DR:** Yes. Claude Code built a fully functional Liquid implementation in 2.5 days, passing 4,424 tests with 99.8% compatibility. Then it compiled the whole thing to Ruby and made it 34% faster than our reference implementation.

## The Setup

I pointed [Claude Code](https://claude.com/claude-code) at [liquid-spec](https://github.com/Shopify/liquid-spec)—our comprehensive test suite—and gave it one instruction:

> Make all the tests pass. Don't read any existing Liquid code.

No documentation. No reference implementation. Just 4,424 executable specifications and a blank directory.

## Day 1: Building Everything

In a single session, Claude produced:
- A two-stage lexer
- A recursive descent parser
- An intermediate language with 55 opcodes
- A stack-based virtual machine
- 50+ filter implementations
- Context management and scoping

**3,763 lines of Ruby. First test run: 4,421 passing.**

One test failed. A recursive render depth edge case.

## Day 2: The Edge Cases

Then came the interesting part. Claude iterated through failures at ~1.5 commits per hour:

```
10:17 - Fix hash.last and array bracket notation
10:19 - Fix integer key lookups
10:21 - Add lax parsing for fat arrow
10:23 - Fix include/render 'for' iteration
```

Each commit fixed one test. Many revealed Liquid semantics I'd forgotten existed:
- `hash.first` returns the key, not a key-value pair
- `"0x10".to_i` returns 0 (Ruby extracts leading digits)
- Templates continue executing after errors
- The keyword `blank` can be a variable name in property access

Claude discovered all of this from test failures alone.

## Day 3: Optimization

With tests passing, Claude added an optimizer:
- Constant folding at compile time
- Dead code elimination
- Instruction fusion
- 12 optimization passes total

Then things got interesting.

## The Plot Twist

The VM was ~2x slower than liquid_ruby. Reasonable for a first implementation.

I asked: "What if we compiled to Ruby instead of interpreting?"

Claude wrote a 1,695-line AOT (Ahead-of-Time) compiler that transforms the intermediate language directly into Ruby code. Instead of:

```ruby
# VM loop: fetch → decode → execute
case instruction[0]
when :FIND_VAR then stack.push(ctx.lookup(instruction[1]))
when :WRITE_VALUE then out << stack.pop.to_s
...
end
```

It generates:

```ruby
# Native Ruby proc
proc { |ctx, out|
  out << ctx.lookup("name").to_s
}
```

**Result: 1.34x faster than liquid_ruby on render.**

## What This Means

### 1. Test Suites Are Specifications

liquid-spec contains enough detail that an AI could build a compatible implementation without reading documentation or code. The tests *are* the spec.

This validates years of investment in liquid-spec. It's not just for testing—it's a complete language specification.

### 2. AI Coding Agents Work

Claude navigated thousands of edge cases, semantic subtleties, and error conditions to achieve near-perfect compatibility. The iteration loop—run tests, read failures, fix, repeat—is remarkably effective.

### 3. Architecture Emerges

The IL approach wasn't planned. Claude found it easier to emit simple instructions than to build and walk an AST. The result was cleaner than what I would have prescribed.

## The Numbers

| Metric | Value |
|--------|-------|
| Development time | 2.5 days |
| Lines of code | 7,176 |
| Tests passing | 4,424 / 4,424 |
| Compatibility | 99.8% |
| Render performance | 1.34x faster than liquid_ruby |

## What's Next?

The code is at [github.com/tobi/liquid-il](https://github.com/tobi/liquid-il).

I'm thinking about:
1. **Production use:** Could this replace liquid_ruby in some contexts?
2. **liquid-c parity:** What would it take to match liquid-c performance?
3. **Other languages:** Could this approach work for other DSLs with good test suites?

## Try It Yourself

If you have a comprehensive test suite for something, try this:

1. Point Claude Code at your tests
2. Say "make them pass"
3. Watch what emerges

You might be surprised.

---

*Full timeline: [TIMELINE.md](TIMELINE.md)*
*All learnings: [LESSONS.md](LESSONS.md)*
*The methodology: [METHODOLOGY.md](METHODOLOGY.md)*
