# Lessons from LiquidIL

What we learned building a complete language implementation with AI.

## 1. Test Suites Are Specifications

The [liquid-spec](https://github.com/Shopify/liquid-spec) test suite contains 4,424 executable specifications. Each one defines:
- Input template
- Environment variables
- Expected output
- Edge cases and error conditions

**The insight:** A comprehensive test suite *is* a specification. Claude Code never read the Liquid documentation or reference implementation. It just made tests pass. The result was 99.8% compatible.

**Implication:** If you want AI to build something, give it a test suite, not prose documentation. Tests are unambiguous. Documentation has gaps.

## 2. Architecture Emerges from Constraints

The IL (Intermediate Language) approach wasn't planned. It emerged naturally:

```
Source → Lexer → Parser → IL → Linker → VM
```

When Claude started building a parser, it found emitting simple instructions easier than building and walking an AST. The structure emerged from:
- **Constraint:** Make tests pass
- **Tendency:** Choose the simplest thing that works
- **Result:** Clean separation of concerns

The IL accidentally produced good properties:
- Simple instruction encoding (just arrays)
- Easy to optimize (linear instruction stream)
- Clear execution model (explicit control flow)

**Implication:** Don't over-specify architecture. Let it emerge from solving real problems.

## 3. Solve Problems at the Right Level

The project demonstrated a clear problem-solving hierarchy:

| Level | When | Examples |
|-------|------|----------|
| Lexer | Character stream | Token boundaries, whitespace handling |
| Parser | Syntax | Tag structure, expression precedence |
| Compile-time | Static analysis | Constant folding, dead code elimination |
| Link time | Global | Label resolution, jump targets |
| Runtime | Dynamic | Variable lookup, filter execution |

**Example:** Filter aliasing (`h` → `escape`) was solved at parse time, not runtime. The parser emits `escape` directly. Zero cost.

**Example:** The optimizer folds `{{ "hello" | upcase }}` into `WRITE_RAW "HELLO"` at compile time. No runtime filter call.

**Implication:** Push work to the earliest possible stage. Lex time > parse time > compile time > link time > runtime.

## 4. The Value of Rapid Iteration

Phase 2 had 17 commits in 42 minutes. Each commit fixed one specific test failure:

```
10:17 - Fix hash.last and array bracket notation
10:19 - Fix integer key lookups
10:21 - Add lax parsing for fat arrow
10:23 - Fix include/render 'for' iteration
...
```

The pattern:
1. Run tests
2. See failure
3. Read expected vs actual
4. Fix
5. Commit
6. Repeat

No design documents. No planning meetings. Just: make the next test pass.

**Implication:** With good tests, rapid iteration beats upfront planning.

## 5. Edge Cases Reveal Semantics

Many test failures revealed subtle Liquid semantics:

| Test Failure | Revealed Semantics |
|--------------|-------------------|
| `hash.last` returns nil | Hashes are ordered but `.last` only works on arrays |
| `"0x10".to_i` returns 0 | Ruby's to_i extracts leading digits, ignores rest |
| Error then more output | Liquid continues after errors, doesn't halt |
| `forloop.parentloop` | Nested loops maintain a stack of loop metadata |
| `{{ blank.x }}` | Keywords can be variable names in property access |

Claude Code discovered these semantics purely from test failures. It didn't know these rules existed—it just noticed when output didn't match.

**Implication:** Good tests encode semantics that documentation forgets to mention.

## 6. Performance Is a Separate Concern

The initial VM was ~2x slower than the reference implementation. That was fine for v1:

- Tests passed
- Code was clear
- Architecture was sound

Performance optimization came later (PR #1), with a completely different approach: compiling IL to Ruby instead of interpreting it. That version is 1.34x *faster* than the reference.

**Implication:** Get it working, then get it fast. Don't prematurely optimize.

## 7. The "Vibe Coding" Methodology Works

The process was surprisingly effective:

1. **Human:** "Make all the tests pass"
2. **AI:** Runs tests, reads failures, writes fixes
3. **Human:** Reviews commits, occasionally redirects
4. **Repeat**

The human role was:
- Setting the goal
- Providing the test suite
- Reviewing architectural decisions
- Intervening on non-obvious choices

The AI handled:
- Implementation details
- Edge case discovery
- Iterative refinement
- Documentation

**Implication:** AI coding agents work best with clear specifications (tests) and minimal human intervention on implementation details.

## 8. What Claude Code Did Well

- **Pattern recognition:** Quickly identified what each test failure meant
- **Incremental fixes:** Made minimal changes per commit
- **Consistent style:** Maintained code conventions throughout
- **Error recovery:** Learned from compilation/runtime errors
- **Documentation:** Produced clear commit messages and code comments

## 9. What Required Human Input

- **Architecture decisions:** "Should we use an IL or AST?"
- **Performance tradeoffs:** "Is 2x slowdown acceptable?"
- **Release preparation:** "Let's document and publish"
- **Direction changes:** "Now try compiling to Ruby"

## 10. Implications for AI-Assisted Development

### For Test Suite Authors
Comprehensive test suites are more valuable than ever. They're not just for validation—they're specifications that AI can implement against.

### For Teams
Consider the "vibe coding" workflow:
- Define requirements as tests
- Let AI iterate to make them pass
- Review and redirect as needed

### For Tool Builders
AI coding agents need:
- Fast test feedback loops
- Clear error messages
- Incremental compilation/execution

### For Language Designers
If you want wide adoption (including AI implementation), publish executable specifications, not just grammars and prose.

---

## Summary

Building LiquidIL demonstrated that:

1. **Test suites are powerful specifications** that AI can implement against
2. **Architecture emerges** from solving real problems
3. **Work belongs at the earliest stage** that can handle it
4. **Rapid iteration** beats upfront planning when tests are good
5. **Edge cases reveal semantics** that documentation misses
6. **Performance is separate** from correctness
7. **"Vibe coding" works** for implementation tasks
8. **AI + human collaboration** is effective with clear boundaries
