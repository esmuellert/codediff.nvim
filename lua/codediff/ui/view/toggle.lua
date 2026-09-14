local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")

local function normalize_inline_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  lifecycle.update_layout(tabpage, "inline")
  session.single_pane = nil

  local original_win = session.original_win
  local modified_win = session.modified_win
  local keep_win = (modified_win and vim.api.nvim_win_is_valid(modified_win) and modified_win) or (original_win and vim.api.nvim_win_is_valid(original_win) and original_win)

  if not keep_win then
    return false
  end

  session.original_win = keep_win
  session.modified_win = keep_win

  local close_win = nil
  if original_win and modified_win and original_win ~= modified_win then
    close_win = keep_win == modified_win and original_win or modified_win
  end

  if close_win and vim.api.nvim_win_is_valid(close_win) then
    vim.api.nvim_set_current_win(keep_win)
    pcall(vim.api.nvim_win_close, close_win, true)
  end

  return true
end

--- Reshape a tab to one pane and a session that says so; side_by_side.update
--- opens the second pane itself when it sees single_pane.
--- Exported because conflict mode needs it too.
--- @param tabpage number
--- @return boolean
function M.normalize_side_by_side_layout(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local current_win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win) and session.original_win)

  if not current_win then
    return false
  end

  lifecycle.update_layout(tabpage, "side-by-side")
  session.single_pane = true
  session.original_win = nil
  session.modified_win = current_win
  return true
end

-- Re-render the current file in the new layout.
-- Panels replay the session's selected comparison through the data controller.
-- For a bare diff (no panel): rebuild session_config from existing session fields.
local function rerender_current_file(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if session.panel then
    return require("codediff.ui.refresh").reopen(tabpage)
  end

  -- No panel: rebuild from session fields
  local session_config = {
    panel = session.panel,
    git_root = session.git_root,
    original = session.original,
    modified = session.modified,
    original_revision = session.original_revision,
    modified_revision = session.modified_revision,
    source_revisions = session.source_revisions,
  }
  return require("codediff.ui.view").update(tabpage, session_config, false)
end

function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    vim.notify("Cannot toggle layout in conflict mode", vim.log.levels.WARN)
    return false
  end

  local target_layout = session.layout == "inline" and "side-by-side" or "inline"
  local normalize = target_layout == "inline" and normalize_inline_layout or M.normalize_side_by_side_layout
  local previous_layout = session.layout

  -- Disable compact mode before changing layout (window IDs will change)
  local compact = require("codediff.ui.view.compact")
  local was_compact = session.compact_mode
  if was_compact then
    compact.disable(tabpage)
  end

  if not normalize(tabpage) then
    return false
  end

  local refresh = require("codediff.ui.refresh")
  refresh.begin(tabpage)
  if rerender_current_file(tabpage) then
    layout.arrange(tabpage)
  else
    refresh.ready(tabpage)
  end

  -- Re-enable compact mode in new layout
  if was_compact then
    compact.enable(tabpage)
  end

  return true
end

return M
