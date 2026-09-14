-- State management for diff views.
local M = {}
local highlights = require("codediff.ui.highlights")

function M.save_buffer_state(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  -- A second session must save the user's setting, not the first session's
  -- temporary disabled value for this shared buffer.
  for _, session in pairs(require("codediff.ui.lifecycle.session").get_active_diffs()) do
    if session.original_bufnr == bufnr and session.original_state then
      return vim.deepcopy(session.original_state)
    elseif session.modified_bufnr == bufnr and session.modified_state then
      return vim.deepcopy(session.modified_state)
    end
  end
  local state = {}
  if vim.lsp.inlay_hint then
    state.inlay_hints_enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
  end
  return state
end

function M.restore_buffer_state(bufnr, state)
  if not vim.api.nvim_buf_is_valid(bufnr) or not state then
    return
  end
  if vim.lsp.inlay_hint and state.inlay_hints_enabled ~= nil then
    vim.lsp.inlay_hint.enable(state.inlay_hints_enabled, { bufnr = bufnr })
  end
end

function M.clear_buffer_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns_conflict, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("codediff-inline"), 0, -1)
  require("codediff.ui.gutter_signs").clear_buffer(bufnr)
end

function M.get_file_mtime(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^codediff://") then
    return nil
  end
  local stat = (vim.uv or vim.loop).fs_stat(name)
  return stat and stat.mtime.sec or nil
end

function M.suspend_diff(tabpage)
  local session = require("codediff.ui.lifecycle").get_session(tabpage)
  if not session or session.suspended then
    return
  end
  session.suspended = true
  M.clear_buffer_highlights(session.original_bufnr)
  M.clear_buffer_highlights(session.modified_bufnr)
  if session.result_bufnr then
    M.clear_buffer_highlights(session.result_bufnr)
  end
  -- Keep collecting invalidations while hidden; apply them when the tab returns.
  require("codediff.ui.refresh").request(tabpage, { render = true })
end

function M.resume_diff(tabpage)
  local sessions = require("codediff.ui.lifecycle.session").get_active_diffs()
  local session = sessions[tabpage]
  if not session or not session.suspended then
    return
  end
  if not vim.api.nvim_buf_is_valid(session.original_bufnr) or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    require("codediff.ui.refresh").dispose(tabpage)
    require("codediff.ui.conflict").teardown_gutter(tabpage)
    if session.keymaps then
      session.keymaps:dispose()
      session.keymaps = nil
    end
    sessions[tabpage] = nil
    return
  end
  session.suspended = false
  local refresh = require("codediff.ui.refresh")
  refresh.replay(tabpage)
  refresh.request(tabpage, { full = true })
end

return M
