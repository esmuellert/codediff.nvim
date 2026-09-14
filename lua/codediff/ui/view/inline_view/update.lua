-- Updates inline views for Explorer and History file switches.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local welcome_window = require("codediff.ui.view.welcome_window")
local helpers = require("codediff.ui.view.helpers")
local readiness = require("codediff.ui.view.readiness")
local buffers = require("codediff.ui.view.inline_view.buffers")
local inline_render = require("codediff.ui.view.inline_view.render")
local inline_keymaps = require("codediff.ui.view.inline_view.keymaps")

local is_virtual_revision = helpers.is_virtual_revision
local prepare_buffer = helpers.prepare_buffer
local show_real_file_buffer = helpers.show_real_file_buffer
local open_real_file = helpers.open_real_file
local clear_highlights = buffers.clear_highlights
local set_scratch_lines = buffers.set_scratch_lines
local new_scratch = buffers.new_scratch
local compute_and_render_inline = inline_render.compute_and_render_inline
local setup_keymaps = inline_keymaps.setup

--- Fetch a revision from git into a scratch buffer, then signal completion.
--- Signals nothing if the buffer died while the fetch was in flight.
--- @param revision string
--- @param git_root string
--- @param relative string
--- @param bufnr number
--- @param done function
local function fetch_into_scratch(revision, git_root, relative, bufnr, done)
  require("codediff.core.git").get_file_content(revision, git_root, relative, function(err, lines)
    vim.schedule(function()
      if require("codediff.core.virtual_file").set_content(bufnr, err and {} or lines, relative) then
        done()
      end
    end)
  end)
end

--- Put the modified side in the pane.
--- Unlike create, a virtual revision goes into a scratch buffer rather than a
--- codediff:// URI, so retargeting never races a pending BufReadCmd.
--- @param win number
--- @param session_config SessionConfig
--- @param is_virtual boolean
--- @return number bufnr
local function open_modified_for_update(win, session_config, is_virtual)
  if is_virtual then
    local mod_buf = new_scratch()
    vim.bo[mod_buf].modifiable = true
    vim.api.nvim_win_set_buf(win, mod_buf)
    return mod_buf
  end

  local info = prepare_buffer(false, session_config.git_root, nil, session_config.modified)
  if info.needs_edit then
    return open_real_file(win, info.target)
  end
  show_real_file_buffer(win, info.bufnr)
  return info.bufnr
end

--- Fill the hidden original side. A real file is copied in synchronously; a
--- revision is fetched and lands through `done`.
--- @param orig_buf number
--- @param session_config SessionConfig
--- @param is_virtual boolean
--- @param done function Called when an async fetch lands
local function fill_original_for_update(orig_buf, session_config, is_virtual, done)
  if is_virtual then
    -- Retargeting can leave the original path empty (a file added in the
    -- modified revision), so fall back to the modified side's path.
    local relative = (session_config.original.relative ~= "" and session_config.original.relative) or session_config.modified.relative
    fetch_into_scratch(session_config.original_revision, session_config.git_root, relative, orig_buf, done)
    return
  end

  local orig_path = session_config.original.absolute
  if orig_path and orig_path ~= "" then
    local real_bufnr = vim.fn.bufadd(orig_path)
    vim.fn.bufload(real_bufnr)
    set_scratch_lines(orig_buf, vim.api.nvim_buf_get_lines(real_bufnr, 0, -1, false))
  end
end

--- Point the session at the newly computed diff and re-arm everything hanging
--- off it: refresh, keymaps, layout, and the window the user was in.
--- @param tabpage number
--- @param session_config SessionConfig
--- @param orig_buf number
--- @param mod_buf number
--- @param lines_diff table
--- @param saved_current_win number?
local function commit_update(tabpage, session_config, orig_buf, mod_buf, lines_diff, saved_current_win)
  lifecycle.update_buffers(tabpage, orig_buf, mod_buf)
  lifecycle.update_git_root(tabpage, session_config.git_root)
  lifecycle.update_revisions(tabpage, session_config.original_revision, session_config.modified_revision)
  lifecycle.update_diff_result(tabpage, lines_diff)
  lifecycle.update_changedtick(tabpage, vim.api.nvim_buf_get_changedtick(orig_buf), vim.api.nvim_buf_get_changedtick(mod_buf))
  lifecycle.update_paths(tabpage, session_config.original, session_config.modified)

  setup_keymaps(tabpage, orig_buf, mod_buf)
  layout.arrange(tabpage)

  if saved_current_win and vim.api.nvim_win_is_valid(saved_current_win) then
    vim.api.nvim_set_current_win(saved_current_win)
  end
end

---@param tabpage number
---@param session_config SessionConfig
---@param auto_scroll_to_first_hunk boolean?
---@return boolean
function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  local saved_current_win = vim.api.nvim_get_current_win()

  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local generation = session.refresh and session.refresh.generation
  local modified_win = session.modified_win
  if not modified_win or not vim.api.nvim_win_is_valid(modified_win) then
    return false
  end

  -- ns_highlight/ns_filler may linger after toggling from side-by-side.
  clear_highlights(session)

  session.single_side = nil
  lifecycle.update_diff_result(tabpage, nil)

  -- Retargeting can move a session between a conflicted file and an ordinary
  -- one, so the merge flag follows the incoming config.
  lifecycle.update_merge(tabpage, session_config.conflict)

  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  local orig_buf = new_scratch()
  local mod_buf = open_modified_for_update(modified_win, session_config, modified_is_virtual)
  welcome_window.sync(modified_win)

  local should_auto_scroll = auto_scroll_to_first_hunk == true

  local render = function()
    if not require("codediff.ui.refresh").is_current(tabpage, session, generation) then
      return
    end
    if not vim.api.nvim_win_is_valid(modified_win) then
      return
    end
    if not vim.api.nvim_buf_is_valid(orig_buf) or not vim.api.nvim_buf_is_valid(mod_buf) then
      return
    end

    local lines_diff = compute_and_render_inline(
      mod_buf,
      orig_buf,
      vim.api.nvim_buf_get_lines(orig_buf, 0, -1, false),
      vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false),
      original_is_virtual,
      modified_is_virtual,
      modified_win,
      should_auto_scroll
    )
    if lines_diff then
      commit_update(tabpage, session_config, orig_buf, mod_buf, lines_diff, saved_current_win)
    end
  end

  -- Each side reports itself as it lands; the last one triggers the render.
  -- Sides that are already in hand are simply not awaited.
  local awaited = {}
  if original_is_virtual then
    awaited[#awaited + 1] = "original"
  end
  if modified_is_virtual then
    awaited[#awaited + 1] = "modified"
  end

  local ready = readiness.when_all(awaited, function()
    vim.schedule(render)
  end)

  fill_original_for_update(orig_buf, session_config, original_is_virtual, function()
    ready.done("original")
  end)

  if modified_is_virtual then
    fetch_into_scratch(session_config.modified_revision, session_config.git_root, session_config.modified.relative, mod_buf, function()
      ready.done("modified")
    end)
  end

  return true
end

return M
