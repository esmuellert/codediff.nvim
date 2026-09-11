-- Centralized layout manager for codediff windows
-- Single source of truth for all window sizing decisions
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

--- Arrange all windows in a codediff tabpage
--- Call this after any structural window change (create, toggle, conflict setup)
--- @param tabpage number
function M.arrange(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local original_win = session.original_win
  local modified_win = session.modified_win
  local result_win = session.result_win
  local panel = session.panel and session.panel.view

  -- Panel state
  local panel_win = panel and panel.winid
  local panel_visible = panel_win and vim.api.nvim_win_is_valid(panel_win) and not panel.is_hidden

  -- Panel config lives under the panel's own name in the user config
  local panel_name = session.panel and session.panel.name or "explorer"
  local panel_config = config.options[panel_name] or {}
  local panel_position = panel_config.position or "left"

  -- Step 1: Pin panel size (fixed element)
  if panel_visible then
    if panel_position == "left" or panel_position == "right" then
      vim.api.nvim_win_set_width(panel_win, panel_config.width)
    else
      vim.api.nvim_win_set_height(panel_win, panel_config.height)
    end
  end

  local orig_valid = original_win and vim.api.nvim_win_is_valid(original_win)
  local mod_valid = modified_win and vim.api.nvim_win_is_valid(modified_win)
  local is_single_diff_window = session.layout == "inline" or original_win == modified_win

  -- Single-pane mode: one diff window takes all available space
  if session.single_pane or is_single_diff_window or (orig_valid ~= mod_valid) then
    local sole_win = orig_valid and original_win or (mod_valid and modified_win or nil)
    if sole_win then
      if panel_visible then
        if panel_position == "left" or panel_position == "right" then
          vim.api.nvim_win_set_width(panel_win, panel_config.width)
          -- Explicitly set diff window to fill remainder
          local remainder = vim.o.columns - panel_config.width - 1
          vim.api.nvim_win_set_width(sole_win, remainder)
        else
          vim.api.nvim_win_set_height(panel_win, panel_config.height)
          -- Diff window takes full width
          vim.api.nvim_win_set_width(sole_win, vim.o.columns)
        end
      end
    end
    return
  end

  -- Both windows must be valid for two-pane layout
  if not orig_valid or not mod_valid then
    return
  end

  local has_result = result_win and vim.api.nvim_win_is_valid(result_win)

  -- Step 2: Collect diff windows and sum their current widths
  -- In center layout, result is a sibling column — include it
  -- In bottom layout, result is in a separate row — exclude it
  local result_position = config.options.diff.conflict_result_position
  local result_is_center = has_result and result_position == "center"

  local available = vim.api.nvim_win_get_width(original_win) + vim.api.nvim_win_get_width(modified_win)
  if result_is_center then
    available = available + vim.api.nvim_win_get_width(result_win)
  end

  -- Step 3: Handle result window height (bottom layout)
  if has_result and not result_is_center then
    local pct = math.min(90, math.max(10, config.options.diff.conflict_result_height))
    vim.api.nvim_win_set_height(result_win, math.floor(vim.o.lines * pct / 100))
  end

  -- Step 4: Distribute widths among diff panes
  if result_is_center then
    -- Three panes with configurable ratio
    local r = config.options.diff.conflict_result_width_ratio
    local total_r = r[1] + r[2] + r[3]

    -- Determine left/right based on window column positions
    local orig_col = vim.api.nvim_win_get_position(original_win)[2]
    local mod_col = vim.api.nvim_win_get_position(modified_win)[2]
    local left_win = orig_col <= mod_col and original_win or modified_win
    local right_win = left_win == original_win and modified_win or original_win

    local lw = math.floor(available * r[1] / total_r)
    local cw = math.floor(available * r[2] / total_r)

    vim.api.nvim_win_set_width(left_win, lw)
    vim.api.nvim_win_set_width(result_win, cw)
    vim.api.nvim_win_set_width(right_win, available - lw - cw)
  else
    -- Two diff panes, equal split
    local half = math.floor(available / 2)
    vim.api.nvim_win_set_width(original_win, half)
    vim.api.nvim_win_set_width(modified_win, available - half)
  end

  -- Step 5: Re-pin panel size (undo disturbance from step 4)
  if panel_visible then
    if panel_position == "left" or panel_position == "right" then
      vim.api.nvim_win_set_width(panel_win, panel_config.width)
    else
      vim.api.nvim_win_set_height(panel_win, panel_config.height)
    end
  end
end

return M
