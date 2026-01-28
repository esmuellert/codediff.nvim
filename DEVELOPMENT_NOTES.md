# Development Notes - Unified Diff Mode Implementation

## Critical Lessons Learned

### 1. API Discovery - Don't Assume, Explore
**Failures:**
- Used `git.get_file_at_revision()` (doesn't exist) instead of exploring actual API
- Used `lifecycle.register_session()` (doesn't exist) instead of checking exports
- Assumed field names `inner.original_range` instead of verifying structure

**Correct Approach:**
```bash
# Always check actual exports
grep "^function M\.|^M\.[a-z_]+ =" lua/codediff/core/git.lua

# Inspect actual data structures
:lua print(vim.inspect(diff_result.changes[1].inner_changes[1]))

# Read existing usage patterns
grep "git\.get_file_content" lua/codediff/ui/ -r
```

**Key APIs (Verified):**
- `git.get_file_content(revision, git_root, rel_path, callback)` - NOT `get_file_at_revision`
- `lifecycle.create_session(tabpage, mode, ...)` - NOT `register_session`
- `inner.original` and `inner.modified` - NOT `original_range`/`modified_range`

### 2. Async Context - vim.schedule() Required
**Failure:**
- Called `vim.fn.readfile()` inside Git async callback → fast event error

**Fix:**
```lua
-- WRONG - fast event context
git.get_file_content(..., function(err, lines)
  local other_lines = vim.fn.readfile(path)  -- ERROR
end)

-- CORRECT - schedule file I/O
git.get_file_content(..., function(err, lines)
  vim.schedule(function()
    local other_lines = vim.fn.readfile(path)  -- OK
  end)
end)
```

**Rule:** Any `vim.fn.*` or `vim.api.*` call inside async callback must be wrapped in `vim.schedule()`.

### 3. Comment Preservation - Only Avoid NEW Comments
**Mistake:**
- Removed pre-existing explanatory comments
- Goal was to avoid NEW AI-generated comments, not remove existing ones

**Reverted Examples:**
```lua
-- REMOVED (wrong):
diff = {
  disable_inlay_hints = true,
  max_computation_time_ms = 5000,
}

-- RESTORED (correct):
diff = {
  disable_inlay_hints = true, -- Disable inlay hints in diff windows for cleaner view
  max_computation_time_ms = 5000, -- Maximum time for diff computation (5 seconds, VSCode default)
}
```

**Rule:** Preserve ALL existing comments. Only avoid adding NEW verbose AI comments.

### 4. Data Structure Verification
**Failure:** Assumed `inner_changes` structure without verification

**Debug Process:**
```lua
-- Add temporary debug output
vim.schedule(function()
  print("inner:", vim.inspect(inner))
end)

-- Output showed:
-- inner: { original = {...}, modified = {...} }
-- NOT: { original_range = {...}, modified_range = {...} }
```

**Rule:** When applying highlights/processing data:
1. Add debug output to see actual structure
2. Verify field names match reality
3. Remove debug output after fixing

### 5. Command Routing Logic
**Failure:** `:CodeDiff --unified HEAD~1 HEAD` routed to explorer mode

**Root Cause:** Command structure has different modes:
- `:CodeDiff <rev>` → Explorer mode (file tree)
- `:CodeDiff file <rev>` → File diff mode

**Fix:** Added error message directing to correct syntax, since explorer mode (2-pane file tree) is incompatible with unified view (1-pane).

### 6. UTF-16 to UTF-8 Conversion
**Issue:** C library returns UTF-16 column positions, Neovim uses UTF-8 byte offsets

**Solution:**
```lua
local line_text = original_lines[src_line]
local start_col = utf16_col_to_byte_col(line_text, orig_range.start_col)
local end_col = utf16_col_to_byte_col(line_text, orig_range.end_col)

-- Adjust for "-" or "+" prefix
start_col = start_col + 1
end_col = end_col + 1

-- Apply extmark with 0-based API
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col - 1, {
  end_col = end_col - 1,
  ...
})
```

### 7. Indexing Conventions
**Three different conventions in play:**
- **C library:** 1-based, end-exclusive ranges
  - `{start_line=2, end_line=5}` = lines 2, 3, 4
- **Lua tables:** 1-based indexing
  - `original_lines[2]` = second line
- **Neovim API:** 0-based indexing
  - `vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, ...)` = second line

**Must convert carefully:**
```lua
-- C gives: start_line = 2 (1-based)
-- Lua access: original_lines[2] (1-based, matches)
-- Extmark: line_idx = 2 - 1 = 1 (0-based for API)
```

## Debugging Workflow

### When Highlights Don't Appear
1. **Verify data exists:**
   ```lua
   print(string.format("Applied %d line highlights, %d char highlights",
     #highlights_queue, #char_highlights_queue))
   ```
2. **Check structure:**
   ```lua
   print("inner:", vim.inspect(change.inner_changes[1]))
   ```
3. **Verify field names:**
   ```lua
   print("Has original_range?", change.inner_changes[1].original_range ~= nil)
   print("Has original?", change.inner_changes[1].original ~= nil)
   ```
4. **Check extmarks applied:**
   ```lua
   print(vim.inspect(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})))
   ```

### When Async Operations Fail
1. Check for `vim.schedule()` wrapping
2. Verify callback signatures match API
3. Add error logging to callbacks
4. Test with simpler sync version first

## Code Style Observations

### Existing Patterns
- No verbose comments on simple operations
- Functional grouping with `-- ============` separators
- Type annotations: `---@type SessionConfig`
- Error handling in callbacks: `if err then vim.schedule(notify) return end`

### Extmark Pattern
```lua
-- Line-level: priority 100, hl_eol = true
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
  end_line = line_idx + 1,
  end_col = 0,
  hl_group = "CodeDiffLineDelete",
  hl_eol = true,
  priority = 100,
})

-- Character-level: priority 200, specific range
vim.api.nvim_buf_set_extmark(buf, ns, line_idx, start_col, {
  end_col = end_col,
  hl_group = "CodeDiffCharDelete",
  priority = 200,
})
```

## Summary

**Always:**
- Grep for actual function exports
- Inspect actual data structures with `vim.inspect()`
- Read existing usage patterns in codebase
- Wrap `vim.fn.*` in `vim.schedule()` inside callbacks
- Preserve existing comments
- Add temporary debug output when stuck
- Test incrementally

**Never:**
- Assume API names
- Assume data structure field names
- Call vim.fn.* directly in async callbacks
- Remove existing comments
- Skip verification steps
