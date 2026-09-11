# codediff.nvim

**Keep the agent running. Review changes as they land.**

CodeDiff is a live code review workspace for Neovim with VSCode style diffs, built for human-in-the-loop AI development. Run any coding agent in the background while you inspect and navigate changes as they land.

CodeDiff stays synchronized with a changing repository, so review can continue as the code evolves. From the same workspace, you can stage or discard changes, review branches and pull requests, browse history, and resolve merge conflicts.

<div align="center">

https://github.com/user-attachments/assets/3c66a26d-5ff9-4dac-8035-a2f2b7bd2308

</div>

## Features

- **Live review:** Changes appear as they land while any coding agent works in the background.
- **VSCode style diffs:** Review side-by-side or inline changes with line- and character-level highlighting.
- **Human control:** Inspect, stage, unstage, or discard files and hunks from one review workspace.
- **Complete workflows:** Review local changes, staged changes, revisions, pull requests, and history.
- **Focused navigation:** Move between files and hunks, fold unchanged code, and track moved blocks.
- **Conflict resolution:** Resolve merge conflicts per block or across the whole file.
- **Editor-native context:** Keep Tree-sitter syntax highlighting in revision buffers.

## Installation

### Prerequisites

- Neovim 0.7 or newer; 0.10 or newer is recommended
- Git for repository workflows
- `curl` or `wget` on Unix, or PowerShell on Windows, for automatic downloads
- A Nerd Font is optional for the default Explorer folder icons

**No compiler required!** The plugin automatically downloads pre-built binaries from GitHub releases.

### Using lazy.nvim

**Minimal installation:**
```lua
{
  "esmuellert/codediff.nvim",
  cmd = "CodeDiff",
}
```

### Automatic installation

CodeDiff automatically downloads the matching diff library on first use and after plugin updates. No build step is required.

To install it explicitly or force a reinstall when troubleshooting:

```vim
" Install or update the diff library
:CodeDiff install

" Force reinstall
:CodeDiff install!
```

### Manual Installation

To install without a plugin manager, follow these steps. The example uses a Unix-style path; on Windows, choose a local directory and use that path in both the clone command and the runtime path setting.

1. **Clone the repository:**
```bash
git clone https://github.com/esmuellert/codediff.nvim ~/.local/share/nvim/codediff.nvim
```

2. **Add to your Neovim runtime path in `init.lua`:**
```lua
vim.opt.rtp:append("~/.local/share/nvim/codediff.nvim")
```

3. **Restart Neovim and use `:CodeDiff`.**

The diff library is still downloaded automatically on first use, even without a plugin manager.

#### Optional: manually install the diff library

If automatic downloads are unavailable, or you prefer to build the diff library yourself, use one of the options below.

Place the library in the plugin root directory using one of these filenames:
- `libvscode_diff.so` or `libvscode_diff_<version>.so` (Linux/BSD)
- `libvscode_diff.dylib` or `libvscode_diff_<version>.dylib` (macOS)
- `libvscode_diff.dll` or `libvscode_diff_<version>.dll` (Windows)

**Option A: Download from GitHub releases** (recommended)

