-- Buffer preparation helpers for diff view
local M = {}

local virtual_file = require("codediff.core.virtual_file")

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
function M.is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Prepare buffer information for loading
-- Returns: { bufnr = number?, target = string?, needs_edit = boolean }
-- - If buffer already exists: { bufnr = 123, target = nil, needs_edit = false }
-- - If needs :edit: { bufnr = nil, target = "path or url", needs_edit = true }
function M.prepare_buffer(is_virtual, git_root, revision, path)
  if is_virtual then
    -- Virtual file: generate URL
    local virtual_url = virtual_file.create_url(git_root, revision, path)
    -- Check if buffer already exists
    local existing_buf = vim.fn.bufnr(virtual_url)

    -- For :0 (staged index), always force reload because index can change
    -- when user runs git add/reset. For commits (immutable), we can cache.
    local is_mutable_revision = revision == ":0" or revision == ":1" or revision == ":2" or revision == ":3"

    if existing_buf ~= -1 and not is_mutable_revision then
      -- Buffer exists for immutable revision, reuse it
      return {
        bufnr = existing_buf,
        target = virtual_url,
        needs_edit = false,
      }
    else
      -- Either buffer doesn't exist, or it's a mutable revision that needs refresh
      -- Don't delete here - let the :edit! handle it (will trigger BufReadCmd)
      return {
        bufnr = existing_buf ~= -1 and existing_buf or nil,
        target = virtual_url,
        needs_edit = true,
      }
    end
  else
    -- Real file: check if already loaded
    local existing_buf = vim.fn.bufnr(path)
    if existing_buf ~= -1 then
      -- Buffer already exists, reuse it
      return {
        bufnr = existing_buf,
        target = nil,
        needs_edit = false,
      }
    else
      -- Buffer doesn't exist, need to :edit it
      return {
        bufnr = nil,
        target = path,
        needs_edit = true,
      }
    end
  end
end

return M
