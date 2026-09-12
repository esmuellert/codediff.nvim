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

function M.toggle_layout(tabpage)
  return require("codediff.ui.view.toggle").toggle(tabpage)
end

function M.get_current_layout(tabpage)
  return get_layout(nil, tabpage)
end

return M
