-- Diff view router — dispatches to the appropriate view engine
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local side_by_side = require("codediff.ui.view.side_by_side")

-- Once-guard: register lifecycle autocmds on first view creation
local lifecycle_initialized = false

local function get_layout(session_config, tabpage)
  if session_config and session_config.conflict then
    return "side-by-side"
  end
  local session = tabpage and lifecycle.get_session(tabpage) or nil
  if session and session.layout then
    return session.layout
  end
  if session_config and session_config.layout then
    return session_config.layout
  end
  return config.options.diff.layout
end

---@class SessionConfig
---@field panel { name: "explorer"|"history", data: table }? Side panel; nil for a bare diff
---@field git_root string?
---@field original Path
---@field modified Path
---@field original_revision string?
---@field modified_revision string?
---@field source_revisions { original: string?, modified: string? }? Requested refs before resolution; retained for refresh
---@field conflict boolean? For merge conflict mode: render both sides against base
---@field layout "side-by-side"|"inline"? Optional per-invocation layout override
---@field exit_on_close boolean? Exit Neovim when this session closes
---@field line_range table? For history line-range mode: { start_line, end_line }

---@param session_config SessionConfig Session configuration
---@param filetype? string Optional filetype for syntax highlighting
---@param on_ready? function Optional callback when view is fully ready (for sync callers)
---@return table|nil Result containing diff metadata, or nil if deferred
function M.create(session_config, filetype, on_ready)
  -- Initialize lifecycle autocmds on first use
  if not lifecycle_initialized then
    lifecycle.setup()
    lifecycle_initialized = true
  end

  if get_layout(session_config) == "inline" then
    return require("codediff.ui.view.inline_view").create(session_config, filetype, on_ready)
  end

  return side_by_side.create(session_config, filetype, on_ready)
end

---Update existing diff view with new files/revisions
---@param tabpage number Tabpage ID of the diff session
---@param session_config SessionConfig New session configuration (updates both sides)
---@param auto_scroll_to_first_hunk boolean? Whether to auto-scroll to first hunk (default: false)
---@return boolean success Whether update succeeded
function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  if not lifecycle.get_session(tabpage) then
    return false
  end
  require("codediff.ui.refresh").begin(tabpage, session_config)
  if get_layout(session_config, tabpage) == "inline" then
    return require("codediff.ui.view.inline_view").update(tabpage, session_config, auto_scroll_to_first_hunk)
  end

  -- An inline tab has one pane with both sides pointing at it; side-by-side
  -- would write both into that window. Reshape it first -- side_by_side.update
  -- opens the missing pane itself.
  local session = lifecycle.get_session(tabpage)
  if session_config and session_config.conflict and session and session.layout == "inline" then
    require("codediff.ui.view.toggle").normalize_side_by_side_layout(tabpage)
  end

  return side_by_side.update(tabpage, session_config, auto_scroll_to_first_hunk)
end

-- Display a resolved comparison selected by the session controller.
function M.show(tabpage, session_config, jump)
  local side = session_config.single_side
  if not side then
    return M.update(tabpage, session_config, jump)
  end
  lifecycle.update_merge(tabpage, session_config.conflict)
  local ref = session_config[side]
  local revision = session_config[side .. "_revision"]
  if get_layout(session_config, tabpage) == "inline" then
    require("codediff.ui.view.inline_view").show_single_file(tabpage, ref.absolute, {
      revision = revision ~= "WORKING" and revision or nil,
      git_root = session_config.git_root,
      rel_path = ref.relative,
      side = side,
    })
  elseif revision and revision ~= "WORKING" then
    local show = side == "original" and side_by_side.show_deleted_virtual_file or side_by_side.show_added_virtual_file
    show(tabpage, session_config.git_root, ref.relative, revision)
  else
    side_by_side.show_untracked_file(tabpage, ref.absolute)
  end
  return true
end

function M.show_welcome(tabpage)
  local session = lifecycle.get_session(tabpage)
  local win = session and session.modified_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local welcome = require("codediff.ui.welcome")
  if welcome.is_welcome_buffer(session.modified_bufnr) then
    require("codediff.ui.refresh").ready(tabpage)
    return true
  end
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  local original = session.original_win
  if session.layout ~= "inline" and original and vim.api.nvim_win_is_valid(original) then
    width, height = width + vim.api.nvim_win_get_width(original) + 1, vim.api.nvim_win_get_height(original)
  end
  local buf = welcome.create_buffer(width, height)
  if session.layout == "inline" then
    require("codediff.ui.view.inline_view").show_welcome(tabpage, buf)
  else
    side_by_side.show_welcome(tabpage, buf)
  end
  return true
end

function M.toggle_layout(tabpage)
  return require("codediff.ui.view.toggle").toggle(tabpage)
end

function M.get_current_layout(tabpage)
  return get_layout(nil, tabpage)
end

return M
