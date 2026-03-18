# Autoresearch Ideas — StringView String Allocation Reduction

## Summary
**Achieved: 71.3% reduction** — from 2,378 to 683 string allocations during parse.

## Remaining Breakdown (683 total)
- **563 irreducible**: first-occurrence interned strings (unique identifiers, string literals, numbers, assign var_names)
- **39**: `loop_name` string interpolation in for-tags (necessary — used by IL for_init)
- **38**: tag_name slow path for uncommon tags (# comment, doc, custom tags)
- **20**: custom tag registration strings (tags.rb)
- **15**: misc parser edge cases (cycle identity, for-in-liquid path)
- **5**: materialize_tag_args for remaining tags called from liquid tag
- **3**: other

## Still Possible (diminishing returns)

### Eliminate tag_name slow path (~38 allocs)
- Add `#` (length 1) and `doc` (length 3) to `_match_common_tag` byte table
- Add other Shopify theme tags: `paginate`, `form`, `endform`, `schema`, `section`, `style`, `javascript`
- Small win but easy

### Pre-Populated Intern Table
- Seed with common Liquid identifiers (product, title, name, price, etc.)
- Would reduce the 563 irreducible by ~200 (common names across templates)
- Risk: overfitting to specific template patterns

### Single-Pass Unified Lexer
- Merge TemplateLexer + ExpressionLexer into one scanner
- Emit flat token stream: RAW → VAR_START → IDENTIFIER → PIPE → VAR_END → ...
- Eliminates ALL content extraction/substring passing
- BIG refactor — would need to redesign parser significantly
- Potential to reduce the 563 irreducible since same source = same intern table across all scanning

### StringView in More IL Instructions
- Currently only WRITE_RAW uses StringView in IL
- CONST_STRING, FIND_VAR, ASSIGN, etc. could carry StringViews
- Would defer materialization to structured compiler for ALL string operands
- Saves first-occurrence intern allocs during parse (materialize in compile phase)
- But increases complexity in IL passes (merge, fold_const, etc.)
