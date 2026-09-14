---
name: nvim-headless
description: Reproduce issues, verify fixes, and write specs in headless Neovim. Defines what is observable without a UI, what needs a workaround, and what is not possible. Use when investigating issues, writing throwaway repro scripts, or adding test cases.
---

# Headless Neovim for codediff

## The one rule

Not "headless can't do it" — "synchronous code can't observe deferred events."

Specs run synchronously inside `-c "run_and_exit(spec)"`. The main loop never
regains control, so events that fire from `normal_check()` — `WinScrolled`,
`WinResized` — are never dispatched. This is identical with or without a UI.

## What works

Everything data-level:

- buffer read/write, `nvim_buf_get_lines` / `set_lines`
- extmarks with `details=true`: highlights, `virt_lines`, signs
- `nvim_get_hl` (resolved colors)
- window splits, layout, `nvim_tabpage_list_wins`
- cursor, `winsaveview` (topline, topfill, leftcol)
- topfill accounting through `virt_lines` blocks
- folds (`foldclosed`, `zf`, `zo`)
- immediate autocmds: `BufEnter`, `WinEnter`, `CursorMoved`, `TabNew`, …
- `vim.system` + `vim.wait` (async child processes)
- `vim.uv` timers under `vim.wait`
- keymaps via `feedkeys` with `"x"` (execute immediately) flag
- treesitter parsers and queries
- git operations via `require("tests.support")` (`create_temp_git_repo`, `git_cmd`)

## What needs a workaround

`WinScrolled` and `WinResized` — fire them manually after scrolling:

```lua
vim.cmd("normal! 20\5") -- 20x <C-e>
vim.api.nvim_exec_autocmds("WinScrolled", {})
```

This is what existing specs already do.

## What requires a separate UI

- **Rendered screen content** (which character is at row/col, its color) is not
  observable in the synchronous headless test process. Use
  `tests/framework/screen.lua`, which starts `nvim --embed` and attaches an RPC
  UI. Close it in `after_each`, even on assertion failure.
- **`UIEnter`** does not fire without an attached UI. Plugins that lazy-load on
  it (e.g. `snacks.nvim`) need explicit initialization in a plain headless spec.

The observation tool does not define the test level. Screen checks that call
renderers directly are integration tests; public commands or actual key input
through the complete application belong in `tests/e2e/`.

## Driving styles

| Style | When to use | WinScrolled? |
|---|---|---|
| Synchronous (default for specs) | Most tests | Manual `exec_autocmds` |
| `defer_fn` coroutine chain | Timer/animation interactions | Fires naturally |
| Separate `nvim --embed` child | Screen-level assertions | Fires naturally |

For a `defer_fn` chain (e.g. reproducing animation conflicts):

```lua
local co = coroutine.create(function()
  -- step 1
  coroutine.yield(200) -- ms to wait before next step
  -- step 2
end)
local function resume()
  local ok, delay = coroutine.resume(co)
  if ok and coroutine.status(co) ~= "dead" then
    vim.defer_fn(resume, delay or 50)
  end
end
vim.defer_fn(resume, 100)
```

## Traps

- **`helpers.wait_for_diff_ready()`** captures `tabpage` at call time.
  `:CodeDiff file <rev>` creates the tab asynchronously, so calling it
  immediately polls the wrong tab. Use `wait_for_new_tab` first, or poll
  `get_current_tabpage()` inside the condition.

- **Default terminal size is 24×80** (window height 22). Set `vim.o.lines`
  explicitly when assertions depend on height.

- **`vim.wait` does NOT pump the normal-mode loop.** It processes libuv
  callbacks (timers, child process I/O) but not deferred display events.
  Do not expect `WinScrolled` to fire inside `vim.wait`.

## Entry points

| What | Where |
|---|---|
| Test bootstrap | `tests/init.lua` |
| Helpers (git repos, waiters) | `tests/support/init.lua` (`require("tests.support")`) |
| Framework (describe/it/assert) | `tests/framework/init.lua` |
| Run all specs | `./tests/run_tests.sh` or `make test-lua` |
| Run one layer | `./tests/run_tests.sh unit` / `integration` / `e2e` |
| Run one spec | `./tests/run_tests.sh tests/unit/core/path_spec.lua` |
| Throwaway repro | Save to `/tmp/repro.lua`, run with `nvim --headless -u tests/init.lua -c "luafile /tmp/repro.lua" -c "qa!"` |
