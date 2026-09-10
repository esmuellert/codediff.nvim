# Test Suite

Integration tests for codediff.nvim using an in-tree, self-contained test framework
(`tests/framework/`) that implements the familiar `describe/it/before_each/after_each/assert.*`
API in pure Lua + Neovim built-ins. No external test dependencies are required.

## Test Coverage

### ✅ FFI Integration (ffi_integration_spec.lua)
C ↔ Lua boundary validation:
- Data structure conversion
- Memory management (no leaks)
- Native and Lua version agreement
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

### ✅ Installer (installer_spec.lua)
Automatic binary installation and version management:
- Module API validation
- VERSION loading from version.lua
- Library path construction
- Version detection from filenames
- Update necessity logic
- Platform-specific extension handling

**10 tests**

### ✅ Auto-scroll (autoscroll_spec.lua)
Diff view scrolling behavior:
- Scroll to first change
- Window centering
- Scroll sync activation

**5 tests**

## Running Tests

### All tests:
```bash
./tests/run_tests.sh          # or: make test-lua
```

Spec files are auto-discovered under `tests/`, so a new `*_spec.lua` is picked
up with no runner changes.

### Individual spec:
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_and_exit('tests/core/ffi_integration_spec.lua')"
```

### How the suite runs

Each spec file gets its own child `nvim --headless` process, so specs stay
isolated from one another. `tests/framework/supervisor.lua` runs those children
concurrently from a single parent Neovim, which cuts the suite from ~150s to
~35s on a 4-core machine.

Children never share the parent's stdout: their output is buffered in full and
printed as one contiguous block when they exit. Letting concurrent processes
write to the same stream interleaves their output, both block-wise (stdout is
fully buffered when it isn't a tty) and line-wise (Neovim writes some messages
without a trailing newline).

Concurrency needs `vim.system()` (Neovim 0.10+). On older versions the suite
automatically falls back to running the same children one at a time, producing
the same output, just slower.

### Test environment

`tests/init.lua` is the bootstrap every child loads. Besides putting the plugin
on the runtimepath it disables a few pieces of Neovim that fight with throwaway
temp repositories: ShaDa, swap files, and the filewatcher backing for
`'autoread'` (via `g:loaded_autoread`, which must stay set before the
`runtime! plugin/*.lua` line that sources Neovim's own runtime plugins).

The `'autoread'` option itself stays on, so `:checktime` still reloads buffers
silently. Only the per-buffer `uv_fs_event` goes away — specs delete the repos
they opened files from, and a watcher left pointing at a deleted path prints
`E211` on Linux and raises `EPERM` in an unbreakable loop on Windows.

| Env var | Default | Purpose |
| --- | --- | --- |
| `CODEDIFF_TEST_JOBS` | 2x CPUs, capped at 16 | Concurrent spec workers. `1` forces sequential. |
| `CODEDIFF_TEST_TIMEOUT` | `300000` | Per-spec timeout in ms; guards against a hung spec stalling CI. |
| `NO_COLOR` / `CODEDIFF_TEST_NO_COLOR` | unset | Disable ANSI colors. |

## Screen-grid regressions

`tests/framework/screen.lua` starts a separate `nvim --embed` and attaches an
RPC UI. Assertions read actual `grid_line` cells and highlight colors, not
extmark metadata or screen functions in the headless test process. It uses
Neovim's bundled MessagePack and libuv, with no external dependencies.

The conflict gutter has three automatically discovered specs:

- `ui/conflict/gutter_grid_spec.lua`: hand-authored block shapes from
  `fixtures/conflict_gutter.lua`, including empty/filler-only blocks, BOF/EOF,
  partial scrolling, unrelated blank rows, multiple blocks and Result
  projections. Checks both glyph cells and colors in all three panes under
  each focus state. Fixtures go through the production conflict renderer;
  expected rows do not call or duplicate the gutter calculator.
- `ui/conflict/gutter_options_spec.lua`: compares ordinary columns against
  Neovim's native rendering, including relative/hybrid numbers, folds, wrapped
  rows and other signs; checks custom-option ownership and restoration.
- `ui/conflict/gutter_lifecycle_spec.lua`: real Git merges, file/window/tab
  transitions, resizing, accept/undo/redo/discard, manual Result edits and
  teardown of stale callbacks and invalid sessions.

Run these like any other spec, for example:

```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_and_exit('tests/ui/conflict/gutter_grid_spec.lua')"
```

Always close the embedded UI in `after_each`, including when an assertion
fails. A grid failure reports the pane/focus context, display row, expected
text and actual text. These are cell-level checks, not font or pixel snapshots.

## Test Philosophy

Focus on **integration points** that C tests cannot validate:
- FFI boundary integrity
- Lua async operations
- System integration (git)
- UI behavior (scrolling, rendering)

## What's NOT Covered

❌ **Diff algorithm** - Validated by C tests in `c-diff-core/tests/` (3,490 lines)
❌ **Other visual features and third-party UI integrations** - Manual testing unless covered by a dedicated grid spec
