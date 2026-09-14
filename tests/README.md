# Test suite

The Lua suite runs in Neovim with the in-tree framework; no Plenary/Busted
installation is needed. Build the native library first (`make build`). Native
algorithm tests remain in `c-diff-core/tests/` and run with `make test-c`.

## Directory contract

```text
tests/
├── unit/              isolated logic and controlled collaborators
│   ├── core/          argparse, paths, installer policy, watcher protocol/manager
│   └── ui/            filters, tree data, merge alignment, refresh policy, readiness
├── integration/       component boundaries with Neovim, Git or the native library
│   ├── commands/      completion queries
│   ├── core/          Git, filesystem, FFI, installer and virtual-buffer integration
│   ├── framework/     runner and discovery self-tests
│   ├── keymap/        real buffer mappings, ownership and golden captures
│   ├── plugin/        public exports, module loading and setup compatibility
│   ├── support/       fixture-factory isolation and cleanup tests
│   └── ui/            rendering, windows, sessions and panel/controller integration
├── e2e/               public commands/keys through the complete application
│   ├── commands/      dispatch, completion, merge commands, standalone-build smoke
│   ├── conflict/      resolution actions and refresh protection
│   ├── explorer/      file actions and navigation
│   ├── history/       commit/file operations
│   ├── refresh/       repository/file inputs, transport and session lifetime
│   ├── view/          hunk operations and working-file following
│   └── virtual_file/  public revision URI and diagnostic isolation
├── fixtures/          deterministic repository profiles and hand-authored golden data
├── support/           shared Git factory, plugin helpers and UI drivers
├── framework/         collector, assertions, reporter, runner and RPC screen transport
├── init.lua           shared Neovim/Git sandbox bootstrap
└── run_tests.{sh,cmd}  equivalent POSIX/Windows entry points
```

**The first directory defines the test level; the next directories define the
feature.** All runnable `*_spec.lua` files live in `unit/`, `integration/` or
`e2e/`, including tests of the test infrastructure itself. Discovery self-tests
enforce this boundary and verify that the layers form a complete, disjoint suite.

- **Unit:** isolated logic such as parsing, policy or data transformations.
  Neovim supplies LuaJIT and `vim` utilities; this does not make a test E2E.
- **Integration:** exercises component APIs and their real boundaries. Creating a
  view directly, invoking a registered callback, supplying synthetic conflict
  ranges or manually emitting an autocmd belongs here. The gutter screen tests
  are integration tests even though they attach a real RPC UI.
- **E2E:** starts at a public command or user input, runs the real Git/file/view
  pipeline, and checks observable outcomes. Older command scenarios inspect
  buffers and window state; the interaction/refresh matrix also asserts actual
  screen cells. Git-backed cases use disposable fixtures, not checkout history.

Name files for their behavior, not an issue number or test level. For example,
`e2e/explorer/untracked_tab_spec.lua` retains its issue reference inside the test.
Do not add redundant `_e2e`/`_integration` suffixes or helper compatibility shims.
Extend an existing spec when it covers the same responsibility.

## Running tests

```bash
./tests/run_tests.sh                                      # all layers; same as make test-lua
./tests/run_tests.sh unit
./tests/run_tests.sh integration
./tests/run_tests.sh e2e
./tests/run_tests.sh tests/e2e/conflict                    # one feature
./tests/run_tests.sh tests/unit/core/path_spec.lua         # one file
./tests/run_tests.sh --help
```

Use `tests\run_tests.cmd` with the same arguments on Windows. Targets may be
layer names, directories or individual specs. Paths are resolved from the
checkout root, regardless of the shell's starting directory. Missing targets
and selections containing no specs fail rather than reporting a green empty run.

For direct Neovim use:

```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_all_and_exit({ dir = 'e2e' })"
```

