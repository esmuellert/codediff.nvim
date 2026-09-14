# Refresh E2E coverage against main

Baseline: `main` / `origin/main` at
`4b3ad7eb99dd0f02e64bbaf562ca1e87e8c07cc9`.

This audit covers the refresh implementation, its session-data refactor, and
regressions found while expanding the tests. Paths below are relative to
`lua/codediff/`. Deleted modules are mapped to their replacement behavior rather
than tested through compatibility adapters.

## Fixture and observation contract

All Git-backed tests use `tests/framework/repository.lua`, including callers of
`tests/helpers.lua:create_temp_git_repo`. The richer UI scenarios share
`tests/fixtures/refresh_repo.lua`. Each case owns a temporary repository and
worktree; cases never share mutable refs, indexes or object files. See
[the fixture documentation](../../fixtures/README.md).

The tests start an actual `nvim --embed`, issue commands or keyboard/mouse input,
and observe rendered screen cells. Git operations affect a real repository.
Native cases require the real watcher to become ready. Polling cases explicitly
disable the native transport and exercise the 500 ms fallback. No test replaces
notifications with a call to an internal refresh method.

Race cases delay delivery of **real Git results**, without replacing their
contents. The read-error case temporarily removes a real loose Git object.
Dialog cases answer Neovim's actual confirmation prompt. Expected file contents,
Git blobs, paths, colors and navigation destinations come from the fixture or
Git, not production diff/gutter calculators.

The existing hand-authored gutter shape tests remain component-level screen
checks. They deliberately use synthetic buffers to test visual projections that
are difficult to express through a Git merge. They are not counted below.

## Scenario matrix

A named scenario is distinct from its parameterized executions. The matrix has
132 named scenarios and 544 E2E executions on a platform with a native watcher.
Fixture tests and unit tests are not included in these counts.

| Spec in this directory | Scenarios | Executions | Parameters |
| --- | ---: | ---: | --- |
| `refresh_e2e_spec.lua` | 16 | 64 | native/polling × side-by-side/inline |
| `conflict_refresh_e2e_spec.lua` | 10 | 20 | native/polling; three missing-stage shapes |
| `file_refresh_e2e_spec.lua` | 3 | 6 | side-by-side/inline; plain-file polling |
| `lifecycle_e2e_spec.lua` | 17 | 66 | both transports/layouts; process exit is native-only |
| `hunk_actions_e2e_spec.lua` | 14 | 54 | both transports/layouts; manual-only mode runs per layout |
| `explorer_actions_e2e_spec.lua` | 20 | 80 | both transports/layouts |
| `history_actions_e2e_spec.lua` | 14 | 56 | both transports/layouts |
| `merge_actions_e2e_spec.lua` | 15 | 120 | both transports × ours left/right × Result bottom/center |
| `source_refresh_e2e_spec.lua` | 19 | 74 | both transports/layouts; plain-file case runs per layout |
| `virtual_file_e2e_spec.lua` | 4 | 4 | direct public `codediff://` buffer commands |

## Production change map

### Commands and source identity

- `commands/handlers/explorer.lua`: existing symbolic-ref and two-revision E2Es;
  S06–S08, S12–S14, S19.
- `commands/handlers/explorer_staged.lua`: H02–H03, E03–E04, S04, S08, S14.
- `commands/handlers/git_diff.lua`: existing bare HEAD/ref and layout-toggle
  E2Es; S01, S03, S05, S07, S09–S10, T13, T15.
- `commands/handlers/history.lua`: Y07–Y08, Y13–Y14.
- `core/git/revision.lua`: existing fixed SHA / movable ref E2Es; S07–S10,
  S14, Y07–Y08.
- `core/git/content.lua`: existing index and missing-stage E2Es; S02, S04,
  S06–S10, V02–V04, T12.
- `core/git/changes.lua`: E01–E16, Y01–Y14, S06, S12–S14. Quoted rename paths,
  literal arrows, and root-commit file discovery have dedicated cases.
- `core/virtual_file.lua`: S02, S04, V01–V04, existing delayed-read/file-switch
  E2Es, and T16.

### Refresh ownership and lifecycle

