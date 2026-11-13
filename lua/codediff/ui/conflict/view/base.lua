-- Optional fourth conflict pane showing the merge base (:1:).
--
-- The pane sits in the middle of the top row: between Incoming and Current in
-- the bottom-result layout, and above Result in the center-result layout. It is
-- read-only, scroll-bound with the inputs, and aligned with them through the
-- same filler computation, so a line in Base stays level with its counterpart
-- on both sides.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local virtual_file = require("codediff.core.virtual_file")

local WINBAR = " Base (Common ancestor)"

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

--- Whether the Base pane should be shown for this session.
--- The session keeps its own preference once toggled; until then the config
--- default applies.
--- @param session table
--- @return boolean
function M.is_enabled(session)
  if session.show_base ~= nil then
    return session.show_base
  end
  return config.options.diff.conflict_show_base == true
end

--- True when the Base pane is currently on screen.
--- @param session table
--- @return boolean
function M.is_visible(session)
  if not valid_win(session.base_win) or not valid_buf(session.base_bufnr) then
    return false
  end
  return vim.api.nvim_win_get_buf(session.base_win) == session.base_bufnr
end

--- Buffer for the visible Base pane, or nil.
--- @param session table
--- @return number|nil
function M.visible_bufnr(session)
  if session and M.is_visible(session) then
    return session.base_bufnr
  end
  return nil
end

--- Replace the Base buffer content.
--- @param session table
--- @param base_lines table
function M.set_lines(session, base_lines)
  local bufnr = session.base_bufnr
  if not valid_buf(bufnr) then
    return
  end
  local relative = session.original and session.original.relative
  if relative and session.git_root then
    -- The same codediff:/// stage-:1 URL as any other virtual revision buffer.
    -- If another buffer already holds the name, keep this one unnamed.
    local name = virtual_file.create_url(session.git_root, ":1", relative)
    if vim.api.nvim_buf_get_name(bufnr) ~= name then
      pcall(vim.api.nvim_buf_set_name, bufnr, name)
    end
  end
  -- Shared with the virtual-file loader: read-only, Tree-sitter highlighting
  -- without firing FileType, so no LSP attaches to the codediff:// URI.
  virtual_file.set_content(bufnr, base_lines or {}, relative)
end

-- The content is set from session.merge_base_lines, which the conflict view
-- already fetched, rather than loaded through the codediff:/// BufReadCmd:
-- that would run git again and its bufhidden=wipe would drop the buffer
-- every time the pane is toggled off.
local function ensure_buffer(session)
  if valid_buf(session.base_bufnr) then
    return session.base_bufnr
  end
  -- Listed, like the Incoming and Current revision buffers.
  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.bo[bufnr].buftype = "nowrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  session.base_bufnr = bufnr
  return bufnr
end

--- Leftmost of the two input windows.
local function left_input_win(session)
  local orig_col = vim.api.nvim_win_get_position(session.original_win)[2]
  local mod_col = vim.api.nvim_win_get_position(session.modified_win)[2]
  return orig_col <= mod_col and session.original_win or session.modified_win
end

local function open_window(session, bufnr)
  local split
  if config.options.diff.conflict_result_position == "center" then
    split = { split = "above", win = session.result_win }
  else
    split = { split = "right", win = left_input_win(session) }
  end
  -- No codediff_restore flag: Base is auxiliary and must not change the
  -- window count that decides when closing panes ends the session.
  local win = vim.api.nvim_open_win(bufnr, false, split)
  vim.wo[win].wrap = false
  vim.wo[win].winbar = WINBAR
  return win
end

--- Re-render both inputs (and Base when visible) with matching alignment.
--- @param session table
function M.render(session)
  if not session or not session.merge_base_lines then
    return
  end
  if not valid_buf(session.original_bufnr) or not valid_buf(session.modified_bufnr) then
    return
  end
  local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
  require("codediff.ui.conflict.view.inputs").compute_and_render_conflict(
    session.original_bufnr,
    session.modified_bufnr,
    session.merge_base_lines,
    original_lines,
    modified_lines,
    { base_bufnr = M.visible_bufnr(session) }
  )
  -- Rendering clears the conflict namespace on the inputs; redraw the markers.
  require("codediff.ui.conflict").refresh(session)
