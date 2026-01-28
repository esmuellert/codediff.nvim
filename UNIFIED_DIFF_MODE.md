# Unified Diff Mode - Feature Documentation

## Overview

Unified diff mode displays diffs in single-pane patch format (like `git diff` output), as an alternative to the default side-by-side view.

## Usage

### Basic Commands
```vim
" From within a file buffer:
:CodeDiff --unified file HEAD~1
:CodeDiff --unified file HEAD~1 HEAD
:CodeDiff --unified file main

" File comparison:
:CodeDiff --unified file /path/to/a.lua /path/to/b.lua
```

### Configuration
```lua
require("codediff").setup({
  diff = {
    default_layout = "unified",  -- Default: "split"
    unified_context = 3,         -- Lines of context (default: 3)
  }
})
```

### Navigation
- `]c` - Jump to next hunk
- `[c` - Jump to previous hunk
- `q` - Close tab

## Features

### Two-Tier Highlighting
- **Line-level**: Full background color on changed lines
  - Red background: Deleted lines (prefixed with `-`)
  - Green background: Inserted lines (prefixed with `+`)
- **Character-level**: Darker overlay on specific changed characters
  - Darker red: Deleted characters within `-` lines
  - Darker green: Inserted characters within `+` lines

### Hunk Headers
- Format: `@@ -<orig_line>,<orig_count> +<mod_line>,<mod_count> @@`
- Blue, bold highlighting
- Jump targets for `]c`/`[c` navigation

### Context Lines
- Configurable via `unified_context` (default: 3 lines)
- Prefixed with space character
- Shows unchanged lines around changes

## Implementation Details

### File Structure
```
lua/codediff/ui/unified/
├── init.lua      - Module facade
├── view.lua      - View setup, Git integration
├── render.lua    - Core rendering logic
└── keymaps.lua   - Navigation keymaps
```

### Key APIs Used
- `git.get_file_content(revision, git_root, rel_path, callback)` - Fetch file at revision
- `diff_module.compute_diff(original, modified, opts)` - Compute diff
- `lifecycle.create_session(...)` - Register session for cleanup

### Rendering Pipeline
1. Parse `diff_result.changes` from C library
2. For each change:
   - Format hunk header
   - Emit context lines (before change)
   - Emit deletions with `-` prefix
   - Emit insertions with `+` prefix
   - Emit context lines (after change)
3. Apply highlights:
   - Line-level extmarks (priority 100)
   - Character-level extmarks (priority 200)
4. Setup navigation keymaps

### Character Highlight Details
- C library returns UTF-16 positions (VSCode native)
- Convert to UTF-8 byte offsets: `vim.str_byteindex(line, utf16_pos)`
- Adjust for `-`/`+` prefix: `byte_offset + 1`
- Line mapping: Track buffer line index for each source line

## Limitations

- Read-only view (no `do`/`dp` operations)
- Not compatible with explorer mode (file tree + diff)
- Requires file context (must be in a file buffer for Git diffs)

## Testing

### Manual Test
```bash
./test_unified_manual.sh
```

### Automated Tests
```vim
" Unit tests (rendering)
:PlenaryBustedFile tests/render/unified_spec.lua

" Integration tests (commands)
:PlenaryBustedFile tests/unified_integration_spec.lua
```

## Troubleshooting

### No character-level highlights
- Check colorscheme supports `CodeDiffCharDelete`/`CodeDiffCharInsert`
- Verify highlights applied: `:lua print(vim.inspect(vim.api.nvim_buf_get_extmarks(0, require("codediff.ui.highlights").ns_highlight, 0, -1, {details=true})))`

### Error: "Use ':CodeDiff --unified file <rev1> [rev2]'"
- Unified mode requires `file` subcommand
- `:CodeDiff --unified HEAD~1 HEAD` is invalid (explorer mode)
- Use: `:CodeDiff --unified file HEAD~1` instead

### Async callback errors (readfile, etc.)
- File I/O wrapped in `vim.schedule()` to avoid fast event context
- Git operations use callbacks with proper scheduling