- `ui/refresh/init.lua`: all transport E2Es; H13, E04, Y06, T09–T16 and the
  existing real watcher-exit case.
- `ui/refresh/inputs.lua`: existing unchanged-status, unsaved-edit, fixed-ref,
  staged-only, missing-stage and pending-read E2Es; S01–S19, T12–T13.
- `ui/refresh/panel.lua`: E01–E20, Y01–Y14, S06–S08, S12–S14, S19.
- `ui/refresh/policy.lua`: actual worktree/index/HEAD/refs changes throughout
  the transport matrix; unit coverage additionally checks all 16 watcher masks.
- `ui/auto_refresh.lua` (removed): H01–H14, C01–C15, T09–T16.
- `ui/explorer/refresh/init.lua` (removed): existing same-status refresh E2Es;
  E01–E20, S04–S06, S08, S12–S14, S19.
- `ui/explorer/refresh/scheduler.lua` (removed): existing native-ready, polling,
  burst and process-exit E2Es; H13 and T09–T12.
- `ui/history/refresh.lua` (removed): Y01–Y14 and the existing history-head refresh.
- `ui/follow_working_file.lua`: existing HEAD-follow and cross-repository E2Es;
  T13 covers leaving Git and returning to a different repository.
- `ui/lifecycle/accessors.lua`: T10–T16, E15, Y12, C14–C15, H11.
- `ui/lifecycle/cleanup.lua`: T10–T11, T14–T16, C14–C15 and existing pending-close
  and buffer-wipe E2Es.
- `ui/lifecycle/init.lua`: the shared-buffer ownership contract in T16.
- `ui/lifecycle/session.lua`: T09–T16, H11, C14–C15 and multi-tab E2Es.
- `ui/lifecycle/state.lua`: T09–T10, T15–T16, H12, S16, and existing conflict
  suspension/Result preservation E2Es.

### Explorer and History presentation

- `ui/explorer/actions.lua`: E01–E20.
- `ui/explorer/init.lua`: E01–E20 and command-driven construction.
- `ui/explorer/keymaps.lua`: E01–E20, H13; these send actual keys/mouse events.
- `ui/explorer/render.lua`: E01–E20, S04, S06, S12–S14, S19.
- `ui/explorer/tree.lua`: E05–E06, E09–E11, E13, E18.
- `ui/history/init.lua`: Y01–Y14.
- `ui/history/keymaps.lua`: Y02–Y14.
- `ui/history/render.lua`: Y01–Y14, including lazy expansion, filtering, ordering,
  added/deleted/renamed files and layout transitions.

### Comparison and merge rendering

- `ui/view/init.lua`: H11, E15, E19, Y02–Y04, Y07, Y11–Y12, S04–S05, S17, T13,
  C14–C15 and existing layout-toggle E2Es.
- `ui/view/helpers.lua`: E15, S01–S19, T13, T15–T16, V01–V04.
- `ui/view/render.lua`: H01–H14, S15–S18, T09, T15–T16, C01–C15.
- `ui/view/panel.lua`: E01–E20, Y01–Y14, S19.
- `ui/view/toggle.lua`: H11, Y12, existing ref-follow-after-toggle and layout
  snapshot regressions.
- `ui/view/actions/diffget.lua`: H08–H09, H11, S17.
- `ui/view/actions/hunk.lua`: H01–H14, E16.
- `ui/view/actions/stage.lua`: E01–E05, C15.
- `ui/view/inline_view/buffers.lua`: inline H/E/Y/S/T cases and E15.
- `ui/view/inline_view/create.lua`: inline command-driven E2Es, S01–S19.
- `ui/view/inline_view/render.lua`: inline H01–H14, S15–S18, T09.
- `ui/view/inline_view/single_file.lua`: inline E15, Y02–Y03, Y07, Y11, S04,
  S14, S16, C15.
- `ui/view/inline_view/update.lua`: inline E/Y/T transitions, S02, S06, T13.
- `ui/view/side_by_side/create.lua`: side-by-side command-driven E2Es.
- `ui/view/side_by_side/single_file.lua`: E15, Y02–Y03, Y07, Y11, S04, S14,
  S16, C15.
- `ui/view/side_by_side/update.lua`: H11, E15, Y02–Y04, Y07, Y11–Y12, T13,
  T15–T16, C15 and existing delayed-selection E2Es.
