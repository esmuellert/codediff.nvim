-- Hunk-level actions: locate the hunk under the cursor, and stage, unstage or
-- discard it.
--
-- Every action takes the session context built by ui/view/keymaps.lua rather
-- than closing over buffers and layout flags, so a mapping installed for one
-- diff cannot act on a stale buffer after a file switch or layout change.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.refresh")

function M.find_hunk_at_cursor(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.stored_diff_result then
    return nil, nil
  end
  local diff_result = session.stored_diff_result
  if not diff_result.changes or #diff_result.changes == 0 then
    return nil, nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  -- In inline mode, always use modified ranges
  local is_original = not ctx.is_inline and current_buf == ctx.original_bufnr
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1]

  for i, mapping in ipairs(diff_result.changes) do
    local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
    local end_line = is_original and mapping.original.end_line or mapping.modified.end_line
    -- Check if cursor is within this hunk (end_line is exclusive)
    if current_line >= start_line and current_line < end_line then
      return mapping, i
    end
    -- Also match if it's a deletion (empty range) and cursor is at start
    if start_line == end_line and current_line == start_line then
      return mapping, i
    end
  end
  return nil, nil
end

local function build_hunk_patch(file_path, orig_lines, mod_lines, orig_start, mod_start)
  local orig_count = #orig_lines
  local mod_count = #mod_lines

  -- For pure insertions with 0 original lines, git expects start to be
  -- the line AFTER which content is inserted (0 if at very start)
  local hdr_orig_start = orig_count == 0 and (orig_start > 0 and orig_start - 1 or 0) or orig_start
  local hdr_mod_start = mod_count == 0 and (mod_start > 0 and mod_start - 1 or 0) or mod_start

  local parts = {
    string.format("--- a/%s", file_path),
    string.format("+++ b/%s", file_path),
    string.format("@@ -%d,%d +%d,%d @@", hdr_orig_start, orig_count, hdr_mod_start, mod_count),
  }

  for _, line in ipairs(orig_lines) do
    table.insert(parts, "-" .. line)
  end
  for _, line in ipairs(mod_lines) do
    table.insert(parts, "+" .. line)
  end

  -- Patch must end with a newline
  return table.concat(parts, "\n") .. "\n"
end

