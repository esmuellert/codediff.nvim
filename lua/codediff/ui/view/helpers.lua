-- Buffer preparation helpers for diff view
local M = {}

local virtual_file = require("codediff.core.virtual_file")
local path = require("codediff.core.path")

--- True when the panel opens before any file is chosen, so the panes start
--- empty and the panel fills them on first selection.
--- @param session_config SessionConfig
--- @return boolean
function M.is_panel_placeholder(session_config)
  local panel_cfg = session_config.panel
  if not panel_cfg then
    return false
  end
  if panel_cfg.name == "history" then
    return panel_cfg.data ~= nil
  end
  if panel_cfg.name == "explorer" then
    -- Empty paths, or dir mode, which has no git_root but does have panel data.
    return path.is_empty(session_config.original) or (not session_config.git_root and panel_cfg.data ~= nil)
  end
  return false
end

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
function M.is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Exact buffer name lookup (vim.fn.bufnr uses pattern matching which
-- causes prefix collisions, e.g. "Makefile" matching "Makefile.win")
local function bufnr_exact(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return -1
end

-- Prepare buffer information for loading
-- Returns: { bufnr = number?, target = string?, needs_edit = boolean }
-- - If buffer already exists: { bufnr = 123, target = nil, needs_edit = false }
-- - If needs :edit: { bufnr = nil, target = "path or url", needs_edit = true }
---@param is_virtual boolean
---@param git_root string?
---@param revision string?
---@param ref Path `.relative` builds the codediff:// URL; `.absolute` identifies the real file
function M.prepare_buffer(is_virtual, git_root, revision, ref)
  if is_virtual then
    -- Virtual file: generate URL from the repo-relative path
    local virtual_url = virtual_file.create_url(git_root, revision, ref.relative)
    -- Check if buffer already exists (exact match to avoid prefix collisions)
    local existing_buf = bufnr_exact(virtual_url)

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
    -- Real file: use exact match for buffer lookup by absolute path
    local existing_buf = bufnr_exact(ref.absolute)
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
        target = ref.absolute,
        needs_edit = true,
      }
    end
  end
end

--- Display a real-file buffer in a window, re-syncing it with disk first.
---
--- Neovim runs a timestamp check whenever a buffer becomes visible. When the
--- file was deleted behind our back (branch switch, `git stash`, external `rm`)
--- that check emits `E211: File ... no longer available`; worse, it can surface
--- as an error out of `nvim_win_set_buf` and abort view construction halfway.
---
--- Running the check ourselves beforehand reloads the buffer when the file
--- really did change and clears the pending check either way, so the display
--- below stays quiet. `:checktime {buf}` is scoped to this buffer — a bare
--- `:checktime` walks every loaded buffer and would reload unrelated files.
--- `silent!` is required on top of `pcall`: for a buffer that is (or is about
--- to be) displayed, `:checktime` *reports* `E211` rather than raising it, so
--- `pcall` alone does not suppress it. A missing file has nothing to reload;
--- the deletion is picked up by the refresh that follows.
---@param win number Window handle
---@param bufnr number Buffer handle backed by a real file on disk
function M.show_real_file_buffer(win, bufnr)
  -- Only normal (file-backed) buffers are timestamp-checked by Neovim; scratch
  -- and codediff:// buffers are skipped, so don't bother them.
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" then
    pcall(vim.cmd, "silent! checktime " .. bufnr)
  end
  vim.api.nvim_win_set_buf(win, bufnr)
end

--- Load a real file into a buffer and display it in `win`.
---
--- Uses `:edit` rather than `bufload()` for a not-yet-loaded buffer on purpose:
--- a buffer loaded outside of any window and then displayed comes back marked
--- `'modified'`, which makes Neovim refuse to ever reload it from disk (W12).
---
--- When the buffer already exists it is reused as-is: `bufadd` resolves
--- `target` to the exact buffer Neovim would pick even when the path is spelled
--- differently (a symlinked directory such as macOS `/tmp`, a `./` segment),
--- which is precisely the case where `:edit` would fail with `E211` for a file
--- that has since been deleted.
---@param win number Window handle
---@param target string Absolute path of the file to load
---@return number bufnr
function M.open_real_file(win, target)
  local bufnr = vim.fn.bufadd(target)
  if vim.api.nvim_buf_is_loaded(bufnr) then
    M.show_real_file_buffer(win, bufnr)
    return bufnr
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  return vim.api.nvim_get_current_buf()
end

-- Replace generated content without changing the buffer's editing permissions.
function M.set_lines(buf, lines)
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    return
  end
  local modifiable, readonly = vim.bo[buf].modifiable, vim.bo[buf].readonly
  vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = modifiable, readonly
end

-- Install a resolved input in the existing pane, without reopening the view.
function M.update_content(session, side, input, lines)
  local buf = session[side .. "_bufnr"]
  if not input.path or input.path.absolute == "" then
    return
  end
  if not M.is_virtual_revision(input.revision) then
    if vim.bo[buf].buftype ~= "" then
      M.set_lines(buf, lines)
    end
    return
  end
  if input.resolved ~= session[side .. "_revision"] then
    local name = virtual_file.create_url(session.git_root, input.resolved, input.path.relative)
    local existing = bufnr_exact(name)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      buf = existing
    else
      buf = vim.api.nvim_create_buf(false, true)
      if existing == -1 then
        vim.api.nvim_buf_set_name(buf, name)
      end
      vim.bo[buf].buftype = "nowrite"
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
    end
    session[side .. "_bufnr"] = buf
    local win = session[side .. "_win"]
    local hidden = side == "original" and session.layout == "inline" and session.single_side ~= "original"
    if win and vim.api.nvim_win_is_valid(win) and not hidden then
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].bufhidden = "wipe"
    end
  end
  virtual_file.set_content(buf, lines, input.path.relative)
  session[side .. "_revision"] = input.resolved
end

return M
