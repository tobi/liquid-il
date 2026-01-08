# Can an AI Build a Programming Language From Tests Alone?

I gave Claude one instruction: "Make all 4,424 tests pass." No documentation. No reference implementation. Just a test suite and a blank directory.

2.5 days later, I had a fully functional template language that's faster than the original.

## The Experiment

[Liquid](https://shopify.github.io/liquid/) is a template language used by millions of websites. Shopify created it, and over the years we've built a comprehensive test suite called [liquid-spec](https://github.com/Shopify/liquid-spec) that captures every aspect of the language's behavior.

I wondered: Could those tests alone serve as a specification? Could an AI implement Liquid from scratch by simply making them pass?

## Day 1: The Foundation

I pointed [Claude Code](https://claude.com/claude-code) at the test suite and said:

> Run the tests. Make them pass. Don't read any existing Liquid code.

In a single session, Claude built:
- A two-stage lexer (one for template structure, one for expressions)
- A recursive descent parser
- An intermediate language with 55 different instructions
- A virtual machine to execute those instructions
- Over 50 filter implementations

First test run: **4,421 tests passing** out of 4,424. One edge case in recursive template depth. Not bad for a few hours of work.

## Day 2: The Edge Cases

This is where it got interesting. Claude iterated through failing tests, fixing them one by one:

```
10:17 - Fix hash.last and array bracket notation
10:19 - Fix integer key lookups
10:21 - Add lax parsing for fat arrow
10:23 - Fix include/render 'for' iteration
```

Each test failure revealed a semantic detail I'd forgotten existed:
- `hash.first` returns just the key, not a key-value pair
- `"0x10".to_i` returns 0 because Ruby extracts leading digits
- After an error, templates continue executing
- The keyword `blank` can be used as a variable name in some contexts

Claude discovered all of this from test failures. It never read documentation or looked at how our existing implementation handles these cases.

## Day 3: Faster Than the Original

With all tests passing, I asked about performance. The initial implementation was about 2x slower than our reference—reasonable for a first version.

Then I asked: "What if we compiled to Ruby instead of interpreting?"

Claude wrote a 1,695-line compiler that transforms the intermediate language directly into Ruby code. Instead of interpreting instructions in a loop, it generates native Ruby that executes directly.

The result? **34% faster than the reference implementation** on rendering.

## What I Learned

### Tests Are Specifications

This experiment validated something I've long suspected: a comprehensive test suite *is* a specification. The 4,424 tests in liquid-spec captured enough detail that an AI could build a compatible implementation without any other guidance.

If you want AI to build something, give it tests, not documentation. Tests are unambiguous. Documentation has gaps.

### Architecture Emerges

I didn't tell Claude to use an intermediate language. I didn't specify a virtual machine architecture. It chose those approaches because they were the simplest way to make tests pass.

The resulting design was cleaner than what I would have prescribed. The IL (intermediate language) approach made optimization straightforward—just transform the instruction stream. That's how we got the 34% speedup.

### The Loop Works

The development process was remarkably simple:

1. Run tests
2. Read failures
3. Write code to fix
4. Commit
5. Repeat

No design documents. No architecture reviews. Just: make the next test pass.

For implementation tasks with good specifications, this "vibe coding" approach is surprisingly effective.

## The Numbers

| Metric | Value |
|--------|-------|
| Development time | 2.5 days |
| Lines of code | 7,176 |
| Tests passing | 4,424 / 4,424 |
| Compatibility | 99.8% |
| Render speed | 1.34x faster than reference |

## Try It Yourself

If you have a comprehensive test suite for something—a parser, a protocol implementation, a data format—try this approach:

1. Point an AI coding agent at your tests
2. Say "make them pass"
3. Watch what emerges

The code for this experiment is at [github.com/tobi/liquid-il](https://github.com/tobi/liquid-il). The full development timeline, including all chat transcripts, is in the docs folder.

## What This Means

We're entering an era where AI can implement specifications, not just assist with coding. The key insight is that test suites are more valuable than ever—they're not just for validation, they're the specification itself.

If you're building something and want AI to eventually help (or take over) implementation work, invest in your tests. Make them comprehensive. Make them unambiguous. Make them executable.

The tests are the spec.

---

*Built with [Claude Code](https://claude.com/claude-code) and [liquid-spec](https://github.com/Shopify/liquid-spec)*
