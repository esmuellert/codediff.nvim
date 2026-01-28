# codediff.nvim - Project Context

## What This Plugin Does

Hybrid Lua + C plugin that ports VSCode's diff algorithm to Neovim. Provides two-tier highlighting (line + character level) for side-by-side diffs, Git integration, merge conflict resolution, and file explorer.

## Recent Work: Unified Diff Mode

**Implemented:** Single-pane patch-style diff view (alternative to side-by-side)

**Usage:**
```vim
:CodeDiff --unified file HEAD~1
:CodeDiff --unified file main HEAD
```

**Config:**
```lua
require("codediff").setup({
  diff = {
    default_layout = "unified",
    unified_context = 3,
  }
})
```

## Architecture Essentials

**Data Flow:**
```
Command → Git (async) → Diff Computation (C FFI) → Rendering → Display
```

**Key Files:**
- `lua/codediff/commands.lua` - Command routing, flag parsing
- `lua/codediff/core/git.lua` - Async Git operations
- `lua/codediff/core/diff.lua` - FFI wrapper for C library
- `lua/codediff/ui/core.lua` - Side-by-side renderer
- `lua/codediff/ui/unified/` - Unified mode implementation

**Critical APIs:**
- `git.get_file_content(revision, git_root, rel_path, callback)` - Fetch file
- `diff_module.compute_diff(original, modified, opts)` - Compute diff
- `lifecycle.create_session(tabpage, mode, ...)` - Register session

**Diff Output Structure:**
```lua
{
  changes = {
    {
      original = { start_line = 2, end_line = 3 },  -- 1-based, end_exclusive
      modified = { start_line = 2, end_line = 4 },
      inner_changes = {  -- Character-level
        {
          original = { start_line=2, start_col=10, end_line=2, end_col=15 },
          modified = { start_line=2, start_col=10, end_line=2, end_col=18 }
        }
      }
    }
  }
}
```

## Important Technical Details

### Indexing Conventions
- C library: 1-based, end-exclusive
- Lua tables: 1-based
- Neovim API: 0-based

### UTF-16 to UTF-8
C returns UTF-16 positions, convert: `vim.str_byteindex(line, utf16_pos)`

### Async Context
Wrap `vim.fn.*` in `vim.schedule()` inside Git callbacks (fast event context)

### Field Names Verified
- `inner.original` and `inner.modified` (NOT `original_range`/`modified_range`)
- `change.inner_changes` (array of inner change objects)

## Testing

**Unit:** `tests/render/unified_spec.lua`
**Integration:** `tests/unified_integration_spec.lua`
**Manual:** `./test_unified_manual.sh`

## Documentation Files

- `UNIFIED_DIFF_MODE.md` - Feature documentation
- `DEVELOPMENT_NOTES.md` - Lessons learned, debugging workflow
- `TESTING.md` - Test procedures

## Next Steps (Future Work)

Unified merge conflict resolver (single-pane 3-way merge) will reuse:
- Single-buffer rendering patterns from unified diff
- Navigation keymaps (`]c`/`[c`)
- Extmark highlighting system
- Existing conflict detection logic from `lua/codediff/ui/conflict/`
