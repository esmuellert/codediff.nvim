# vscode-diff.nvim

[![Pre-release](https://img.shields.io/github/v/release/esmuellert/vscode-diff.nvim?include_prereleases&sort=semver&label=🚀%20pre-release&color=orange)](https://github.com/esmuellert/vscode-diff.nvim/issues/97) [![Downloads](https://img.shields.io/github/downloads/esmuellert/vscode-diff.nvim/total?label=⬇%20downloads&color=blue)](https://github.com/esmuellert/vscode-diff.nvim/releases)

> **🧪 v2.0.0 Pre-release Available!** The `next` branch includes new features like **Git Merge Tool support**. [Help us test it!](https://github.com/esmuellert/vscode-diff.nvim/issues/97)

A Neovim plugin that provides VSCode-style side-by-side diff rendering with two-tier highlighting.

<div align="center">

![VSCode-style diff view showing side-by-side comparison with two-tier highlighting](https://github.com/user-attachments/assets/473ae319-40ac-40e4-958b-a0f2525d1f94)

</div>

<div align="center">

https://github.com/user-attachments/assets/64c41f01-dffe-4318-bce4-16eec8de356e

**Demo: Quick walkthrough of diff features**

</div>

## Features

- **Two-tier highlighting system**:
  - Light backgrounds for entire modified lines (green for insertions, red for deletions)
  - Deep/dark character-level highlights showing exact changes within lines
- **Side-by-side diff view** in a new tab with synchronized scrolling
- **Git integration**: Compare between any git revision (HEAD, commits, branches, tags)
- **Same implementation as VSCode's diff engine**, providing identical visual highlighting for most scenarios
- **Fast C-based diff computation** using FFI with **multi-core parallelization** (OpenMP)
- **Async git operations** - non-blocking file retrieval from git

## Installation

### Prerequisites

- Neovim >= 0.7.0 (for Lua FFI support; 0.10+ recommended for vim.system)
- Git (for git diff features)
- `curl` or `wget` (for automatic binary download)
- `nui.nvim` (for explorer UI)

**No compiler required!** The plugin automatically downloads pre-built binaries from GitHub releases.

### Using lazy.nvim

**Minimal installation:**
```lua
{
  "esmuellert/vscode-diff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "CodeDiff",
}
```

> **Note:** The plugin automatically adapts to your colorscheme's background (dark/light). It uses `DiffAdd` and `DiffDelete` for line-level diffs, and auto-adjusts brightness for character-level highlights (1.4x brighter for dark themes, 0.92x darker for light themes). See [Highlight Groups](#highlight-groups) for customization.

**With custom configuration:**
```lua
{
  "esmuellert/vscode-diff.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "CodeDiff",
  config = function()
    require("vscode-diff").setup({
      -- Highlight configuration
      highlights = {
        -- Line-level: accepts highlight group names or hex colors (e.g., "#2ea043")
        line_insert = "DiffAdd",      -- Line-level insertions
        line_delete = "DiffDelete",   -- Line-level deletions

        -- Character-level: accepts highlight group names or hex colors
        -- If specified, these override char_brightness calculation
        char_insert = nil,            -- Character-level insertions (nil = auto-derive)
        char_delete = nil,            -- Character-level deletions (nil = auto-derive)

        -- Brightness multiplier (only used when char_insert/char_delete are nil)
        -- nil = auto-detect based on background (1.4 for dark, 0.92 for light)
        char_brightness = nil,        -- Auto-adjust based on your colorscheme

        -- Conflict sign highlights (for merge conflict views)
        -- Accepts highlight group names or hex colors (e.g., "#f0883e")
        -- nil = use default fallback chain
        conflict_sign = nil,          -- Unresolved: DiagnosticSignWarn -> #f0883e
        conflict_sign_resolved = nil, -- Resolved: Comment -> #6e7681
        conflict_sign_accepted = nil, -- Accepted: GitSignsAdd -> DiagnosticSignOk -> #3fb950
        conflict_sign_rejected = nil, -- Rejected: GitSignsDelete -> DiagnosticSignError -> #f85149
      },

      -- Diff view behavior
      diff = {
        disable_inlay_hints = true,         -- Disable inlay hints in diff windows for cleaner view
        max_computation_time_ms = 5000,     -- Maximum time for diff computation (VSCode default)
        hide_merge_artifacts = false,       -- Hide merge tool temp files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*)
      },

      -- Explorer panel configuration
      explorer = {
        position = "left",  -- "left" or "bottom"
        width = 40,         -- Width when position is "left" (columns)
        height = 15,        -- Height when position is "bottom" (lines)
        indent_markers = true,  -- Show indent markers in tree view (│, ├, └)
        icons = {
          folder_closed = "",  -- Nerd Font folder icon (customize as needed)
          folder_open = "",    -- Nerd Font folder-open icon
        },
        view_mode = "list",    -- "list" or "tree"
        file_filter = {
          ignore = {},  -- Glob patterns to hide (e.g., {"*.lock", "dist/*"})
        },
      },

      -- Keymaps in diff view
      keymaps = {
        view = {
          quit = "q",                    -- Close diff tab
          toggle_explorer = "<leader>b",  -- Toggle explorer visibility (explorer mode only)
          next_hunk = "]c",   -- Jump to next change
          prev_hunk = "[c",   -- Jump to previous change
          next_file = "]f",   -- Next file in explorer mode
          prev_file = "[f",   -- Previous file in explorer mode
          diff_get = "do",    -- Get change from other buffer (like vimdiff)
          diff_put = "dp",    -- Put change to other buffer (like vimdiff)
        },
        explorer = {
          select = "<CR>",    -- Open diff for selected file
          hover = "K",        -- Show file diff preview
          refresh = "R",      -- Refresh git status
          toggle_view_mode = "i",  -- Toggle between 'list' and 'tree' views
        },
        conflict = {
          accept_incoming = "<leader>ct",  -- Accept incoming (theirs/left) change
          accept_current = "<leader>co",   -- Accept current (ours/right) change
          accept_both = "<leader>cb",      -- Accept both changes (incoming first)
          discard = "<leader>cx",          -- Discard both, keep base
          next_conflict = "]x",            -- Jump to next conflict
          prev_conflict = "[x",            -- Jump to previous conflict
          diffget_incoming = "2do",        -- Get hunk from incoming (left/theirs) buffer
          diffget_current = "3do",         -- Get hunk from current (right/ours) buffer
        },
      },
    })
  end,
}
```

The C library will be downloaded automatically on first use. No `build` step needed!

### Managing Library Installation

The plugin automatically manages the C library installation:

**Automatic Updates:**
- The library is automatically downloaded on first use
- When you update the plugin to a new version, the library is automatically updated to match
- No manual intervention required!

**Manual Installation Commands:**
```vim
" Install/update the library manually
:CodeDiff install

" Force reinstall (useful for troubleshooting)
:CodeDiff install!
```

**Version Management:**
The installer reads the `VERSION` file to download the matching library version from GitHub releases. This ensures compatibility between the Lua code and C library.

### Manual Installation

If you prefer to install manually without a plugin manager:

1. **Clone the repository:**
```bash
git clone https://github.com/esmuellert/vscode-diff.nvim ~/.local/share/nvim/vscode-diff.nvim
```

2. **Add to your Neovim runtime path in `init.lua`:**
```lua
vim.opt.rtp:append("~/.local/share/nvim/vscode-diff.nvim")
```

3. **Install the C library:**

The plugin requires a C library binary in the plugin root directory. The plugin auto-detects these filenames:
- `libvscode_diff.so` or `libvscode_diff_<version>.so` (Linux/BSD)
- `libvscode_diff.dylib` or `libvscode_diff_<version>.dylib` (macOS)
- `libvscode_diff.dll` or `libvscode_diff_<version>.dll` (Windows)

**Option A: Download from GitHub releases** (recommended)

Download the appropriate binary from the [GitHub releases page](https://github.com/esmuellert/vscode-diff.nvim/releases) and place it in the plugin root directory. Rename it to match the expected format: `libvscode_diff.so`/`.dylib`/`.dll` or `libvscode_diff_<version>.so`/`.dylib`/`.dll`. **Linux users**: If your system lacks OpenMP, also download `libgomp_linux_{arch}_{version}.so.1` and rename it to `libgomp.so.1` in the same directory.

**Option B: Build from source**

Build requirements: C compiler (GCC/Clang/MSVC/MinGW) or CMake 3.15+

Using build scripts (no CMake required):
```bash
# Linux/macOS/BSD
./build.sh

# Windows
build.cmd
```

Or using CMake:
```bash
cmake -B build
cmake --build build
```

Both methods automatically place the library in the plugin root directory.

## Usage

The `:CodeDiff` command supports multiple modes:

### File Explorer Mode

Open an interactive file explorer showing changed files:

```vim
" Show git status in explorer (default)
:CodeDiff

" Show changes for specific revision in explorer
:CodeDiff HEAD~5

" Compare against a branch
:CodeDiff main

" Compare against a specific commit
:CodeDiff abc123

" Compare two revisions (e.g. HEAD vs main)
:CodeDiff main HEAD
```

### Git Diff Mode

Compare the current buffer with a git revision:

```vim
" Compare with last commit
:CodeDiff file HEAD

" Compare with previous commit
:CodeDiff file HEAD~1

" Compare with specific commit
:CodeDiff file abc123

" Compare with branch
:CodeDiff file main

" Compare with tag
:CodeDiff file v1.0.0

" Compare two revisions for current file
:CodeDiff file main HEAD
```

**Requirements:**
- Current buffer must be saved to a file
- File must be in a git repository
- Git revision must exist

**Behavior:**
- Left buffer: Git version (at specified revision) - readonly
- Right buffer: Current buffer content - readonly
- Opens in a new tab automatically
- Async operation - won't block Neovim

### File Comparison Mode

Compare two arbitrary files side-by-side:

```vim
:CodeDiff file file_a.txt file_b.txt
```

### Lua API

```lua
-- Primary user API - setup configuration
require("vscode-diff").setup({
  highlights = {
    line_insert = "DiffAdd",
    line_delete = "DiffDelete",
    char_brightness = 1.4,
  },
})

-- Advanced usage - direct access to internal modules
local diff = require("vscode-diff.diff")
local render = require("vscode-diff.render")
local git = require("vscode-diff.git")

-- Example 1: Compute diff between two sets of lines
local lines_a = {"line 1", "line 2"}
local lines_b = {"line 1", "modified line 2"}
local lines_diff = diff.compute_diff(lines_a, lines_b)

-- Example 2: Get file content from git (async)
git.get_file_content("HEAD~1", "/path/to/repo", "relative/path.lua", function(err, lines)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  -- Use lines...
end)

-- Example 3: Get git root for a file (async)
git.get_git_root("/path/to/file.lua", function(err, git_root)
  if not err then
    -- File is in a git repository
  end
end)
```

## Architecture

### Components

- **C Module** (`libvscode-diff/`): Fast diff computation and render plan generation
  - Myers diff algorithm
  - Character-level refinement for highlighting
  - Matches VSCode's `rangeMapping.ts` data structures

- **Lua FFI Layer** (`lua/vscode-diff/diff.lua`): Bridge between C and Lua
  - FFI declarations matching C structs
  - Type conversions between C and Lua

- **Render Module** (`lua/vscode-diff/render/`): Neovim buffer rendering
  - VSCode-style highlight groups
  - Virtual line insertion for alignment
  - Side-by-side window management
  - Git status explorer

### Syntax Highlighting

The plugin handles syntax highlighting differently based on buffer type:

**Working files (editable):**
- Behaves like normal buffers with standard highlighting
- Inlay hints disabled by default (incompatible with diff highlights)
- All LSP features available

**Git history files (read-only):**
- Virtual buffers stored in memory, discarded when tab closes
- TreeSitter highlighting applied automatically (if installed)
- LSP not attached (most features meaningless for historical files)
- Semantic token highlighting fetched via LSP request when available

### Highlight Groups

The plugin defines highlight groups matching VSCode's diff colors:

- `CodeDiffLineInsert` - Light green background for inserted lines
- `CodeDiffLineDelete` - Light red background for deleted lines
- `CodeDiffCharInsert` - Deep/dark green for inserted characters
- `CodeDiffCharDelete` - Deep/dark red for deleted characters
- `CodeDiffFiller` - Gray foreground for filler line slashes (`╱╱╱`)

<details open>
<summary><b>📸 Visual Examples</b> (click to collapse)</summary>

<br>

**Dawnfox Light** - Default configuration with auto-detected brightness (`char_brightness = 0.92` for light themes):

![Dawnfox Light theme with default auto color selection](https://github.com/user-attachments/assets/760fa8be-dba7-4eb5-b71b-c53fb3aa6edf)

**Catppuccin Mocha** - Default configuration with auto-detected brightness (`char_brightness = 1.4` for dark themes):

![Catppuccin Mocha theme with default auto color selection](https://github.com/user-attachments/assets/0187ff6c-9a2b-45dc-b9be-c15fd2a796d9)

**Kanagawa Lotus** - Default configuration with auto-detected brightness (`char_brightness = 0.92` for light themes):

![Kanagawa Lotus theme with default auto color selection](https://github.com/user-attachments/assets/9e4a0e1c-0ebf-47c8-a8b5-f8a0966c5592)

</details>

**Default behavior:**
- Uses your colorscheme's `DiffAdd` and `DiffDelete` for line-level highlights
- Character-level highlights are auto-adjusted based on `vim.o.background`:
  - **Dark themes** (`background = "dark"`): Brightness multiplied by `1.4` (40% brighter)
  - **Light themes** (`background = "light"`): Brightness multiplied by `0.92` (8% darker)
- This auto-detection works out-of-box for most colorschemes
- You can override with explicit `char_brightness` value if needed

**Customization examples:**

```lua
-- Use hex colors directly
highlights = {
  line_insert = "#1d3042",
  line_delete = "#351d2b",
  char_brightness = 1.5,  -- Override auto-detection with explicit value
}

-- Override character colors explicitly
highlights = {
  line_insert = "DiffAdd",
  line_delete = "DiffDelete",
  char_insert = "#3fb950",
  char_delete = "#ff7b72",
}

-- Mix highlight groups and hex colors
highlights = {
  line_insert = "String",
  char_delete = "#ff0000",
}
```

## Development

### Building

```bash
make clean && make
```

### Testing

Run all tests:
```bash
make test              # Run all tests (C + Lua integration)
```

Run specific test suites:
```bash
make test-c            # C unit tests only
make test-lua          # Lua integration tests only
```

For more details on the test structure, see [`tests/README.md`](tests/README.md).

### Project Structure

```
vscode-diff.nvim/
├── libvscode-diff/       # C diff engine
│   ├── src/              # C implementation
│   ├── include/          # C headers
│   └── tests/            # C unit tests
├── lua/vscode-diff/      # Lua modules
│   ├── init.lua          # Main API
│   ├── config.lua        # Configuration
│   ├── diff.lua          # FFI interface
│   ├── git.lua           # Git operations
│   ├── commands.lua      # Command handlers
│   ├── installer.lua     # Binary installer
│   └── render/           # Rendering modules
│       ├── core.lua      # Diff rendering
│       ├── view.lua      # View management
│       ├── explorer.lua  # Git status explorer
│       └── highlights.lua # Highlight setup
├── plugin/               # Plugin entry point
│   └── vscode-diff.lua   # Auto-loaded on startup
├── tests/                # Test suite (plenary.nvim)
│   └── README.md         # Test documentation
├── docs/                 # Production docs
├── dev-docs/             # Development docs
├── Makefile              # Build automation
└── README.md             # This file
```

## Roadmap

### Current Status: Complete ✅

- [x] C-based diff computation with VSCode-identical algorithm
- [x] Two-tier highlighting (line + character level)
- [x] Side-by-side view with synchronized scrolling
- [x] Git integration (async operations, status explorer, revision comparison)
- [x] Auto-refresh on buffer changes (live diff updates)
- [x] Syntax highlighting preservation (LSP semantic tokens + TreeSitter)
- [x] Read-only buffers with virtual filler lines for alignment
- [x] Flexible highlight configuration (colorscheme-aware)
- [x] Integration tests (C + Lua with plenary.nvim)

### Future Enhancements

- [ ] Inline diff mode (single buffer view)
- [ ] Fold support for large diffs

## VSCode Reference

This plugin follows VSCode's diff rendering architecture:

- **Data structures**: Based on `src/vs/editor/common/diff/rangeMapping.ts`
- **Decorations**: Based on `src/vs/editor/browser/widget/diffEditor/registrations.contribution.ts`
- **Styling**: Based on `src/vs/editor/browser/widget/diffEditor/style.css`

## License

MIT

## Contributing

Contributions are welcome! Please ensure:
1. C tests pass (`make test`)
2. Lua tests pass
3. Code follows existing style
4. Updates to README if adding features
