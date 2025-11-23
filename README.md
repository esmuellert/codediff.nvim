# vscode-diff.nvim

> **⚠️ WORK IN PROGRESS**: This plugin is under active development and not ready for production use.

A Neovim plugin that provides VSCode-style inline diff rendering with two-tier highlighting.

## Features

- **Two-tier highlighting system**:
  - Light backgrounds for entire modified lines (green for insertions, red for deletions)
  - Deep/dark character-level highlights showing exact changes within lines
- **Side-by-side diff view** in a new tab with synchronized scrolling
- **Git integration**: Compare current buffer with any git revision (HEAD, commits, branches, tags)
- **Fast C-based diff computation** using FFI with **multi-core parallelization** (OpenMP)
- **Async git operations** - non-blocking file retrieval from git
- **Read-only buffers** to prevent accidental edits
- **Aligned line rendering** with virtual filler lines

## Installation

### Prerequisites

- Neovim >= 0.7.0 (for Lua FFI support; 0.10+ recommended for vim.system)
- Git (for git diff features)
- `curl` or `wget` (for automatic binary download)
- `nui.nvim` (for explorer UI)

**No compiler required!** The plugin automatically downloads pre-built binaries from GitHub releases.

### Using lazy.nvim

**Simple installation (all platforms):**
```lua
{
  "esmuellert/vscode-diff.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("vscode-diff.config").setup({
      -- Optional configuration (defaults shown)
      highlights = {
        line_insert = "DiffAdd",
        line_delete = "DiffDelete",
        char_brightness = 1.4,
      },
      diff = {
        disable_inlay_hints = true,
        max_computation_time_ms = 5000,
      },
      keymaps = {
        view = {
          next_hunk = "]c",
          prev_hunk = "[c",
          next_file = "]f",
          prev_file = "[f",
        },
        explorer = {
          select = "<CR>",
          hover = "K",
          refresh = "R",
        },
      },
    })
  end,
}
```

The C library will be downloaded automatically on first use. No `build` step needed!

### Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/esmuellert/vscode-diff.nvim ~/.local/share/nvim/vscode-diff.nvim
```

2. Add to your Neovim runtime path in `init.lua`:
```lua
vim.opt.rtp:append("~/.local/share/nvim/vscode-diff.nvim")
```

The C library will be downloaded automatically on first use.

### Building from Source (Optional)

If you prefer to build the C library yourself instead of using pre-built binaries:

**Linux/macOS/BSD:**
```bash
cd ~/.local/share/nvim/vscode-diff.nvim
make clean && make
```

**Windows:**
```cmd
REM Option 1: Standalone build (no CMake needed, auto-detects MSVC/MinGW/Clang)
build.cmd

REM Option 2: CMake with Visual Studio
cmake -B build && cmake --build build

REM Option 3: CMake with MinGW
cmake -B build -G "MinGW Makefiles" && cmake --build build
```

**Build requirements:**
- **Linux/macOS/BSD**: GCC/Clang and Make
- **Windows**: Visual Studio (MSVC), MinGW-w64 (GCC), or CMake

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

### Highlight Groups

The plugin defines four highlight groups matching VSCode's diff colors:

- `CodeDiffLineInsert` - Light green background for inserted lines
- `CodeDiffLineDelete` - Light red background for deleted lines
- `CodeDiffCharInsert` - Deep/dark green for inserted characters (THE "DEEPER COLOR")
- `CodeDiffCharDelete` - Deep/dark red for deleted characters (THE "DEEPER COLOR")

You can customize these in your config:

```lua
vim.api.nvim_set_hl(0, "CodeDiffCharInsert", { bg = "#2d6d2d" })
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

### Current Status: MVP Complete ✅

- [x] C-based diff computation
- [x] Two-tier highlighting (line + character level)
- [x] Side-by-side rendering
- [x] Read-only buffers
- [x] Line alignment with filler lines
- [x] Lua FFI bindings
- [x] Git integration (async operations, status explorer, revision comparison)
- [x] Integration tests (C, Lua)

### Future Enhancements

- [ ] Live diff updates on buffer changes
- [ ] Inline diff mode (single buffer)
- [ ] Syntax highlighting preservation
- [ ] Fold support for large diffs
- [ ] Performance optimization for large files
- [ ] Custom color schemes

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
