-- Configuration module
local M = {}

M.defaults = {
  -- Highlight configuration
  highlights = {
    -- Line-level highlights: accepts highlight group names (e.g., "DiffAdd") or color values (e.g., "#2ea043")
    line_insert = "DiffAdd",      -- Line-level insertions (base color)
    line_delete = "DiffDelete",   -- Line-level deletions (base color)

    -- Character-level highlights: accepts highlight group names or color values
    -- If specified, these override char_brightness calculation
    char_insert = nil,  -- Character-level insertions (if nil, derived from line_insert with char_brightness)
    char_delete = nil,  -- Character-level deletions (if nil, derived from line_delete with char_brightness)

    -- Brightness multiplier for character-level highlights (only used if char_insert/char_delete are nil)
    -- nil = auto-detect based on background (1.4 for dark, 0.92 for light)
    -- Set explicit value to override: char_brightness = 1.2
    char_brightness = nil,
  },

  -- Diff view behavior
  diff = {
    disable_inlay_hints = true,  -- Disable inlay hints in diff windows for cleaner view
    max_computation_time_ms = 5000,  -- Maximum time for diff computation (5 seconds, VSCode default)
  },

  -- Keymaps
  keymaps = {
    view = {
      quit = "q",                   -- Close diff tab
      toggle_explorer = "<leader>b", -- Toggle explorer visibility (explorer mode only)
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
    -- Conflict mode keymaps (only active in merge conflict views)
    conflict = {
      accept_incoming = "<leader>ct",  -- Accept incoming (theirs/left) change
      accept_current = "<leader>co",   -- Accept current (ours/right) change
      accept_both = "<leader>cb",      -- Accept both changes (incoming first)
      discard = "<leader>cx",          -- Discard both, keep base
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
