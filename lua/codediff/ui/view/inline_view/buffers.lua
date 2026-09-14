-- Buffer lifecycle for inline diff views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")

function M.clear_highlights(session)
  for _, bufnr in pairs({ session.original_bufnr, session.modified_bufnr }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      lifecycle.clear_highlights(bufnr)
    end
  end
end

--- Replace a scratch buffer's contents, restoring its read-only state.
--- Returns false when the buffer is gone, which is the caller's cue to stop:
--- the tab may have closed while the fetch was in flight.
--- @param bufnr number
--- @param lines string[]
--- @return boolean
function M.set_scratch_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  return true
end

--- An empty, unlisted, non-file buffer.
--- @return number
function M.new_scratch()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  return bufnr
end

return M