1. Choose the [release](https://github.com/esmuellert/codediff.nvim/releases) matching your installed plugin version.
2. Download the binary for your operating system and Neovim's CPU architecture.
3. Place it in the plugin root directory and rename it using one of the filenames listed above.

If no pre-built binary is available for your platform, use Option B.

**Linux users**: If `libgomp.so.1` is unavailable to Neovim, also download `libgomp_linux_{arch}_{version}.so.1` from the same release for the same architecture and rename it to `libgomp.so.1` in the plugin root directory.

**Option B: Build from source**

Build requirements: a C11 compiler. CMake 3.15 or newer is optional for the developer build.

Run the following commands from the plugin root directory. For the Unix example above, first run `cd ~/.local/share/nvim/codediff.nvim`.

Using build scripts (no CMake required):
```bash
# Linux/macOS/BSD
./build.sh
```

```cmd
REM Windows
build.cmd
```

Or using CMake:
```bash
cmake -B build
cmake --build build
```

Both methods automatically place the library in the plugin root directory.

## Configuration

<details>
<summary><strong>Full configuration reference</strong></summary>

```lua
{
  "esmuellert/codediff.nvim",
  cmd = "CodeDiff",
  opts = {
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
      layout = "side-by-side",             -- Diff layout: "side-by-side" (two panes) or "inline" (single pane with virtual lines)
      filler_text = "╱",                   -- Repeated filler pattern; use "" for blank alignment rows
      disable_inlay_hints = true,         -- Disable inlay hints in diff windows for cleaner view
      max_computation_time_ms = 5000,     -- Maximum time for diff computation (VSCode default)
      ignore_trim_whitespace = false,     -- Ignore leading and trailing whitespace changes
      hide_merge_artifacts = false,       -- Hide merge tool temp files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*)
      original_position = "left",         -- Position of original (old) content: "left" or "right"
      conflict_ours_position = "right",   -- Position of ours (:2) in conflict view: "left" or "right"
      conflict_result_position = "bottom", -- "bottom" (default): result below diff panes or "center": result between diff panes (three columns)
      conflict_result_height = 30,         -- Height of result pane in bottom layout (% of total height)
      conflict_result_width_ratio = { 1, 1, 1 }, -- Width ratio for center layout panes {left, center, right} (e.g., {1, 2, 1} for wider result)
      cycle_next_hunk = true,             -- Wrap around when navigating hunks (]c/[c): false to stop at first/last
      cycle_next_file = true,             -- Wrap around when navigating files (]f/[f): false to stop at first/last
      cycle_hunks_across_files = false,   -- ]c/[c at file boundary hops to first/last hunk of next/prev file (explorer/history)
      jump_to_first_change = true,        -- Auto-scroll to first change when opening a diff: false to stay at same line
      highlight_added_deleted_files = false, -- Tint full contents of added, untracked, and deleted files
      highlight_priority = 100,           -- Priority for line-level diff highlights (increase to override LSP highlights)
      gutter_signs = false,                -- Gutter +/- signs; see Gutter signs below
      compute_moves = false,              -- Detect moved code blocks (opt-in, matches VSCode experimental.showMoves)
      compact_context_lines = 3,          -- Number of context lines around hunks in compact mode
      compact_sync_folds = true,          -- Sync fold open/close across panes (mirrors Vim diff mode behavior)
      compact = false,                    -- Default compact preference for each CodeDiff session; toggle with gc
    },

    -- Explorer panel configuration
    explorer = {
      position = "left",  -- "left", "right", "top", or "bottom"
      hidden = false,  -- Initial visibility state
      width = 40,         -- Width when position is "left" (columns)
      height = 15,        -- Height when position is "bottom" (lines)
      auto_refresh = true,  -- Native file watching with polling fallback (R still refreshes manually)
      indent_markers = true,  -- Show indent markers in tree view (│, ├, └)
      initial_focus = "explorer",  -- Initial focus: "explorer", "original", or "modified"
      icons = {
        folder_closed = "\u{e5ff}", -- Nerd Font folder icon
        folder_open = "\u{e5fe}",   -- Nerd Font open-folder icon
      },
      view_mode = "list",    -- "list" or "tree"
      flatten_dirs = true,   -- Flatten single-child directory chains in tree view
      file_filter = {
        ignore = { ".git/**", ".jj/**" },  -- Glob patterns to hide (e.g., {"*.lock", "dist/*"})
      },
      untracked = "all",  -- Untracked scan: "all", "normal" (collapse dirs), or "no" (skip; use for huge work trees like GIT_WORK_TREE=$HOME that hang, #389)
      focus_on_select = false,  -- Jump to modified pane after selecting a file (default: stay in explorer)
      auto_open_on_cursor = false, -- Rebind j/k/Down/Up in the explorer to also open the file under the cursor
      status_right_margin = 1,  -- Trailing cells between status symbol (M/A/D) and right edge; increase if Nerd Font icons clip it
      line_stats = {
        enabled = false,         -- Fetch and show Git line statistics
        count_untracked = false, -- Count untracked file lines as insertions
        max_untracked_bytes = 1024 * 1024, -- Skip larger untracked files
      },
      ellipsis = "…",          -- Text appended to truncated Explorer regions
      formatters = {  -- Optional function(ctx) -> line layout callbacks; omit to use the built-ins
        file = nil,   -- File rows
        folder = nil, -- Directory rows in tree view
        group = nil,  -- Section headers such as Changes and Staged Changes
      },
      visible_groups = {       -- Which groups to show (can be toggled at runtime)
        staged = true,
        unstaged = true,
        conflicts = true,
      },
    },

    -- History panel configuration (for :CodeDiff history)
    history = {
      position = "bottom",  -- "left", "right", "top", or "bottom" (default: bottom)
      width = 40,           -- Width when position is "left" (columns)
      height = 15,          -- Height when position is "bottom" (lines)
      initial_focus = "history",  -- Initial focus: "history", "original", or "modified"
      view_mode = "list",   -- "list" or "tree" for files under commits
      date_format = "%ar",  -- Commit date rendering: "%ar" (default, relative), "%ai" (ISO), "%ad" (git default), or any strftime string (e.g. "%Y/%m/%d %H:%M:%S")
    },

    -- Keymaps in diff view
    keymaps = {
      view = {
        quit = "q",                    -- Close diff tab
        toggle_explorer = "<leader>b",  -- Toggle explorer visibility (explorer mode only)
        focus_explorer = "<leader>e",   -- Focus explorer panel (explorer mode only)
        next_hunk = "]c",   -- Jump to next change
        prev_hunk = "[c",   -- Jump to previous change
        next_file = "]f",   -- Next file in explorer/history mode
        prev_file = "[f",   -- Previous file in explorer/history mode
        diff_get = "do",    -- Get change from other buffer (like vimdiff)
        diff_put = "dp",    -- Put change to other buffer (like vimdiff)
        open_in_prev_tab = "gf", -- Open current buffer in previous tab (or create one before)
        close_on_open_in_prev_tab = false, -- Close codediff tab after gf opens file in previous tab
        toggle_stage = "-", -- Stage/unstage current file (works in explorer and diff buffers)
        toggle_staged_view = "gS", -- Swap between staged/unstaged view of current file (#352)
        stage_hunk = "<leader>hs",   -- Stage hunk under cursor to git index
        unstage_hunk = "<leader>hu", -- Unstage hunk under cursor from git index
        discard_hunk = "<leader>hr", -- Discard hunk under cursor (working tree only)
        hunk_textobject = "ih",      -- Textobject for hunk (vih to select, yih to yank, etc.)
        show_help = "g?",   -- Show floating window with available keymaps
        align_move = "gm", -- Temporarily align moved code blocks across panes
        toggle_layout = "t", -- Toggle between side-by-side and inline layout
        toggle_compact = "gc", -- Toggle compact mode (fold unchanged regions)
      },
      explorer = {
        select = "<CR>",    -- Open diff for selected file
        hover = "K",        -- Show full path
        refresh = "R",      -- Refresh git status
        toggle_view_mode = "i",  -- Toggle between 'list' and 'tree' views
        stage_all = "S",    -- Stage all files
        unstage_all = "U",  -- Unstage all files
        restore = "X",      -- Discard changes (restore file)
        toggle_changes = "gu",  -- Toggle Changes (unstaged) group visibility
        toggle_staged = "gs",   -- Toggle Staged Changes group visibility
        -- Fold keymaps (Vim-style)
        fold_open = "zo",           -- Open fold (expand current node)
        fold_open_recursive = "zO", -- Open fold recursively (expand all descendants)
        fold_close = "zc",          -- Close fold (collapse current node)
        fold_close_recursive = "zC", -- Close fold recursively (collapse all descendants)
        fold_toggle = "za",         -- Toggle fold (expand/collapse current node)
        fold_toggle_recursive = "zA", -- Toggle fold recursively
        fold_open_all = "zR",       -- Open all folds in tree
        fold_close_all = "zM",      -- Close all folds in tree
      },
      history = {
        select = "<CR>",    -- Select commit/file or toggle expand
        toggle_view_mode = "i",  -- Toggle between 'list' and 'tree' views
        refresh = "R",      -- Refresh history (re-fetch commits)
        -- Fold keymaps (Vim-style, apply to directory nodes only)
        fold_open = "zo",           -- Open fold (expand current node)
        fold_open_recursive = "zO", -- Open fold recursively (expand all descendants)
        fold_close = "zc",          -- Close fold (collapse current node)
        fold_close_recursive = "zC", -- Close fold recursively (collapse all descendants)
        fold_toggle = "za",         -- Toggle fold (expand/collapse current node)
        fold_toggle_recursive = "zA", -- Toggle fold recursively
        fold_open_all = "zR",       -- Open all folds in tree
        fold_close_all = "zM",      -- Close all folds in tree
      },
      conflict = {
        accept_incoming = "<leader>ct",  -- Accept incoming (theirs/left) change
        accept_current = "<leader>co",   -- Accept current (ours/right) change
        accept_both = "<leader>cb",      -- Accept both changes
        discard = "<leader>cx",          -- Discard both, keep base
        -- Accept all (whole file) - uppercase versions
        accept_all_incoming = "<leader>cT",  -- Accept ALL incoming changes
        accept_all_current = "<leader>cO",   -- Accept ALL current changes
        accept_all_both = "<leader>cB",      -- Accept ALL both changes
        discard_all = "<leader>cX",          -- Discard ALL, reset to base
        next_conflict = "]x",            -- Jump to next conflict
        prev_conflict = "[x",            -- Jump to previous conflict
        diffget_incoming = "2do",        -- Get hunk from incoming (left/theirs) buffer
        diffget_current = "3do",         -- Get hunk from current (right/ours) buffer
      },
    },
  },
}
```

</details>

### Keymaps

Each keymap action accepts a single key or a list of keys:

```lua
keymaps = { view = { quit = { "q", "<Esc>" } } }
```

Set an action to `false` or `{}` to disable it. An explicitly configured mapping takes precedence over another action's default. If two explicitly configured actions use the same key, CodeDiff warns that only one can work.

### Explorer line statistics

Line statistics are disabled by default because they run additional Git queries. Set `explorer.line_stats.enabled = true` to show per-file counts and group totals in Explorer views for repository status and revision comparisons. Untracked files are counted only when `count_untracked = true`; untracked files larger than `max_untracked_bytes` are skipped.

Files display `+12 -4`, or `bin` for binary files. Group headings display totals such as `Changes (3 · +42 -8)`. Folder and group `stats` values contain `files_changed`, `insertions`, `deletions`, `binary_files`, and `unavailable_files`.

### Explorer line formatters

`explorer.formatters.file`, `folder`, and `group` replace the complete corresponding Explorer row. Each callback receives row metadata and returns a layout:

```lua
{
  left = {
    {
      segments = { { text = "name.lua", hl = "Normal" } },
      truncate_priority = 2,
    },
  },
  right = {
    {
      segments = { { text = "M", hl = "CodeDiffStatusModified" } },
    },
  },
  min_gap = 2,
}
```

A layout contains `left` and `right` lists of regions and an optional `min_gap` (default `2`). Each region contains styled `segments`. A numeric `truncate_priority` makes the region truncatable; lower values truncate first, while regions without a priority remain fixed until necessary. The `right` side is right-aligned, and truncated text uses `explorer.ellipsis`.

Each segment is `{ text = string, hl? = highlight }`. `hl` accepts a Neovim highlight group, a `#RGB`/`#RRGGBB` foreground color, or a highlight definition such as `{ fg = "#3fb950", bold = true }`. Omitted highlights use `Normal`; selected file rows retain their selection background.

File contexts contain `path`, `filename`, `directory`, `old_path`, `group`, `stats`, `status`, `status_hl`, `status_right_margin`, `indent`, `indent_hl`, `icon`, and `icon_hl`. Folder contexts contain `name`, `path`, `group`, `file_count`, `stats`, `files`, `indent`, `indent_hl`, `icon`, `icon_hl`, and `expanded`. Group contexts contain `name`, `label`, `file_count`, `stats`, `files`, and `expanded`. `stats` is `nil` when line statistics are disabled.

Folder and group `files` contain `{ path, old_path, group, status, stats }` entries for every represented file. The built-in callbacks are exported by `codediff.ui.explorer.formatters` and return fresh layouts that can be assigned directly or wrapped.

```lua
require("codediff").setup({
  explorer = {
    formatters = {
      group = function(ctx)
        return {
          left = {{
            segments = {{ text = " " .. ctx.label, hl = "CodeDiffExplorerTreeGroup" }},
            truncate_priority = 1,
          }},
          right = {{
            segments = {{ text = ctx.file_count .. " files", hl = "Number" }},
          }},
        }
      end,
    },
  },
})
```

### Gutter signs

Gutter signs are disabled by default and require Neovim 0.10 or newer. Enable them under `diff`:

```lua
gutter_signs = {
  insert_text = "＋",
  delete_text = "－",
  highlight_numbers = true,
  changed_priority = 100,
  unchanged_priority = nil,
}
```

`insert_text` and `delete_text` must each occupy one or two display cells. To place a blank sign at priority `7` on unchanged lines, set:

```lua
gutter_signs = {
  unchanged_priority = 7,
}
```

Changed signs use priority `100` by default, so they remain visible. CodeDiff does not modify `signcolumn` or `statuscolumn`. This example reserves one sign column and places signs after line numbers:

```lua
vim.opt.signcolumn = "yes"
vim.opt.statuscolumn = "%C%=%l %s"
```

With one sign column, the blank priority-`7` sign hides signs with lower priorities. Set `signcolumn` to `"yes:2"` to allow a second sign column.

## Usage

Use `:CodeDiff` to review repository changes, pull requests, files, directories, and history.

### Review Repository Changes

#### Working Tree and Revisions

Open an interactive file explorer showing changed files:

```vim
" Show repository status in the Explorer
:CodeDiff

" Compare a revision with the working tree
:CodeDiff HEAD~5

" Compare a branch with the working tree
:CodeDiff main

" Compare a commit with the working tree
:CodeDiff abc123

" Compare two revisions (e.g. main vs HEAD)
:CodeDiff main HEAD

" Override layout for this invocation
:CodeDiff --inline
:CodeDiff main --side-by-side

" Operate on another repository without leaving the current one.
" Accepts the repository root or any path inside it; -C is an alias.
" Works with repository review, pull requests, and history.
:CodeDiff --repo ~/code/other-repo
:CodeDiff --repo ~/code/other-repo main
:CodeDiff -C ~/code/other-repo history
```

#### Staged Changes

Review only changes in the Git index:

```vim
" Index vs HEAD
:CodeDiff --staged

" Index vs another revision
:CodeDiff --staged HEAD~3
```

`--cached` is an alias for `--staged`. In the default Explorer, `gS` switches between the staged and unstaged versions of a file that appears in both groups.

#### Pull Requests

Fetch and review a pull request without checking out its branch or changing the working tree:

```vim
:CodeDiff pr 512

" Fetch from another remote
:CodeDiff pr 512 --remote upstream

" Override the target branch
:CodeDiff pr 512 --base release/3.x

" Review only part of the pull request
:CodeDiff pr 512 -- lua/codediff

" Review a pull request in another local repository
:CodeDiff --repo ~/code/codediff.nvim pr 512
```

CodeDiff supports GitHub, GitLab, and Azure DevOps using the authentication already configured for the selected Git remote. No provider CLI is required.

CodeDiff stores fetched commits in private Git refs without creating a local branch. Remove cached refs when they are no longer needed:

```vim
:CodeDiff pr clean 512
:CodeDiff pr clean 512 --remote upstream
:CodeDiff pr clean --all
:CodeDiff pr clean --all --remote upstream
```

The cleanup commands also support `--repo` and `-C`.

#### Merge-base Comparisons

Review changes introduced since a branch diverged from its base:

```vim
" Merge base of main and HEAD vs working tree
:CodeDiff main...

" Merge base of main and HEAD vs HEAD
:CodeDiff main...HEAD

" Merge base of two branches vs the target branch
:CodeDiff develop...feature/new-ui
```

`<base>...` compares the merge base of `<base>` and `HEAD` with the working tree. `<base>...<target>` compares the merge base with `<target>`.

#### Scope by Path

Append `--` followed by one or more Git pathspecs relative to the repository root:

```vim
" Working-tree changes under a path
:CodeDiff -- src/api

" Changes between two revisions under a path
:CodeDiff v1.0.1 v1.0.2 -- modules/network

" Merge-base comparison under a path
:CodeDiff main... -- packages/ui
```

Multiple pathspecs and Git glob syntax are supported.

### Compare Files and Directories

#### Current File and Revisions

Compare the current file with a Git revision, or compare that file between two revisions:

```vim
" Revision vs working buffer
:CodeDiff file HEAD

" Two revisions
:CodeDiff file main HEAD

" Merge base of main and HEAD vs working buffer
:CodeDiff file main...
```

The current buffer must represent a file in a Git repository. With one revision, the working buffer remains editable and the revision content is read-only. With two revisions, both sides are read-only.

#### Two Files

Compare two files without Git:

```vim
:CodeDiff file file_a.txt file_b.txt
```

#### Two Directories

Compare two directories without Git:

```vim
" Explicit subcommand
:CodeDiff dir /path/to/dir1 /path/to/dir2

" Directories are also detected automatically
:CodeDiff ~/project-v1 ~/project-v2
```

The Explorer lists files as Added (A), Deleted (D), or Modified (M). Select a file to review its diff.

### Review History

By default, history shows the latest 100 non-merge commits. Expand a commit to see its changed files, then select a file to compare the commit with its parent.

```vim
" Open recent history
:CodeDiff history

" Review a commit range
:CodeDiff history HEAD~10..HEAD
:CodeDiff history origin/main..HEAD

" Limit history to the current file or another file
:CodeDiff history %
:CodeDiff history HEAD~10..HEAD path/to/file.lua

" Show the selected range from oldest to newest
:CodeDiff history origin/main..HEAD --reverse

" Compare each selected commit with the working tree
:CodeDiff history origin/main..HEAD --base WORKING

" Show commits that changed the selected lines
:'<,'>CodeDiff history
:'<,'>CodeDiff history HEAD~10..HEAD
```

`--reverse` (or `-r`) shows commits from oldest to newest. `--base <revision>` (or `-b`) compares each commit with a fixed Git revision; use `WORKING` for the current working tree. When invoked with a visual range, history is limited to commits that changed the selected lines in the current file.

### Git Tool Integration

`--exit-on-close` exits Neovim when the CodeDiff session closes, which is useful for processes started by Git.

#### Merge Tool

Configure CodeDiff as a Git merge tool, then run `git mergetool` to resolve conflicts:

```bash
git config --global merge.tool codediff
git config --global mergetool.codediff.cmd 'nvim "$MERGED" -c "CodeDiff --exit-on-close merge \"$MERGED\""'
git mergetool
```

#### Diff Tool

Configure CodeDiff as a Git diff tool:

```bash
git config --global diff.tool codediff
git config --global difftool.codediff.cmd 'nvim "$LOCAL" "$REMOTE" +"CodeDiff --exit-on-close file $LOCAL $REMOTE"'
```

Then review uncommitted changes or compare revisions:

```bash
git difftool
git difftool main feature-branch
```

### Extend CodeDiff

#### Lua API

`require("codediff")` exposes the supported Lua API:

| Function | Description |
|----------|-------------|
| `setup(opts)` | Apply CodeDiff configuration |
| `next_hunk()` | Move to the next hunk |
| `prev_hunk()` | Move to the previous hunk |
| `next_file()` | Move to the next file, or the next commit in single-file history |
| `prev_file()` | Move to the previous file, or the previous commit in single-file history |

The navigation functions return `true` when navigation succeeds and `false` otherwise. Modules under `codediff.core` and `codediff.ui` are internal and are not part of the supported API.

#### User Autocmd Events

CodeDiff emits `User` autocmd events for view lifecycle changes:

| Event | When | Data |
|-------|------|------|
| `CodeDiffOpen` | When a CodeDiff view opens | `tabpage`, `mode` |
| `CodeDiffClose` | Before cleanup starts | `tabpage`, `mode` |
| `CodeDiffFileSelect` | When a file is selected in the Explorer | `tabpage`, `path`, `status` |

`mode` is one of `"explorer"`, `"standalone"`, or `"history"`.

<details>
<summary>Example: Disable cursorline in the CodeDiff tab</summary>

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffOpen",
  callback = function(event)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(event.data.tabpage)) do
      vim.wo[win].cursorline = false
    end
  end,
})
```

</details>

## Development

Development requires CMake 3.15 or newer, a C11 compiler, Neovim, and Git. `CMakeLists.txt` is the source of truth for native builds.

### Build and Test

Build the native library and run its tests:

```bash
cmake -S . -B build
cmake --build build --config Release
ctest --test-dir build --output-on-failure -C Release
```

Run the Lua integration suite:

```bash
./tests/run_tests.sh
```

On Windows, use `tests\run_tests.cmd`.

Check Lua formatting:

```bash
stylua --check lua
```

Run one Lua spec:

```bash
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_and_exit('tests/path/to/spec.lua')"
```

## Contributing

Contributions are welcome. Please include tests for behavioral changes and update user documentation when behavior changes.

## License

MIT
