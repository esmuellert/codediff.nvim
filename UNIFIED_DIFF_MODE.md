# Unified Diff Mode

Single-pane patch-style diff view, similar to `git diff` output.

## Usage

```vim
" From a file buffer:
:CodeDiff --unified file HEAD~1
:CodeDiff --unified file main
:CodeDiff --unified file HEAD~1 HEAD

" Compare two files:
:CodeDiff --unified file /path/to/a.lua /path/to/b.lua
```

## Configuration

```lua
require("codediff").setup({
  diff = {
    default_layout = "unified",  -- Use unified view by default
    unified_context = 3,         -- Lines of context around changes
  }
})
```

## Navigation

| Key | Action |
|-----|--------|
| `]c` | Next hunk |
| `[c` | Previous hunk |
| `q` | Close diff tab |

## Features

### Two-Tier Highlighting
- **Line-level**: Full background color on changed lines
  - Red: Deleted lines (prefix: `-`)
  - Green: Inserted lines (prefix: `+`)
- **Character-level**: Darker overlay on specific changed characters
  - Darker red: Deleted characters within `-` lines
  - Darker green: Inserted characters within `+` lines

### Hunk Headers
Format: `@@ -orig_line,count +mod_line,count @@`
- Blue, bold highlighting
- Jump targets for `]c`/`[c` navigation

### Context Lines
- Configurable via `unified_context` (default: 3)
- Prefixed with space character
- Shows unchanged lines around changes

## Limitations

- Read-only view (no `do`/`dp` operations like vimdiff)
- Not compatible with explorer mode (file tree)
- Requires file context for Git diffs
