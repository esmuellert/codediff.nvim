# Merge Tool Diff Rendering - VSCode Parity Gaps

**Date**: 2025-12-09
**Status**: ✅ RESOLVED - Full parity achieved

## Overview

This document tracks the parity gaps between our merge tool diff rendering and VSCode's implementation. Our goal is 100% replication of VSCode's merge editor rendering for the incoming (left/:3) and current (right/:2) editors.

## Resolution Summary

All parity gaps have been fixed. The comparison test now shows identical filler output between VSCode and our Lua implementation.

### Key Fixes Applied

1. **Event Sort Order in `split_up_common_equal_range_mappings`** (Root cause of most gaps)
   - End events must be processed before start events at the same position
   - This ensures continuous coverage when equal ranges are adjacent
   - Without this fix, we produced "half syncs" instead of "full syncs"

2. **Output Range Extension in `compute_mapping_alignments`**
   - When multiple changes from different inputs are grouped into one alignment
   - Must extend output ranges to cover the full base range using VSCode's `extendInputRange` logic
   - Calculates proper start/end deltas from joined mapping to full base range

### Verification

Run the comparison test to verify parity:
```bash
./scripts/test_merge_comparison.sh  # Auto-detect from ~/vscode-merge-test
./scripts/test_merge_comparison.sh <conflict_file>  # Single file
./scripts/test_merge_comparison.sh <base> <input1> <input2>  # Three files
```

Expected output:
```
Comparing fillers (normalized):
✓ Fillers are IDENTICAL
```

## Previously Identified Gaps (All Resolved)

### Gap 1: Event Processing Order ✅ FIXED
When equal ranges are adjacent (one ends where another starts at the same position), end events must be processed before start events to maintain continuous coverage.

### Gap 2: Output Range Extension ✅ FIXED
When grouping changes, output ranges must be extended using the `extendInputRange` pattern to cover the full merged base range.

### Gap 3-6: Various Edge Cases ✅ FIXED
All other gaps were symptoms of the above two root causes and were resolved by the fixes.

## References

- VSCode `lineAlignment.ts`: Core alignment algorithm
- VSCode `viewZones.ts`: Filler line insertion
- VSCode `inputCodeEditorView.ts`: Decoration application
- VSCode `modifiedBaseRange.ts`: Conflict detection
- VSCode `mapping.ts`: MappingAlignment.compute()