- `ui/conflict/resolution/block.lua`: C02–C05.
- `ui/conflict/resolution/diffget.lua`: C10–C11.
- `ui/conflict/resolution/file.lua`: C06–C09, C15.
- `ui/conflict/view/inputs.lua`: C01–C15 and existing actual-stage-change E2Es.
- `ui/conflict/view/result.lua`: C01–C15, existing edited/untouched/empty Result
  and missing-stage E2Es.

## New scenario index

Each ID is part of the test name, making failures and source searches traceable.

| IDs | Contract |
| --- | --- |
| H01–H03 | Stage one/all hunks, unstage one, preserve unaffected index/working text |
| H04–H07 | Real discard/cancel dialogs, deleted lines, BOF insertions |
| H08–H10 | Diffget, undo/redo/save, layout-specific diffput, staging unsaved text |
| H11–H14 | Layout toggle, compact folds, manual-only refresh, hunk text object |
| E01–E04 | Panel/pane staging, same-group advancement, gS, stage/unstage all |
| E05–E08 | Directory staging/restoration, cancel, untracked deletion |
| E09–E13 | Group visibility, folds, list/tree, auto-open, hidden panels, filters/pathspec |
| E14–E16 | Staged rename, deleted-file return, customized mappings after buffer replacement |
| E17–E20 | Rendered hover path, tree navigation, gf/tab return, real double-click |
| Y01–Y05 | Latest/older commits, lazy files, added/deleted previews, list/tree preservation |
| Y06–Y10 | HEAD refresh, root commit, movable base tag, collapse preservation, filtering |
| Y11–Y14 | Rename paths, layout changes, line-range filtering, reverse ordering |
| C01–C05 | Independent fixture seed, marker cells/colors, per-block resolution, undo/redo/discard |
| C06–C11 | Whole-file resolution/reset and numbered diffget |
| C12–C15 | Conflict navigation, save, unrelated staging, quit dialogs, finish-and-stage workflow |
| S01–S05 | Unicode/BOM/CRLF, virtual syntax/readonly, no final newline, empty files |
| S06–S10 | Renames, fixed ancestry, movable tags, regular Git directories, SHA-256 |
| S11–S14 | Plain paths with spaces/Unicode, literal arrows, renamed arrows, unborn branches |
| S15–S19 | Whitespace policy, whole-file highlights, original-right layout, moves, --repo |
| T09–T12 | Hidden updates, hidden wipe, pane close, actual missing-object read/retry |
| T13–T16 | Leaving/returning to Git, user keymaps, inlay hints, shared buffers across tabs |
| V01–V04 | Public revision URI, write protection, reversed load completions, wipe, missing file |

The existing 38 scenarios cover unchanged-status worktree changes, unsaved
buffers, mutable index/refs/HEAD, fixed revisions, added/deleted previews,
unchanged grids, directory scans, editable Result protection, missing merge
stages, late Git callbacks, tab/buffer retirement, cross-repository following,
hidden panels, shared subscriptions and native-process failover.

## Regressions found by the expanded scenarios

| Cases | Correction |
| --- | --- |
| E15 | Read a clean, previously missing file when it reappears instead of blocking on W13 |
| S02 | Populate inline revision buffers without firing FileType/LSP attachment |
| S06, S12–S13 | Parse raw NUL-delimited status paths; use the renamed index path for unstaged content |
| Y07, Y14 | Handle parentless history commits and list their files |
| Y13–Y14 | Preserve line-range and reverse query options during history refresh |
| T13 | Materialize a genuinely empty comparison side when following a file outside Git |
| T15–T16 | Retain original buffer settings and respect buffers still owned by another session |

## Scope of the assurance

This is a behavioral change map, not a claim of 100% line/branch coverage or an
exhaustive Cartesian product of every option. Tests validate Neovim's rendered
cells, not fonts or pixels. FileType/readonly/diagnostic/inlay contracts are
covered; every external LSP server, distribution, filesystem failure, and
third-party UI plugin is not installed or simulated. OS/version results must be
reported separately. A passing matrix is evidence for these contracts, not an
absolute guarantee that no other bug exists.
