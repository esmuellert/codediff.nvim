-- Configuration module
local M = {}

M.defaults = {
  -- Highlight configuration
  highlights = {
    -- Line-level highlights: accepts highlight group names (e.g., "DiffAdd") or color values (e.g., "#2ea043")
    line_insert = "DiffAdd", -- Line-level insertions (base color)
    line_delete = "DiffDelete", -- Line-level deletions (base color)

    -- Character-level highlights: accepts highlight group names or color values
    -- If specified, these override char_brightness calculation
    char_insert = nil, -- Character-level insertions (if nil, derived from line_insert with char_brightness)
    char_delete = nil, -- Character-level deletions (if nil, derived from line_delete with char_brightness)

    -- Brightness multiplier for character-level highlights (only used if char_insert/char_delete are nil)
    -- nil = auto-detect based on background (1.4 for dark, 0.92 for light)
    -- Set explicit value to override: char_brightness = 1.2
    char_brightness = nil,

    -- Conflict sign highlights (for merge conflict views)
    -- Accepts highlight group names (e.g., "DiagnosticWarn") or color values (e.g., "#f0883e")
    -- nil = use default fallback chain (GitSigns* -> DiagnosticSign* -> hardcoded colors)
    conflict_sign = nil, -- Unresolved conflict sign (default: DiagnosticSignWarn -> #f0883e)
    conflict_sign_resolved = nil, -- Resolved conflict sign (default: Comment -> #6e7681)
    conflict_sign_accepted = nil, -- Accepted side sign (default: GitSignsAdd -> DiagnosticSignOk -> #3fb950)
    conflict_sign_rejected = nil, -- Rejected side sign (default: GitSignsDelete -> DiagnosticSignError -> #f85149)
  },

  -- Diff view behavior
  diff = {
    layout = "side-by-side", -- Diff layout: "side-by-side" or "inline"
    filler_text = "╱",
    disable_inlay_hints = true, -- Disable inlay hints in diff windows for cleaner view
    max_computation_time_ms = 5000, -- Maximum time for diff computation (5 seconds, VSCode default)
    ignore_trim_whitespace = false, -- Ignore leading/trailing whitespace changes (like diffopt+=iwhite)
    hide_merge_artifacts = false, -- Hide merge tool temp files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*)
    original_position = "left", -- Position of original (old) content: "left" or "right"
    conflict_ours_position = "right", -- Position of ours (:2) in conflict view: "left" or "right" (independent of original_position)
    conflict_result_position = "bottom", -- Position of result buffer in conflict view: "bottom" or "center"
    conflict_result_height = 30, -- Height of result buffer in bottom layout (percentage of total height)
    conflict_result_width_ratio = { 1, 1, 1 }, -- Width ratio for center layout panes {left, center, right} (e.g., {1, 2, 1} for wider result)
    cycle_next_hunk = true, -- Wrap around when navigating hunks (]c/[c): true = cycle, false = stop at first/last
    cycle_next_file = true, -- Wrap around when navigating files (]f/[f): true = cycle, false = stop at first/last
    cycle_hunks_across_files = false, -- ]c/[c at file boundary jumps to first/last hunk of next/prev file (explorer/history mode)
    jump_to_first_change = true, -- Auto-scroll to first change when opening a diff: true = jump to first hunk, false = stay at same line
    highlight_added_deleted_files = false, -- Tint the full contents of added, untracked, and deleted files
    highlight_priority = 100, -- Priority for line-level diff highlights (increase to override LSP highlights)
    gutter_signs = false, -- Gutter +/- signs; optionally block lower-priority signs on unchanged lines
    compute_moves = false, -- Detect moved code blocks (opt-in, may increase diff computation time)
    compact_context_lines = 3, -- Number of context lines around hunks in compact mode
    compact_sync_folds = true, -- Sync fold open/close across panes in compact mode (mirrors Vim diff mode behavior)
    compact = false, -- Default compact preference for each CodeDiff session; still toggleable with the gc keymap
  },

  -- Explorer panel configuration
  explorer = {
    position = "left", -- "left", "right", "top", or "bottom"
    hidden = false, -- Initial visibility state
    width = 40, -- Width when position is "left" (columns)
    height = 15, -- Height when position is "bottom" (lines)
    auto_refresh = true, -- Native explorer refresh with polling fallback
    view_mode = "list", -- "list" (flat file list) or "tree" (directory tree)
    indent_markers = true, -- Show indent markers in tree view (│, ├, └)
    initial_focus = "explorer", -- Initial focus: "explorer", "original", or "modified"
    icons = {
      folder_closed = "\u{e5ff}", -- Nerd Font: folder
      folder_open = "\u{e5fe}", -- Nerd Font: folder-open
    },
    file_filter = {
      ignore = { ".git/**", ".jj/**" }, -- Glob patterns to hide (e.g., {"*.lock", "dist/*"})
    },
    untracked = "all", -- Untracked file scan: "all" (-uall), "normal" (-unormal, collapse dirs), or "no" (-uno, skip; use for huge work trees like GIT_WORK_TREE=$HOME that hang, #389)
    focus_on_select = false, -- Jump to modified pane after selecting a file (default: stay in explorer)
    auto_open_on_cursor = false, -- Rebind j/k/Down/Up in the explorer to also open the file under the cursor
    flatten_dirs = true, -- Flatten single-child directory chains in tree view (e.g., src/components/ui/)
    status_right_margin = 1, -- Trailing cells between the status symbol (M/A/D) and the right edge; increase if Nerd Font icons clip it
    line_stats = {
      enabled = false,
      count_untracked = false,
      max_untracked_bytes = 1024 * 1024,
    },
    ellipsis = "…", -- Text appended to truncated Explorer regions
    formatters = { -- nil = use the built-in from lua/codediff/ui/explorer/formatters/
      file = nil, -- File rows: function(ctx) -> layout
      folder = nil, -- Directory rows in tree view: function(ctx) -> layout
      group = nil, -- Section headers such as Changes and Staged: function(ctx) -> layout
    },
    visible_groups = { -- Which groups to show in explorer (can be toggled at runtime)
      staged = true,
      unstaged = true,
      conflicts = true,
    },
  },

  -- History panel configuration (for :CodeDiff history)
  history = {
    position = "bottom", -- "left", "right", "top", or "bottom" (default: bottom)
    width = 40, -- Width when position is "left" (columns)
    height = 15, -- Height when position is "bottom" (lines)
    initial_focus = "history", -- Initial focus: "history", "original", or "modified"
    view_mode = "list", -- "list" or "tree" for files under commits
    date_format = "%ar", -- Commit date rendering: "%ar" (default, git's relative like "3 days ago"), "%ai" (ISO), "%ad" (git's default), or any strftime string (e.g. "%Y/%m/%d %H:%M:%S")
  },

  -- Keymaps
  keymaps = {
    view = {
      quit = "q", -- Close diff tab
      toggle_explorer = "<leader>b", -- Toggle explorer visibility (explorer mode only)
      focus_explorer = "<leader>e", -- Focus explorer panel (explorer mode only)
      next_hunk = "]c",
      prev_hunk = "[c",
      next_file = "]f",
      prev_file = "[f",
      diff_get = "do", -- Get change from other buffer (like vimdiff)
      diff_put = "dp", -- Put change to other buffer (like vimdiff)
      open_in_prev_tab = "gf", -- Open current buffer in previous tab (or new tab before current)
      close_on_open_in_prev_tab = false, -- Close codediff tab after opening in previous tab
      toggle_stage = "-", -- Stage/unstage current file (works in explorer and diff buffers)
      toggle_staged_view = "gS", -- Swap between staged/unstaged view of current file (#352)
      stage_hunk = "<leader>hs", -- Stage the hunk under cursor to git index
      unstage_hunk = "<leader>hu", -- Unstage the hunk under cursor from git index
      discard_hunk = "<leader>hr", -- Discard the hunk under cursor (working tree only)
      hunk_textobject = "ih", -- Textobject for hunk (vih to select, yih to yank, etc.)
      align_move = "gm", -- Temporarily align other pane to show paired moved code
      toggle_layout = "t", -- Toggle diff layout for the current codediff session
      toggle_compact = "gc", -- Toggle compact mode (fold unchanged regions, show only hunks + context)
      show_help = "g?", -- Show floating window with available keymaps
    },
    explorer = {
      select = "<CR>",
      hover = "K",
      refresh = "R",
      toggle_view_mode = "i", -- Toggle between 'list' and 'tree' views
      stage_all = "S", -- Stage all files
      unstage_all = "U", -- Unstage all files
      restore = "X", -- Discard changes to file (restore to index/HEAD)
      toggle_changes = "gu", -- Toggle Changes (unstaged) group visibility
      toggle_staged = "gs", -- Toggle Staged Changes group visibility
      -- Fold keymaps (Vim-style)
      fold_open = "zo", -- Open fold (expand current node)
      fold_open_recursive = "zO", -- Open fold recursively (expand current node and all descendants)
      fold_close = "zc", -- Close fold (collapse current node)
      fold_close_recursive = "zC", -- Close fold recursively (collapse current node and all descendants)
      fold_toggle = "za", -- Toggle fold (expand/collapse current node)
      fold_toggle_recursive = "zA", -- Toggle fold recursively
      fold_open_all = "zR", -- Open all folds in tree
      fold_close_all = "zM", -- Close all folds in tree
    },
    history = {
      select = "<CR>", -- Select commit/file or toggle expand
      toggle_view_mode = "i", -- Toggle between 'list' and 'tree' views
      refresh = "R", -- Refresh history (re-fetch commits)
      -- Fold keymaps (Vim-style, apply to directory nodes only)
      fold_open = "zo",
      fold_open_recursive = "zO",
      fold_close = "zc",
      fold_close_recursive = "zC",
      fold_toggle = "za",
      fold_toggle_recursive = "zA",
      fold_open_all = "zR",
      fold_close_all = "zM",
    },
    -- Conflict mode keymaps (only active in merge conflict views)
    conflict = {
      accept_incoming = "<leader>ct", -- Accept incoming (theirs/left) change
      accept_current = "<leader>co", -- Accept current (ours/right) change
      accept_both = "<leader>cb", -- Accept both changes (incoming first)
      discard = "<leader>cx", -- Discard both, keep base
      -- Accept all (whole file) - uppercase versions like diffview
      accept_all_incoming = "<leader>cT", -- Accept ALL incoming changes
      accept_all_current = "<leader>cO", -- Accept ALL current changes
      accept_all_both = "<leader>cB", -- Accept ALL both changes
      discard_all = "<leader>cX", -- Discard ALL, reset to base
      next_conflict = "]x", -- Jump to next conflict
      prev_conflict = "[x", -- Jump to previous conflict
      -- Vimdiff-style numbered diffget (from result buffer)
      diffget_incoming = "2do", -- Get hunk from incoming (left/theirs) buffer
      diffget_current = "3do", -- Get hunk from current (right/ours) buffer
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
