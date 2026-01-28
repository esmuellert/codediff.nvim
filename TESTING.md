# Testing Guide - Unified Diff Mode

## Automated Tests

### Run All Tests
```bash
nvim --headless -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

### Run Specific Tests
```bash
# Unified mode rendering tests
nvim --headless -c "PlenaryBustedFile tests/render/unified_spec.lua"

# Unified mode integration tests
nvim --headless -c "PlenaryBustedFile tests/unified_integration_spec.lua"
```

## Manual Testing

### Quick Test
```bash
./test_unified_manual.sh
```

### Manual Test Cases

#### 1. Git Diff with Single Revision
```vim
" Open a file that has changes
:e lua/codediff/config.lua
:CodeDiff --unified file HEAD~1
```

**Expected:**
- Single buffer with unified diff
- Lines prefixed with `-`, `+`, or ` `
- Hunk headers: `@@ -line,count +line,count @@`
- Line-level highlights (red for deletions, green for insertions)
- Character-level highlights (darker overlays)
- `]c` jumps to next hunk
- `[c` jumps to previous hunk

#### 2. Git Diff with Two Revisions
```vim
:e README.md
:CodeDiff --unified file HEAD~5 HEAD~1
```

**Expected:**
- Diff between two specific commits
- Same rendering as single revision test

#### 3. File Comparison
```vim
:CodeDiff --unified file /tmp/a.lua /tmp/b.lua
```

**Expected:**
- Works without Git context
- Compares two arbitrary files

#### 4. Default Layout Configuration
```lua
-- In your config
require("codediff").setup({
  diff = {
    default_layout = "unified",
  }
})
```

```vim
:CodeDiff file HEAD~1
```

**Expected:**
- Unified view used by default (no `--unified` flag needed)

#### 5. Context Lines Configuration
```lua
require("codediff").setup({
  diff = {
    unified_context = 5,  -- More context
  }
})
```

**Expected:**
- 5 lines of context before/after each change

#### 6. Character-Level Highlights
```vim
" Open file with word-level changes
:e lua/codediff/ui/unified/render.lua
:CodeDiff --unified file HEAD~1
```

**Expected:**
- Line backgrounds (light red/green)
- Specific changed characters have darker overlay
- Both highlights visible simultaneously

#### 7. Multiple Hunks Navigation
```vim
:e lua/codediff/commands.lua
:CodeDiff --unified file HEAD~1
```

**Expected:**
- Multiple `@@` hunk headers visible
- `]c` cycles through all hunks
- `[c` cycles backwards
- Cursor positioned at hunk header line

## Verification Checklist

### Rendering
- [ ] Hunk headers formatted correctly
- [ ] Context lines have space prefix
- [ ] Deletion lines have `-` prefix
- [ ] Insertion lines have `+` prefix
- [ ] Line-level highlights applied
- [ ] Character-level highlights applied
- [ ] No extmark errors in `:messages`

### Navigation
- [ ] `]c` jumps to next hunk
- [ ] `[c` jumps to previous hunk
- [ ] No jump when at last/first hunk
- [ ] `q` closes the diff tab

### Git Integration
- [ ] Works with `HEAD~N` syntax
- [ ] Works with branch names
- [ ] Works with commit SHAs
- [ ] Works with two revisions
- [ ] Error message for invalid revisions

### Configuration
- [ ] `default_layout = "unified"` respected
- [ ] `unified_context` value applied
- [ ] `--unified` flag overrides default

### Edge Cases
- [ ] Empty diff shows appropriate message
- [ ] Large files don't crash
- [ ] UTF-8 characters render correctly
- [ ] Files with no newline at EOF handled

## Debugging

### Check Highlights Applied
```vim
:lua print(vim.inspect(vim.api.nvim_buf_get_extmarks(0, require("codediff.ui.highlights").ns_highlight, 0, -1, {details=true})))
```

### Check Data Structure
```vim
:lua local diff = require("codediff.core.diff")
:lua local result = diff.compute_diff({"line1", "line2"}, {"line1 modified", "line3"})
:lua print(vim.inspect(result))
```

### Enable Debug Output
Add temporary print statements in render.lua:
```lua
print(string.format("Applied %d line highlights, %d char highlights",
  #highlights_queue, #char_highlights_queue))
```

## Common Issues

### Character highlights not visible
- Check colorscheme supports `CodeDiffCharDelete`/`CodeDiffCharInsert`
- Verify extmarks applied (see debugging section)
- Ensure character-level changes exist in diff

### Navigation not working
- Verify keymaps set: `:nmap ]c`
- Check hunk headers present in buffer
- Ensure buffer is not modified

### Git errors
- Check file is in a Git repository: `:!git status`
- Verify revision exists: `:!git log --oneline -5`
- Check file exists at revision: `:!git show HEAD~1:path/to/file`
