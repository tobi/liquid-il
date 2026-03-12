# Autoresearch: 100% liquid-spec Coverage

## Objective
Fix all remaining liquid-spec failures to reach 100% pass rate. Currently at 4090/4102 (99.7%). The 12 failures fall into 3 categories:

### Category 1: Include + interrupt propagation (8 errors)
Break/continue inside an included partial must propagate to the caller's for loop. The structured compiler currently **refuses to compile** these templates (raises RuntimeError) because `throw/catch` doesn't propagate across the compiled partial lambda boundary.

**Tests:** include_break_exits_innermost_for_loop, include_propagates_continue, include_propagates_break, break_propagates_through_include, continue_propagates_through_include, break_in_nested_include_blocks, include_for_propagates_break_to_outer, test_break_through_include, test_can_continue_loop_from_inside_included_snippet

**Root cause:** Compiled partials are lambda closures. `throw(:loop_break_N)` inside a lambda doesn't unwind to the `catch(:loop_break_N)` in the caller — Ruby's `throw` doesn't cross lambda boundaries.

**Fix approach:** After executing an included partial, check the scope's interrupt stack. If the partial pushed a break/continue interrupt, propagate it in the caller's loop (throw to the catch, or skip remaining body).

### Category 2: Render tag syntax validation (1 failure)
`{% render name %}` (variable, not string literal) should be a parse error but is accepted.

**Test:** render_static_name_only

**Fix approach:** Add parse-time validation in `parse_render_tag` — if the argument is an identifier (not a quoted string), raise SyntaxError.

### Category 3: Include with dynamic name + `for` iteration (2 failures)
`{% include page for foo %}` with `page` as a variable, and `{% include foo with product_list as p_list %}` with `foo` as a variable — the `for` loop iteration and `with`/`as` don't work correctly with dynamic partial names.

**Tests:** test_including_via_variable_value, test_with_iterates_variables_when_it_is_an_array_for_dynamic_templates

**Fix approach:** Fix the dynamic partial execution path to properly handle `for` iteration (call partial once per item) and `with`/`as` aliasing.

### Category 4: Max complexity (secondary concern)
The spec suite stops at complexity 200/1000. Higher complexity tests are not run. Not a blocker but worth tracking.

## Metrics
- **Primary**: `failures` (count of failed + errored tests, lower is better)
- **Secondary**: `passed` (total passed), `parse_µs`, `render_µs`

## How to Run
```bash
./autoresearch.sh
```

## Files in Scope
- `lib/liquid_il/structured_compiler.rb` — compilation blockers check, partial lambda generation, for loop codegen
- `lib/liquid_il/structured_helpers.rb` — `execute_dynamic_partial` for runtime dynamic includes
- `lib/liquid_il/parser.rb` — render tag parsing (syntax validation)
- `spec/liquid_il_structured.rb` — adapter file (compile/render entry points, fallback handling)

## Off Limits
- Don't change the liquid-spec test expectations
- Don't regress any currently-passing tests
- Don't regress benchmark speed (render_µs, parse_µs)

## Constraints
- `bundle exec liquid-spec run spec/liquid_il_structured.rb` is the test command
- Must maintain YJIT compatibility
- Benchmark: `./auto/autoresearch.sh` for speed metrics

## What's Been Tried
(Starting fresh)
