---
applyTo: "tests/**"
---

# Test Directory Guidelines

When working with tests in this directory:

- **Headless boundaries**: Read `.agents/skills/nvim-headless/SKILL.md` before writing specs that involve scroll events, timers, or window geometry
- **Test levels**: Put runnable specs under `tests/unit/`, `tests/integration/`, or `tests/e2e/`, then group by feature. Isolated logic belongs in unit; direct component calls and Neovim/Git/FFI boundaries belong in integration; public commands or real user input through the whole application belong in E2E. Using Git or an embedded screen alone does not make a component test E2E.
- **Names and shared code**: Use behavior-based `*_spec.lua` names, without redundant `_e2e`/`_integration` suffixes. Keep issue references inside cases. Shared drivers and the Git factory belong in `tests/support/`, data in `tests/fixtures/`, and the runner/RPC transport in `tests/framework/`. Infrastructure self-tests also belong in a test layer.
- **Extend existing tests**: Add new test cases to existing test files whenever possible; only create new test files when covering genuinely distinct functionality.
- **Fixtures and imports**: Use the shared repository factory rather than the source checkout's Git history. Import helpers through `require("tests.support")` and its submodules, not cwd-relative `dofile` or old-path adapters. Use `support.project_root` rather than counting a spec's parent directories.
- **Test runner**: Specs are auto-discovered by `tests/framework/supervisor.lua` with no CI enumeration changes. `tests/run_tests.sh` and `.cmd` accept `all`, `unit`, `integration`, `e2e`, a directory, or a single spec. Discovery self-tests enforce the directory boundary.
- **No legacy API in tests**: When fixing tests, always update them to use the latest API; never add backward compatibility or reintroduce removed APIs for test compatibility—tests must use current production APIs
