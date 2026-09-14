-- Displays one-sided files and welcome content in inline views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local core = require("codediff.ui.core")
local path = require("codediff.core.path")
local layout = require("codediff.ui.layout")
local welcome_window = require("codediff.ui.view.welcome_window")
local helpers = require("codediff.ui.view.helpers")
local buffers = require("codediff.ui.view.inline_view.buffers")

local open_real_file = helpers.open_real_file
local clear_highlights = buffers.clear_highlights

--- Display a single file in the inline diff window without any diff decorations.
--- Used for untracked (??), added (A), and deleted (D) files in explorer/history.
---@param tabpage number
---@param file_path string Path to load (absolute for real files)
---@param opts? { revision: string?, git_root: string?, rel_path: string?, side: "original"|"modified"? }
function M.show_single_file(tabpage, file_path, opts)
  opts = opts or {}
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local side = opts.side or "modified"

  lifecycle.update_layout(tabpage, "inline")
  local mod_win = session.modified_win
  if not mod_win or not vim.api.nvim_win_is_valid(mod_win) then
    return
  end

  -- Clear old inline decorations.
  clear_highlights(session)

  -- Load the file
  local file_bufnr
  if opts.revision and opts.git_root then
    -- Virtual file: reuse a buffer keyed by (git_root, revision, path) via the
    -- codediff:// URL scheme. This guarantees a stable bufnr across repeated
    -- calls (same fix as side_by_side.load_virtual_file). The BufReadCmd in
    -- core/virtual_file.lua handles content fetching and intentionally avoids
    -- setting filetype to prevent LSP attach crashes on the custom URI scheme.
    local virtual_file = require("codediff.core.virtual_file")
    local url = virtual_file.create_url(opts.git_root, opts.revision, opts.rel_path or file_path)
    file_bufnr = vim.fn.bufadd(url)
    vim.fn.bufload(file_bufnr)
    vim.api.nvim_win_set_buf(mod_win, file_bufnr)
    welcome_window.sync(mod_win)
  else
    -- Real file
    file_bufnr = open_real_file(mod_win, file_path)
    welcome_window.sync(mod_win)
  end

  -- Update session state
  local empty_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[empty_buf].buftype = "nofile"

  local session_path = (opts.revision and opts.rel_path) and opts.rel_path or file_path
  local file_ref = path.make_ref(session_path, opts.git_root or session.git_root)
  local orig_bufnr = side == "original" and file_bufnr or empty_buf
  local mod_bufnr = side == "modified" and file_bufnr or empty_buf
  local original = side == "original" and file_ref or path.empty()
  local modified = side == "modified" and file_ref or path.empty()
  local original_revision = side == "original" and opts.revision or nil
  local modified_revision = side == "modified" and opts.revision or nil

  lifecycle.update_buffers(tabpage, orig_bufnr, mod_bufnr)
  lifecycle.update_paths(tabpage, original, modified)
  lifecycle.update_revisions(tabpage, original_revision, modified_revision)
  lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
  session.single_side = side
  core.render_whole_file(file_bufnr, side)

  local view_keymaps = require("codediff.ui.view.keymaps")
  view_keymaps.setup_all_keymaps(tabpage, orig_bufnr, mod_bufnr, session.panel ~= nil and session.panel.name == "explorer")
  layout.arrange(tabpage)
  welcome_window.sync_later(mod_win)
end

--- Show the welcome page in the inline diff window
---@param tabpage number
---@param load_bufnr number Welcome buffer created by welcome.create_buffer
function M.show_welcome(tabpage, load_bufnr)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  lifecycle.update_layout(tabpage, "inline")
  local mod_win = session.modified_win
  if not mod_win or not vim.api.nvim_win_is_valid(mod_win) then
    return
  end

  clear_highlights(session)
  session.single_side = nil

  vim.api.nvim_win_set_buf(mod_win, load_bufnr)
  welcome_window.sync(mod_win)

  local empty_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[empty_buf].buftype = "nofile"

  lifecycle.update_buffers(tabpage, empty_buf, load_bufnr)
  lifecycle.update_paths(tabpage, path.empty(), path.empty())
  lifecycle.update_revisions(tabpage, nil, nil)
  lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })

  local view_keymaps = require("codediff.ui.view.keymaps")
  view_keymaps.setup_all_keymaps(tabpage, empty_buf, load_bufnr, session.panel ~= nil and session.panel.name == "explorer")
  layout.arrange(tabpage)
  welcome_window.sync_later(mod_win)
end

return M
