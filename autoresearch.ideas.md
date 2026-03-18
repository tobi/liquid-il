# Autoresearch Ideas — StringView String Allocation Reduction

## Remaining Targets (from 921 string allocs)

### Irreducible (515 allocs)
- **515** lexer.rb intern first-occurrence byteslice — unique identifiers/strings/numbers that must be created once

### For/Tablerow Tag (~182 allocs)
- Rewrite `parse_for_tag` and `parse_tablerow_tag` to scan `@source` directly via region
- Find ` in ` by byte scanning, intern var_name, parse collection via `expr_lexer_for_region`
- Complex because options parsing (limit:, offset:, reversed, cols:) needs careful byte-level tokenization
- Still needs `rest.split` for option parsing — could extract options first then pass collection as region

### Tag Name Slow Path (~38 allocs)
- Add `#` and `doc` to common tag table (1-byte and 3-byte fast paths)
- Add `paginate`, `form`, `endform`, `endpaginate`, `schema`, `section`, `style`, `javascript` for Shopify themes

### Materialize Tag Args (~44 allocs)
- Remaining calls to `materialize_tag_args` for for/tablerow tags
- Would be eliminated if for/tablerow use region scanning

### Assign from Liquid Tag (~26 allocs)  
- `_parse_assign_from_string` path still uses byteslice for value_expr
- Could compute absolute source positions from liquid tag content offsets

## Architecture Ideas

### Single-Pass Unified Lexer
- Merge TemplateLexer + ExpressionLexer into one scanner
- Emit flat token stream: RAW → VAR_START → IDENTIFIER → PIPE → IDENTIFIER → VAR_END → TAG_START → TAG_NAME → ... 
- Parser would switch between template and expression grammar based on delimiters
- Eliminates ALL content extraction/substring passing
- BIG refactor — would need to redesign the parser significantly

### StringView in IL Instructions
- Already done for WRITE_RAW; could extend to other instructions
- CONST_STRING, FIND_VAR, ASSIGN, etc. could all carry StringViews
- Materialization deferred to structured compiler
- Risk: every IL consumer/pass needs to handle StringView

### Pre-Populated Intern Table
- Seed the intern table with common identifiers: product, title, name, price, size, etc.
- Zero alloc for the most common names even on first occurrence
- Minimal overhead (a few frozen strings in a hash)
