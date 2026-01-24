---
name: nvim-e2e-workflow
description: Investigate and fix Lua plugin issues using Neovim headless mode. Use this skill when working on GitHub issues for this codediff/vscode-diff.nvim plugin - it provides E2E testing capabilities to reproduce issues, implement fixes, and validate changes.
---

# Neovim E2E Workflow for codediff Plugin

This skill enables end-to-end investigation and fixing of Lua plugin issues using Neovim headless mode.

## Repository Overview

- **Plugin name**: codediff (formerly vscode-diff)
- **Type**: Neovim Lua plugin with native C bindings
- **Main module**: `require("codediff")`
- **Test framework**: plenary.nvim

---

## Workflow: End-to-End Issue Resolution

When assigned a GitHub issue, follow this complete workflow:

### Phase 1: Fetch and Understand the Issue

Use the GitHub MCP tools to get issue details:

```
github-mcp-server-issue_read(method="get", owner="esmuellert", repo="vscode-diff.nvim", issue_number=<N>)
```

Then search the codebase for relevant code:
```bash
grep -r "pattern" lua/codediff/
```

### Phase 2: Reproduce the Issue

Create a scenario script that reproduces the issue. Save it to `/tmp/repro.lua`:

```lua
-- Scenario: Reproduce issue #N
return {
  setup = function(ctx, e2e)
    -- Create test environment
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("test.txt", {"original content"})
    ctx.repo.git("add .")
    ctx.repo.git("commit -m 'initial'")
    ctx.repo.write_file("test.txt", {"modified content"})
    vim.cmd("edit " .. ctx.repo.path("test.txt"))
  end,

  run = function(ctx, e2e)
    -- Execute the action that triggers the issue
    e2e.exec("CodeDiff")
    e2e.wait_for_explorer(5000)
  end,

  validate = function(ctx, e2e)
    -- Check current (broken) behavior
    -- Return false if issue is reproduced, true if already fixed
    local has_explorer = e2e.wait_for_explorer(2000)
    if not has_explorer then
      print("Issue reproduced: Explorer did not open")
      return false
    end
    return true
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
```

Run it with:
```bash
SCENARIO_FILE=/tmp/repro.lua nvim --headless -u tests/init.lua -c "luafile scripts/nvim-e2e.lua" -c "qa!" 2>&1
```

### Phase 3: Implement the Fix

1. Edit files in `lua/codediff/` based on investigation
2. Keep changes minimal and focused
3. Follow existing code patterns

### Phase 4: Validate the Fix

Run the same scenario - it should now pass:
```bash
SCENARIO_FILE=/tmp/repro.lua nvim --headless -u tests/init.lua -c "luafile scripts/nvim-e2e.lua" -c "qa!" 2>&1
```

Then run the full test suite:
```bash
./tests/run_plenary_tests.sh
```

---

## E2E Runner API Reference

The `scripts/nvim-e2e.lua` module provides comprehensive helpers for simulating user workflows.

### Git Repository

```lua
local repo = e2e.create_temp_git_repo()
repo.dir                              -- Full path to repo
repo.git("add .")                     -- Run git command
repo.write_file("path", {"line1"})    -- Write file
repo.read_file("path")                -- Read file as lines
repo.path("rel/path")                 -- Get full path
repo.cleanup()                        -- Delete repo
```

### Waiting

```lua
e2e.wait(timeout_ms, condition_fn)    -- Wait for condition
e2e.wait_for_new_tab(timeout_ms)      -- Wait for new tab
e2e.wait_for_explorer(timeout_ms)     -- Wait for explorer window
e2e.wait_for_diff_ready(timeout_ms)   -- Wait for diff session ready
e2e.wait_for_buffer_content(bufnr, text, timeout_ms)
```

### Windows and Buffers

```lua
e2e.find_window_by_filetype("codediff-explorer")  -- Returns winid, bufnr
e2e.get_all_windows()                 -- List all windows with metadata
e2e.focus_window(winid)               -- Focus specific window
e2e.focus_explorer()                  -- Focus explorer window
e2e.get_buffer_content(bufnr)         -- Get buffer as string
e2e.get_buffer_lines(bufnr)           -- Get buffer as lines table
e2e.get_cursor_position()             -- Returns {line, col}
e2e.set_cursor_position(line, col)    -- Set cursor
```

### Diff Session

```lua
e2e.get_diff_buffers()                -- Returns orig_buf, mod_buf
e2e.get_diff_session()                -- Get full session object
e2e.get_original_content()            -- Get original buffer content
e2e.get_modified_content()            -- Get modified buffer content
e2e.create_diff_view(config)          -- Create new diff view
e2e.update_diff_view(config)          -- Update current diff view
```

### Explorer

```lua
e2e.get_explorer_files()              -- Get explorer buffer lines
e2e.select_explorer_item(line_num)    -- Select item by line number
```

### Commands and Keypresses

