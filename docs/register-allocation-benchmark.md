# Register Allocation Benchmark Results

This document presents benchmark results measuring the reduction in peak temp register usage achieved by the register allocation optimization pass (US-007).

## Methodology

The benchmark compiles representative real-world Liquid templates with all optimization passes **except** register allocation, then measures:

1. **Effective before**: The maximum of unique temp indices used OR total STORE_TEMP operations (whichever is higher)
2. **Peak after**: The maximum number of simultaneously live temp registers after register allocation

The register allocator performs:
- **Backward liveness analysis**: Identifies the last-use point for each temp register
- **Forward allocation**: Reuses temp slots as they become dead

## Results

| Template | Effective Before | Peak After | Reduction | % Reduction |
|----------|-----------------|------------|-----------|-------------|
| E-commerce Product List | 2 | 1 | 1 | 50.0% |
| Blog Post | 3 | 2 | 1 | 33.3% |
| Invoice | 4 | 3 | 1 | 25.0% |
| Navigation Menu | 3 | 2 | 1 | 33.3% |
| Data Table | 7 | 5 | 2 | 28.6% |

### Summary

- **Templates benchmarked**: 5
- **Total effective before**: 19 temps
- **Total after allocation**: 13 temps
- **Total reduction**: 6 temps
- **Average reduction**: 34.0%

## Template Descriptions

### E-commerce Product List
A typical product listing with loops, conditionals, and filter chains:
- Nested loops (products → tags)
- Filter chains: `escape`, `money`, `truncate`, `times`, `round`, `downcase`, `replace`
- Conditionals for sale pricing

### Blog Post
A blog article with metadata, images, tags, and related posts:
- Multiple conditional sections
- Nested loops with `forloop.last` check
- Filter chains: `escape`, `date`, `downcase`, `url_encode`

### Invoice
A business invoice with line items and calculations:
- Loop over line items with calculations
- Multiple conditional sections
- Filter chains: `date`, `escape`, `newline_to_br`, `money`, `times`

### Navigation Menu
A 3-level navigation hierarchy:
- Triple-nested loops
- Conditionals for active states and submenus
- Filter: `escape`

### Data Table
A data table with dynamic cell formatting:
- Nested loops (rows → cells)
- Case statement for cell type formatting
- Filter chains: `escape`, `upcase`, `size`, `round`, `money`, `date`, `times`, `truncate`
- Cycle for alternating row styles

## Interpretation

The register allocation optimization consistently reduces peak temp usage across all tested templates. Key observations:

1. **Typical reduction: 25-50%** - Most templates see a reduction of 1-2 temp registers
2. **More complex templates benefit more** - Templates with more STORE_TEMP operations (like Data Table) show larger absolute reductions
3. **Sequential non-overlapping temps** see the best optimization - When temps are used and immediately consumed, slots can be reused efficiently
4. **Overlapping lifetimes** limit optimization - When temps must remain live simultaneously (e.g., for nested filter chains), slots cannot be shared

## Running the Benchmark

```bash
bundle exec ruby test/register_benchmark.rb
```

## Implementation Details

See `lib/liquid_il/effect_analysis.rb` for:
- `TempLiveness`: Backward pass liveness analysis
- `TempAllocator`: Forward pass slot allocation
- `RegisterAllocator`: Optimization pass entry point

The register allocator is integrated as optimization pass 19 in `lib/liquid_il/compiler.rb`.