end

--- Line the Base pane's view up with the inputs, using Current (or Incoming
--- when Current is gone) as the reference, and join their scrollbind group.
local function sync_view(session)
  if not M.is_visible(session) then
    return
  end
  local anchor = valid_win(session.modified_win) and session.modified_win or session.original_win
  if not valid_win(anchor) then
    return
  end
  local view = vim.api.nvim_win_call(anchor, vim.fn.winsaveview)
  vim.api.nvim_win_call(session.base_win, function()
    local line_count = vim.api.nvim_buf_line_count(session.base_bufnr)
    vim.fn.winrestview({ topline = math.min(view.topline, line_count), lnum = math.min(view.lnum, line_count), col = 0 })
  end)
  vim.wo[session.base_win].scrollbind = true
  vim.api.nvim_win_call(anchor, function()
    vim.cmd("syncbind")
  end)
end

--- Show the Base pane, creating its window and buffer when needed.
--- @param tabpage number
--- @return boolean shown
function M.show(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not valid_win(session.result_win) then
    return false
  end
  if not valid_win(session.original_win) or not valid_win(session.modified_win) then
    return false
  end

  local bufnr = ensure_buffer(session)
  M.set_lines(session, session.merge_base_lines or {})

  if not valid_win(session.base_win) then
    session.base_win = open_window(session, bufnr)
  elseif vim.api.nvim_win_get_buf(session.base_win) ~= bufnr then
    vim.api.nvim_win_set_buf(session.base_win, bufnr)
  end

  M.render(session)
  require("codediff.ui.layout").arrange(tabpage)
  sync_view(session)
  return true
end

--- Close the Base window. The buffer is kept so a later toggle reuses it.
--- @param session table
function M.close_window(session)
  local win = session.base_win
  session.base_win = nil
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Hide the Base pane and restore two-column alignment of the inputs.
--- @param tabpage number
function M.hide(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local was_visible = valid_win(session.base_win)
  M.close_window(session)
  if was_visible then
    M.render(session)
    require("codediff.ui.layout").arrange(tabpage)
  end
end

--- Make the pane match the session preference. Called whenever the conflict
--- view is (re)built for a file.
--- @param tabpage number
function M.sync(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  if M.is_enabled(session) then
    M.show(tabpage)
  else
    M.hide(tabpage)
  end
end

--- Toggle the Base pane for this session.
--- @param tabpage number
function M.toggle(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not valid_win(session.result_win) then
    vim.notify("Base pane is only available in a merge conflict view", vim.log.levels.WARN)
    return
  end
  local focused = vim.api.nvim_get_current_win()
  local had_buffer = valid_buf(session.base_bufnr)
  session.show_base = not M.is_visible(session)
  M.sync(tabpage)
  if session.show_base and not had_buffer then
    -- A freshly created buffer still needs the conflict mappings (toggle
    -- again, quit); an existing one kept them from the last bind.
    require("codediff.ui.conflict").setup_keymaps(tabpage)
  end
  if valid_win(focused) then
    vim.api.nvim_set_current_win(focused)
  elseif valid_win(session.modified_win) then
    vim.api.nvim_set_current_win(session.modified_win)
  end
end

--- Forget the Base pane when the session leaves conflict mode or ends.
--- @param session table
--- @param delete_buffer boolean
function M.teardown(session, delete_buffer)
  M.close_window(session)
  if delete_buffer and valid_buf(session.base_bufnr) then
    pcall(vim.api.nvim_buf_delete, session.base_bufnr, { force = true })
  end
  if delete_buffer then
    session.base_bufnr = nil
  end
end

return M