```lua
e2e.exec("CodeDiff HEAD~1")           -- Run vim command
e2e.feedkeys("<leader>b", "n")        -- Raw keypress
e2e.press("]c", 200)                  -- Keypress with wait

-- Built-in navigation (using plugin defaults)
e2e.next_hunk()                       -- ]c
e2e.prev_hunk()                       -- [c
e2e.next_file()                       -- ]f
e2e.prev_file()                       -- [f
e2e.toggle_stage()                    -- -
e2e.toggle_explorer()                 -- <leader>b
e2e.quit_diff()                       -- q

-- Conflict resolution
e2e.accept_incoming()                 -- <leader>ct
e2e.accept_current()                  -- <leader>co
e2e.accept_both()                     -- <leader>cb
e2e.next_conflict()                   -- ]x
e2e.prev_conflict()                   -- [x

-- Diff operations
e2e.diff_get()                        -- do
e2e.diff_put()                        -- dp
```

### Git Status

```lua
e2e.get_git_status(repo_dir)          -- Get parsed git status
e2e.is_file_staged(repo_dir, "file.txt")  -- Check if file is staged
```

### Assertions

```lua
e2e.assert_contains(str, substr, msg) -- Check substring
e2e.assert_equals(expected, actual, msg)
e2e.assert_true(value, msg)
```

---

## Scenario Examples

### Example: Test Hunk Navigation

```lua
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file.txt", {"line 1", "line 2", "line 3", "line 4", "line 5"})
    ctx.repo.git("add . && git commit -m 'initial'")
    ctx.repo.write_file("file.txt", {"CHANGED 1", "line 2", "CHANGED 3", "line 4", "CHANGED 5"})
    vim.cmd("edit " .. ctx.repo.path("file.txt"))
  end,

  run = function(ctx, e2e)
    e2e.exec("CodeDiff")
    e2e.wait_for_diff_ready(5000)

    local _, mod_buf = e2e.get_diff_buffers()
    local mod_win = vim.fn.bufwinid(mod_buf)
    e2e.focus_window(mod_win)

    ctx.positions = {}
    e2e.set_cursor_position(1, 0)
    e2e.next_hunk()
    table.insert(ctx.positions, e2e.get_cursor_position().line)
    e2e.next_hunk()
    table.insert(ctx.positions, e2e.get_cursor_position().line)
  end,

  validate = function(ctx, e2e)
    return #ctx.positions >= 2
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
```

### Example: Test Staging Workflow

```lua
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file.txt", {"original"})
    ctx.repo.git("add . && git commit -m 'initial'")
    ctx.repo.write_file("file.txt", {"modified"})
    vim.cmd("edit " .. ctx.repo.path("file.txt"))
  end,

  run = function(ctx, e2e)
    e2e.exec("CodeDiff")
    e2e.wait_for_explorer(3000)

    e2e.focus_explorer()
    e2e.set_cursor_position(1)
    e2e.toggle_stage()
    e2e.wait(500)
  end,

  validate = function(ctx, e2e)
    return e2e.is_file_staged(ctx.repo.dir, "file.txt")
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
```

### Example: Test Diff Content

```lua
return {
  setup = function(ctx, e2e)
    ctx.repo = e2e.create_temp_git_repo()
    ctx.repo.write_file("file.txt", {"line 1", "line 2"})
    ctx.repo.git("add . && git commit -m 'initial'")
    ctx.repo.write_file("file.txt", {"line 1", "line 2 MODIFIED"})
    vim.cmd("edit " .. ctx.repo.path("file.txt"))
  end,

  run = function(ctx, e2e)
    e2e.exec("CodeDiff")
    e2e.wait_for_diff_ready(5000)
  end,

  validate = function(ctx, e2e)
    local original = e2e.get_original_content()
    local modified = e2e.get_modified_content()

    local ok = true
    ok = ok and e2e.assert_contains(original, "line 2", "Original should have line 2")
    ok = ok and e2e.assert_contains(modified, "MODIFIED", "Modified should have change")
    return ok
  end,

  cleanup = function(ctx, e2e)
    if ctx.repo then ctx.repo.cleanup() end
  end
}
```

---

## Quick Commands

**Run a scenario:**
```bash
SCENARIO_FILE=/tmp/scenario.lua nvim --headless -u tests/init.lua -c "luafile scripts/nvim-e2e.lua" -c "qa!" 2>&1
```

**Quick inline check:**
```bash
nvim --headless -u tests/init.lua -c "lua print(vim.inspect(require('codediff.config').options))" -c "qa!"
```

**Run all tests:**
```bash
./tests/run_plenary_tests.sh
```

**Run single test file:**
```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_file('tests/explorer_spec.lua', { minimal_init = 'tests/init.lua' })"
```

---

## Module Structure

```
lua/codediff/
├── init.lua              -- Main entry, setup()
├── config.lua            -- Configuration
├── commands.lua          -- :CodeDiff command
├── version.lua           -- Version info
├── core/
│   ├── diff.lua          -- FFI diff computation
│   ├── git.lua           -- Git operations (async)
│   └── virtual_file.lua  -- Virtual buffer handling
└── ui/
    ├── init.lua          -- UI setup
    ├── render.lua        -- Diff rendering
    ├── explorer.lua      -- File explorer
    └── lifecycle.lua     -- Session management
```

## Important Notes

- Always create scenarios in `/tmp/` - never in the repository
- Scenarios must return a table with setup/run/validate/cleanup functions
- Use `vim.wait()` for async operations (git, file loading)
- Clean up temp directories in the cleanup phase
- The plugin module is `codediff`, not `vscode-diff`
