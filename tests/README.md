# Test Suite

Integration tests for vscode-diff.nvim using [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

## Test Coverage

### ✅ FFI Integration (ffi_integration_spec.lua)
C ↔ Lua boundary validation:
- Data structure conversion
- Memory management (no leaks)
- Edge cases (empty diffs, large files)

**10 tests**

### ✅ Git Integration (git_integration_spec.lua)
Git operations and async handling:
- Repository detection
- Async callbacks
- Error handling for invalid revisions
- Path calculation
- LRU cache validation

**9 tests**

### ✅ Auto-scroll (autoscroll_spec.lua)
Diff view scrolling behavior:
- Scroll to first change
- Window centering
- Scroll sync activation

**5 tests**

### ✅ Semantic Tokens (render/semantic_tokens_spec.lua)
LSP integration and rendering:
- Module compatibility checks
- Virtual file URL handling
- Namespace management

**12 tests**

## Running Tests

### All tests:
```bash
./tests/run_plenary_tests.sh
```

### Individual spec:
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/ffi_integration_spec.lua')"
```

## Test Philosophy

Focus on **integration points** that C tests cannot validate:
- FFI boundary integrity
- Lua async operations
- System integration (git)
- UI behavior (scrolling, rendering)

**Total: 36 tests** across 4 spec files using industry-standard plenary.nvim framework.

## What's NOT Covered

❌ **Diff algorithm** - Validated by C tests in `c-diff-core/tests/` (3,490 lines)
❌ **Visual correctness** - Manual testing required
