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
    disable_inlay_hints = true, -- Disable inlay hints in diff windows for cleaner view
    max_computation_time_ms = 5000, -- Maximum time for diff computation (5 seconds, VSCode default)
    hide_merge_artifacts = false, -- Hide merge tool temp files (*.orig, *.BACKUP.*, *.BASE.*, *.LOCAL.*, *.REMOTE.*)
    original_position = "left", -- Position of original (old) content: "left" or "right"
    conflict_ours_position = "right", -- Position of ours (:2) in conflict view: "left" or "right" (independent of original_position)
  },

  -- Explorer panel configuration
  explorer = {
    position = "left", -- "left" or "bottom"
    width = 40, -- Width when position is "left" (columns)
    height = 15, -- Height when position is "bottom" (lines)
    view_mode = "list", -- "list" (flat file list) or "tree" (directory tree)
    indent_markers = true, -- Show indent markers in tree view (│, ├, └)
    icons = {
      folder_closed = "\u{e5ff}", -- Nerd Font: folder
      folder_open = "\u{e5fe}", -- Nerd Font: folder-open
    },
    file_filter = {
      ignore = {}, -- Glob patterns to hide (e.g., {"*.lock", "dist/*"})
    },
  },

  -- Keymaps
  keymaps = {
    view = {
      quit = "q", -- Close diff tab
      toggle_explorer = "<leader>b", -- Toggle explorer visibility (explorer mode only)
      next_hunk = "]c",
      prev_hunk = "[c",
      next_file = "]f",
      prev_file = "[f",
      diff_get = "do", -- Get change from other buffer (like vimdiff)
      diff_put = "dp", -- Put change to other buffer (like vimdiff)
    },
    explorer = {
      select = "<CR>",
      hover = "K",
      refresh = "R",
      toggle_view_mode = "i", -- Toggle between 'list' and 'tree' views
      toggle_stage = "-", -- Stage/unstage selected file (like diffview)
      stage_all = "S", -- Stage all files
      unstage_all = "U", -- Unstage all files
      restore = "X", -- Discard changes to file (restore to index/HEAD)
    },
    -- Conflict mode keymaps (only active in merge conflict views)
    conflict = {
      accept_incoming = "<leader>ct", -- Accept incoming (theirs/left) change
      accept_current = "<leader>co", -- Accept current (ours/right) change
      accept_both = "<leader>cb", -- Accept both changes (incoming first)
      discard = "<leader>cx", -- Discard both, keep base
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
