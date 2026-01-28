# Development Notes - Unified Diff Mode

## Critical Lessons

### 1. Always Explore APIs First
**Don't assume API names exist. Always grep for exports.**

```bash
# Check actual function exports
grep "^function M\.|^M\.[a-z_]+ =" lua/codediff/core/git.lua

# Inspect data structures
:lua print(vim.inspect(diff_result.changes[1]))

# Find usage patterns
grep "git\\.get_file_content" lua/codediff/ui/ -r
```

**Verified APIs:**
- `git.get_file_content(revision, git_root, rel_path, callback)` ✓
- `lifecycle.create_session(tabpage, mode, ...)` ✓
- `inner.original` and `inner.modified` ✓ (NOT `original_range`)

### 2. Async Context Requires vim.schedule()
Any `vim.fn.*` or `vim.api.*` call inside async callback must be wrapped:

```lua
-- WRONG
git.get_file_content(..., function(err, lines)
  local other = vim.fn.readfile(path)  -- E5560: fast event error
end)

-- CORRECT
git.get_file_content(..., function(err, lines)
  vim.schedule(function()
    local other = vim.fn.readfile(path)  -- OK
  end)
end)
```

### 3. Verify Data Structures with vim.inspect()
When highlights don't appear, inspect the actual structure:

```lua
print(vim.inspect(change.inner_changes[1]))
-- Shows: { original = {...}, modified = {...} }
-- NOT: { original_range = {...}, modified_range = {...} }
```

### 4. UTF-16 to UTF-8 Conversion
C library returns UTF-16 positions, Neovim uses UTF-8 byte offsets:

```lua
local line_text = original_lines[src_line]
local start_col = vim.str_byteindex(line_text, utf16_col - 1, true) + 1
local end_col = vim.str_byteindex(line_text, utf16_end - 1, true) + 1

-- Adjust for "-" or "+" prefix
start_col = start_col + 1
end_col = end_col + 1

-- Apply with 0-based API
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col - 1, {
  end_col = end_col - 1,
  ...
})
```

### 5. Three Indexing Conventions
- **C library:** 1-based, end-exclusive ranges
  - `{start_line=2, end_line=5}` = lines 2, 3, 4
- **Lua tables:** 1-based
  - `original_lines[2]` = second line
- **Neovim API:** 0-based
  - `nvim_buf_set_extmark(buf, ns, 1, 0, ...)` = second line

### 6. Preserve Existing Comments
Only avoid NEW verbose AI comments. Keep all pre-existing comments in the codebase.

## Debugging Workflow

### When Highlights Don't Appear
1. Verify data exists: `print(#highlights_queue, #char_highlights_queue)`
2. Inspect structure: `print(vim.inspect(change.inner_changes[1]))`
3. Check field names: `print(change.inner_changes[1].original ~= nil)`
4. Verify extmarks: `print(vim.inspect(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})))`

### When Async Operations Fail
1. Wrap all `vim.fn.*` calls in `vim.schedule()`
2. Verify callback signatures match API
3. Add error logging to callbacks
4. Test with simpler sync version first

## File Structure

```
lua/codediff/ui/unified/
├── init.lua      - Module facade
├── view.lua      - View setup, Git integration
├── render.lua    - Core rendering logic
└── keymaps.lua   - Navigation keymaps
```

## Key Implementation Details

### Rendering Pipeline
1. Parse `diff_result.changes` from C library
2. For each change:
   - Format hunk header
   - Emit context lines (before)
   - Emit deletions with `-` prefix
   - Emit insertions with `+` prefix
   - Emit context lines (after)
3. Apply highlights:
   - Line-level extmarks (priority 100, hl_eol=true)
   - Character-level extmarks (priority 200)
4. Setup navigation keymaps

### Extmark Pattern
```lua
-- Line-level
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
  end_line = line_idx + 1,
  end_col = 0,
  hl_group = "CodeDiffLineDelete",
  hl_eol = true,
  priority = 100,
})

-- Character-level
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col, {
  end_col = end_col,
  hl_group = "CodeDiffCharDelete",
  priority = 200,
})
```

## Summary

**Always:**
- Grep for actual function exports before calling
- Inspect data structures with `vim.inspect()`
- Wrap `vim.fn.*` in `vim.schedule()` inside callbacks
- Preserve existing comments
- Add temporary debug output when stuck
- Test incrementally

**Never:**
- Assume API names
- Assume data structure field names
- Call `vim.fn.*` directly in async callbacks
- Remove existing comments
- Skip verification steps
