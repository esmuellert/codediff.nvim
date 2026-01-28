# Testing Unified Diff Mode

## Automated Tests

### Unit Tests
```bash
# Run unified renderer tests
nvim --headless -c "PlenaryBustedDirectory tests/render/unified_spec.lua"
```

### Integration Tests
```bash
# Run integration tests
nvim --headless -c "PlenaryBustedDirectory tests/unified_integration_spec.lua"
```

### All Tests
```bash
# Run all tests
nvim --headless -c "PlenaryBustedDirectory tests/"
```

## Manual Testing

### Quick Test Script
```bash
./test_unified_manual.sh
```

This script:
- Creates a temporary Git repository
- Commits some Lua files with changes
- Opens Neovim with unified diff mode

### Manual Test Cases

**1. Git revision comparison:**
```vim
:CodeDiff --unified HEAD~1 HEAD
```

**2. Working tree vs revision:**
```vim
:CodeDiff --unified file HEAD~1
```

**3. File comparison:**
```vim
:CodeDiff --unified file /path/to/a.lua /path/to/b.lua
```

**4. Config default:**
```vim
lua require("codediff").setup({diff = {default_layout = "unified"}})
:CodeDiff HEAD~1 HEAD
```

### Expected Behavior

**Display:**
- Hunk headers: `@@ -2,3 +2,4 @@` (blue, bold)
- Deletions: Lines prefixed with `-` (red background)
- Insertions: Lines prefixed with `+` (green background)
- Context: Lines prefixed with ` ` (space)
- Character highlights: Darker overlays on changed portions

**Navigation:**
- `]c` - Jump to next hunk
- `[c` - Jump to previous hunk
- `q` - Close tab

**Highlights:**
- Line-level backgrounds (priority 100)
- Character-level overlays (priority 200)
- Hunk header highlighting (CodeDiffUnifiedHeader)

## Validation Checklist

- [ ] Unified format displays correctly
- [ ] Hunk headers formatted properly
- [ ] Line-level highlights applied (red/green)
- [ ] Character-level highlights applied (darker overlays)
- [ ] Context lines shown with space prefix
- [ ] UTF-8 multibyte characters handled correctly
- [ ] Navigation keymaps work (`]c`, `[c`, `q`)
- [ ] `--unified` flag works
- [ ] `default_layout = "unified"` config works
- [ ] Works with Git revisions
- [ ] Works with file paths
- [ ] Multiple hunks displayed correctly
- [ ] Empty diff handled gracefully
