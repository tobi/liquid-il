# PRD: Global Registers Optimization

## Overview

Implement register liveness analysis to enable temp register reuse across the IL optimization pipeline. This addresses register pressure, eliminates inefficient temp allocation, enables new optimization opportunities, and provides infrastructure for future optimizations.

## Problem Statement

Currently, each optimization pass allocates temps independently using `find_max_temp_index()`. This leads to:

1. **Register pressure** - Multiple passes each grab fresh temps, risking exhaustion of the 16 register slots
2. **Inefficient usage** - A temp used only in lines 5-10 cannot be reused for lines 20-30
3. **Missed optimizations** - Same values computed in different code regions use different temps
4. **No foundation** - Future optimizations (expensive filter caching) need liveness info to work

## Goals

- Implement basic liveness analysis to determine when temps are "dead" (last use has passed)
- Enable temp reuse: when a temp is dead, its slot can be allocated to a new temp
- Keep implementation simple - no control-flow graphs or SSA, just linear scan within templates
- Reduce peak register usage in typical templates

## Non-Goals

- Cross-template analysis (partials are separate compilation units for this pass)
- Full data-flow analysis infrastructure
- SSA form or phi nodes
- Optimal register allocation (we want "good enough" with simple code)

## Design

### Liveness Analysis

For each temp register, track:
- **Definition point** - Where the temp is assigned (STORETEMP)
- **Last use point** - The final instruction that reads the temp (LOADTEMP)

A temp is **live** between its definition and last use. After the last use, the register slot is available for reuse.

### Implementation Approach

1. **Single backward pass** to find last-use points for each temp
2. **Forward allocation pass** that reuses dead temp slots
3. **Integration point** - Run after all optimization passes, before linking

### Example

Before optimization:
```
STORETEMP 0    # temp0 = x
LOADTEMP 0
OUTPUT
STORETEMP 1    # temp1 = y (temp0 is dead here!)
LOADTEMP 1
OUTPUT
STORETEMP 2    # temp2 = z (temp1 is dead here!)
```

After optimization:
```
STORETEMP 0    # temp0 = x
LOADTEMP 0
OUTPUT
STORETEMP 0    # reuse slot 0 for y
LOADTEMP 0
OUTPUT
STORETEMP 0    # reuse slot 0 for z
```

Peak usage reduced from 3 temps to 1.

## Success Criteria

- [ ] Liveness analysis correctly identifies temp live ranges
- [ ] Temp slots are reused when safe
- [ ] All existing tests pass
- [ ] Measurable reduction in peak temp usage on real templates

## Technical Notes

- Scope: Single templates only (not cross-partial)
- No control flow analysis - treat code as linear sequence
- Integrate after existing optimization passes run
- Consider: Should this rewrite temp indices in-place or create a mapping?