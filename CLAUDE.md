# Claude Context - codediff.nvim

## Project Overview
Neovim diff plugin using VSCode's diff algorithm (C library via LuaJIT FFI). Provides side-by-side and unified diff views, Git integration, merge conflict resolution, and file explorer.

## Architecture
- **C Core:** Myers diff algorithm with character-level refinement (libvscode-diff)
- **Lua UI:** Neovim extmarks for rendering, async Git operations, session management
- **FFI Bridge:** LuaJIT FFI for C library integration

## Key Modules

### Core
- `lua/codediff/core/diff.lua` - FFI wrapper for C diff library
- `lua/codediff/core/git.lua` - Git operations (async)
- `lua/codediff/core/lifecycle.lua` - Session management

### UI
- `lua/codediff/ui/view.lua` - Side-by-side diff view
- `lua/codediff/ui/unified/` - Unified (single-pane) diff view
- `lua/codediff/ui/highlights.lua` - Highlight groups and extmarks
- `lua/codediff/ui/explorer/` - File tree panel
- `lua/codediff/ui/render.lua` - Side-by-side rendering

### Commands
- `lua/codediff/commands.lua` - Command parsing and routing
- `lua/codediff/config.lua` - Configuration management

## Critical APIs (Verified)

### Git
```lua
git.get_file_content(revision, git_root, rel_path, callback)
git.get_relative_path(file_path, git_root)
```

### Diff
```lua
diff.compute_diff(original_lines, modified_lines, opts)
-- Returns: { changes = { {original = {...}, modified = {...}, inner_changes = {...}} } }
```

### Lifecycle
```lua
lifecycle.create_session(tabpage, mode, git_root, ...)
```

### Data Structures
```lua
-- Change object
{
  original = { start_line = 1, end_line = 5 },  -- 1-based, end-exclusive
  modified = { start_line = 1, end_line = 3 },
  inner_changes = {
    {
      original = { start_line = 2, end_line = 3, start_col = 5, end_col = 10 },  -- UTF-16
      modified = { start_line = 2, end_line = 2, start_col = 5, end_col = 8 }
    }
  }
}
```

## Indexing Conventions
- **C library:** 1-based lines, UTF-16 columns, end-exclusive ranges
- **Lua tables:** 1-based indexing
- **Neovim API:** 0-based indexing

## Common Patterns

### Async File Operations
```lua
git.get_file_content(rev, root, path, function(err, lines)
  if err then
    vim.schedule(function() vim.notify(err, vim.log.levels.ERROR) end)
    return
  end
  vim.schedule(function()
    -- All vim.fn.* and vim.api.* calls must be in vim.schedule()
    local content = vim.fn.readfile(path)
  end)
end)
```

### Extmark Highlights
```lua
-- Line-level (priority 100)
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
  end_line = line_idx + 1,
  hl_group = "CodeDiffLineInsert",
  hl_eol = true,
  priority = 100,
})

-- Character-level (priority 200)
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col, {
  end_col = end_col,
  hl_group = "CodeDiffCharInsert",
  priority = 200,
})
```

### UTF-16 to UTF-8 Conversion
```lua
local byte_col = vim.str_byteindex(line_text, utf16_col - 1, true) + 1
```

## Testing

### Run Tests
```bash
# All tests
nvim --headless -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

# Specific test
nvim --headless -c "PlenaryBustedFile tests/unified_integration_spec.lua"
```

### Manual Testing
```vim
:CodeDiff --unified file HEAD~1
:CodeDiff file HEAD~1 HEAD
:CodeDiff /path/a.lua /path/b.lua
```

## Code Style
- No verbose AI comments (preserve existing comments only)
- Modern Lua annotations: `---@type SessionConfig`
- Functional grouping with section separators
- Error handling: `if err then vim.schedule(notify) return end`

## Common Pitfalls
1. Don't assume API names - always grep for exports
2. Don't assume field names - inspect with `vim.inspect()`
3. Always wrap `vim.fn.*` in `vim.schedule()` inside async callbacks
4. UTF-16 → UTF-8 conversion needed for column positions
5. Remember three different indexing conventions (C/Lua/Neovim)