function M.stage_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow staging from unstaged views (working tree changes)
  if session.modified_revision ~= nil then
    vim.notify("Stage only works on unstaged changes", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  -- Get the file path relative to git root
  local file_path = (session.original.relative ~= "" and session.original.relative) or session.modified.relative
  if not file_path or file_path == "" then
    vim.notify("No file path for staging", vim.log.levels.WARN)
    return
  end

  local stage_orig_buf, stage_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not stage_orig_buf or not stage_mod_buf or not vim.api.nvim_buf_is_valid(stage_orig_buf) or not vim.api.nvim_buf_is_valid(stage_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Read lines from both buffers for this hunk
  local orig_lines = vim.api.nvim_buf_get_lines(stage_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)
  local mod_lines = vim.api.nvim_buf_get_lines(stage_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false)

  local patch = build_hunk_patch(file_path, orig_lines, mod_lines, hunk.original.start_line, hunk.modified.start_line)

  local git = require("codediff.core.git")
  git.apply_patch(session.git_root, patch, false, function(err)
    if err then
      vim.notify("Failed to stage hunk: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("Staged hunk %d", hunk_idx), vim.log.levels.INFO)
  end)
end

function M.unstage_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow unstaging from staged views
  if session.modified_revision ~= ":0" then
    vim.notify("Unstage only works on staged changes", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  local file_path = (session.original.relative ~= "" and session.original.relative) or session.modified.relative
  if not file_path or file_path == "" then
    vim.notify("No file path for unstaging", vim.log.levels.WARN)
    return
  end

  local unstage_orig_buf, unstage_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not unstage_orig_buf or not unstage_mod_buf or not vim.api.nvim_buf_is_valid(unstage_orig_buf) or not vim.api.nvim_buf_is_valid(unstage_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Read lines from both buffers for this hunk
  local orig_lines = vim.api.nvim_buf_get_lines(unstage_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)
  local mod_lines = vim.api.nvim_buf_get_lines(unstage_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false)

  local patch = build_hunk_patch(file_path, orig_lines, mod_lines, hunk.original.start_line, hunk.modified.start_line)

  local git = require("codediff.core.git")
  git.apply_patch(session.git_root, patch, true, function(err)
    if err then
      vim.notify("Failed to unstage hunk: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("Unstaged hunk %d", hunk_idx), vim.log.levels.INFO)
  end)
end

function M.discard_hunk(ctx)
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return
  end

  -- Only allow discarding in unstaged views (working tree changes)
  if session.modified_revision ~= nil then
    vim.notify("Discard only works on unstaged changes (working tree)", vim.log.levels.WARN)
    return
  end

  local hunk, hunk_idx = M.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  -- Prompt for confirmation before discarding (destructive operation)
  local prompt = string.format("Discard hunk %d?", hunk_idx)
  local choice = vim.fn.confirm(prompt, "&Discard\n&Cancel", 2, "Warning")
  if choice ~= 1 then
    return
  end

  local discard_orig_buf, discard_mod_buf = lifecycle.get_buffers(ctx.tabpage)
  if not discard_orig_buf or not discard_mod_buf or not vim.api.nvim_buf_is_valid(discard_orig_buf) or not vim.api.nvim_buf_is_valid(discard_mod_buf) then
    vim.notify("Diff buffers are no longer available", vim.log.levels.WARN)
    return
  end

  -- Replace the modified hunk range with the original lines. Every other line
  -- (including unrelated unsaved edits) stays as-is in the live buffer, so the
  -- discarded region falls back to original content and nothing else changes.
  local orig_lines = vim.api.nvim_buf_get_lines(discard_orig_buf, hunk.original.start_line - 1, hunk.original.end_line - 1, false)

  local was_modifiable = vim.bo[discard_mod_buf].modifiable
  local was_readonly = vim.bo[discard_mod_buf].readonly

  local ok, edit_err = pcall(function()
    vim.bo[discard_mod_buf].readonly = false
    vim.bo[discard_mod_buf].modifiable = true
    vim.api.nvim_buf_set_lines(discard_mod_buf, hunk.modified.start_line - 1, hunk.modified.end_line - 1, false, orig_lines)
    -- Persist through the native write path so 'fileformat', 'fileencoding'
    -- and 'endofline' are honored. 'noautocmd' keeps format-on-save (and
    -- similar BufWritePre hooks) from rewriting lines outside the hunk.
    vim.api.nvim_buf_call(discard_mod_buf, function()
      vim.cmd("silent noautocmd write!")
    end)
  end)

  if vim.api.nvim_buf_is_valid(discard_mod_buf) then
    vim.bo[discard_mod_buf].modifiable = was_modifiable
    vim.bo[discard_mod_buf].readonly = was_readonly
  end

  if not ok then
    vim.notify("Failed to discard hunk: " .. tostring(edit_err), vim.log.levels.ERROR)
    return
  end

  refresh.buffer_changed(discard_mod_buf)
  vim.notify(string.format("Discarded hunk %d", hunk_idx), vim.log.levels.INFO)
end

--- Visually select the hunk under the cursor, for the `ih` textobject.
--- @param ctx CodeDiffActionContext
function M.select_hunk(ctx)
  local mapping = M.find_hunk_at_cursor(ctx)
  if not mapping then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local is_original = current_buf == ctx.original_bufnr
  local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
  local end_line = is_original and mapping.original.end_line or mapping.modified.end_line

  -- end_line is exclusive, and empty ranges (deletions) can't be selected
  if start_line >= end_line then
    return
  end

  vim.cmd("normal! " .. start_line .. "GV" .. (end_line - 1) .. "G")
end

return M