Each spec gets its own child Neovim process. The supervisor discovers files
recursively, runs a bounded worker pool and prints each child's output as one
block. Start messages and a 30-second active-worker heartbeat distinguish long
specs from a stalled runner. New specs need no manifest or CI enumeration changes.
Windows CI uses four workers and a 15-minute per-spec budget for large E2E
matrices; individual asynchronous assertions retain their own bounded waits.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `CODEDIFF_TEST_TARGET` | `all` | Same selector as the positional argument; an explicit argument wins |
| `CODEDIFF_TEST_JOBS` | 2× CPUs, capped at 16 | Concurrent spec workers; `1` runs sequentially |
| `CODEDIFF_TEST_TIMEOUT` | `300000` | Per-spec timeout in milliseconds |
| `NO_COLOR` / `CODEDIFF_TEST_NO_COLOR` | unset | Disable ANSI output |
| `CODEDIFF_WATCHER_PATH` | installer default | Existing native watcher executable for offline E2Es |
| `CODEDIFF_TEST_UPSTREAM_SCROLLBIND` | unset | Opt into the strict tall-virtual-line regression on a Neovim build carrying the upstream fix |

## Fixtures and shared support

Import helpers as modules, not cwd-relative `dofile` calls:

```lua
local h = require("tests.support")
local ui = require("tests.support.e2e")
local repositories = require("tests.support.repository")
local fixture = require("tests.fixtures.refresh_repo")
```

- `support/repository.lua` owns the isolated TMP repository/worktree factory.
  Cases never share mutable refs, indexes or object files.
- `fixtures/refresh_repo.lua` supplies the basic, hunks, workspace, history and
  merge profiles; `fixtures/conflict_gutter.lua` supplies independent visual
  expectations and the focused gutter merge fixture.
- `support/init.lua` exposes plugin waiters and `project_root`. Tests must not
  infer the checkout root by counting their own parent directories.
- `support/e2e.lua` drives embedded UI workflows. `support/gutter.lua` drives
  focused renderer checks. `support/keymaps.lua` captures mapping matrices.
- `framework/screen.lua` owns generic RPC transport and screen-grid observation,
  not feature fixtures or business assertions.

Close embedded UIs before cleaning up their repositories, including on failed
assertions. Skipping during setup still runs cleanup; cleanup failures must not
be hidden by a skip. See [fixtures/README.md](fixtures/README.md) for the graph,
factory options, cleanup guarantees and interactive reproduction commands.

## Environment and observable behavior

`init.lua` disables auto-installation, ShaDa and swap files, isolates Git config,
and removes inherited repository/index overrides. It pins `core.autocrlf=false`
for all Git children, including on Windows. Neovim's per-buffer autoread watcher
is disabled to avoid watching deleted fixture paths, while `autoread` itself
remains available to `:checktime`.

Synchronous headless specs can inspect buffers, extmarks, windows and options.
They cannot observe rendered cells or naturally dispatched `WinScrolled` /
`WinResized` merely by calling `vim.wait`. Use `framework/screen.lua` and a
separate `nvim --embed` for those observations. Always close the screen in
`after_each`.

Native refresh E2Es require a real watcher and verify that it became ready;
silent fallback is not a native-test pass. Polling cases disable native startup
and exercise the 500 ms fallback. Android skips native cases only. Race tests
may delay delivery of real Git results, but do not fabricate their contents.

The tall-virtual-line monotonicity check is an upstream Neovim probe, not a
CodeDiff workaround. Neovim reverted #41519 in `0c9012f`, so a `0.13` version
check is insufficient. Its assertion remains opt-in on fixed builds; CodeDiff's
own scrollbind setup is checked unconditionally. Synthetic gutter fixtures
retire their comparison controller so periodic input reads cannot overwrite the
hand-authored projections; real merge E2Es keep the full controller active.

## Behavioral coverage

[e2e/COVERAGE.md](e2e/COVERAGE.md) maps the refresh changes against `main` to
scenario IDs and parameterized executions. Its 133 named scenarios / 548
executions are a specific cross-feature matrix, **not the total E2E suite** and
not a count of unit or integration tests. Additional command and working-file
E2Es live alongside it. The runner reports the selected suite's actual counts.

These tests provide evidence for documented behaviors, not an absolute safety
guarantee, pixel/font snapshots, or coverage of every external LSP, UI plugin,
filesystem and operating-system combination.
