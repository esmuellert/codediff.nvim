# Timeout Mechanism - Fixed & Tested

## The Bug
Character-level Myers was hardcoded to timeout=0 (infinite) instead of using the configured timeout.

```c
// BEFORE (Bug):
myers_nd_diff_algorithm(seq1_iface, seq2_iface, 0, &hit_timeout);  // ✗ Hardcoded!

// AFTER (Fixed):
myers_nd_diff_algorithm(seq1_iface, seq2_iface, options->timeout_ms, &hit_timeout);  // ✓
```

## The Fix
The timeout infrastructure **already existed** in Myers from day one. We just completed the wiring:

1. Added `timeout_ms` to `CharLevelOptions` struct
2. Passed timeout through `refine_diff()` → `char_opts.timeout_ms = timeout->timeout_ms`
3. Used it in char_level.c instead of hardcoded 0
4. Removed misleading comment: `// timeout handled inside refine_diff_char_level`

**This was incomplete plumbing, not a missing feature.**

## Timeout Flow (End-to-End)

```
Lua Config (5000ms)
  ↓
lua/vscode-diff/config.lua: config.options.diff.max_computation_time_ms
  ↓
lua/vscode-diff/commands.lua: diff.compute_diff(..., { max_computation_time_ms = 5000 })
  ↓
lua/vscode-diff/diff.lua: c_options.max_computation_time_ms = 5000
  ↓
libvscode-diff/api.c: compute_diff(options->max_computation_time_ms)
  ↓
default_lines_diff_computer.c: timeout.timeout_ms = options->max_computation_time_ms
  ↓
Line-level Myers: myers_nd_diff_algorithm(..., timeout_ms, ...)  ✓
  ↓
Char-level Myers: myers_nd_diff_algorithm(..., options->timeout_ms, ...)  ✓ FIXED!
```

## VSCode Parity: 100% ✓

| Aspect | VSCode | Before Fix | After Fix |
|--------|--------|------------|-----------|
| Timeout in Myers signature | ✓ | ✓ | ✓ |
| Line-level uses timeout | ✓ | ✓ | ✓ |
| Char-level uses timeout | ✓ | ✗ (0) | ✓ |
| Default: 5000ms | ✓ | ✓ | ✓ |
| Early exit on timeout | ✓ | Line only | Both ✓ |
| Trivial diff fallback | ✓ | Line only | Both ✓ |

## Performance Impact

Test file (1150 → 2352 lines):

| Timeout | Time | Hit? | Detail |
|---------|------|------|--------|
| 5000ms | 1221ms | No | Full (1188 inner changes) |
| 50ms | 139ms | Yes | Partial (61 regions, 1 inner each) |
| 10ms | 26ms | Yes | Trivial (1 region, 1 inner) |

## User Configuration

```lua
require("vscode-diff").setup({
  diff = {
    max_computation_time_ms = 5000,  -- Default (VSCode parity)
    -- Lower = faster but less detail on large files
    -- Higher = more accurate but slower on complex diffs
  }
})
```

## Tests: 13/13 Passing ✓

**Current location**: `tests/integration/core/diff/timeout_spec.lua`

Coverage:
- Basic functionality (3): parameter acceptance, completion, defaults
- Large files (3): normal/short/very-short timeouts
- Config integration (2): respects config, VSCode default
- VSCode parity (2): line+char Myers, structure consistency
- Edge cases (3): zero/negative timeout, empty files

Run: `./tests/run_tests.sh tests/integration/core/diff/timeout_spec.lua`

## Files Modified

1. `libvscode-diff/include/char_level.h` - Added timeout_ms field
2. `libvscode-diff/src/char_level.c` - Use timeout instead of 0
3. `libvscode-diff/default_lines_diff_computer.c` - Thread timeout through
4. `libvscode-diff/diff_tool.c` - Test env var support
5. `lua/vscode-diff/config.lua` - Added config option
6. `lua/vscode-diff/auto_refresh.lua` - Pass timeout from config
7. `lua/vscode-diff/commands.lua` - Pass timeout from config (2 places)
8. `tests/integration/core/diff/timeout_spec.lua` - Comprehensive test suite (current path)
9. `tests/run_tests.sh` - Added to test runner

---

**Date**: 2025-01-07
**Status**: ✅ Complete - Bug fixed, tests passing, VSCode parity achieved
