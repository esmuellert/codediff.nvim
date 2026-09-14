-- File-level staging actions driven from the explorer or the diff panes.

local M = {}

local lifecycle = require("codediff.ui.lifecycle")

function M.toggle_stage(ctx)
  local current_buf = vim.api.nvim_get_current_buf()
  local explorer = lifecycle.get_panel_view(ctx.tabpage)
  local session = lifecycle.get_session(ctx.tabpage)

  if not session then
    return
  end

  -- Only available in explorer mode with git
  if not ctx.is_explorer_mode then
    vim.notify("Stage/unstage only available in explorer mode", vim.log.levels.WARN)
    return
  end

  if not explorer or not explorer.data.git_root then
    vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
    return
  end

  -- Case 1: Cursor in explorer buffer
  if explorer.bufnr and current_buf == explorer.bufnr then
    -- Delegate to explorer action (handles files and directories)
    local explorer_module = require("codediff.ui.explorer")
    explorer_module.toggle_stage_entry(explorer, explorer.tree)
    return
  end

  -- Case 2: Cursor in diff buffers (original or modified)
  if current_buf == ctx.original_bufnr or current_buf == ctx.modified_bufnr then
    local file_path = explorer.data.current_file_path
    local group = explorer.data.current_file_group

    -- Guard: must have a current file selected
    if not file_path then
      vim.notify("No file selected", vim.log.levels.WARN)
      return
    end

    -- Guard: file must be stageable
    if not group or (group ~= "staged" and group ~= "unstaged" and group ~= "conflicts") then
      vim.notify("Current file cannot be staged/unstaged", vim.log.levels.WARN)
      return
    end

    local explorer_module = require("codediff.ui.explorer")
    explorer_module.toggle_stage_file(explorer.data.git_root, file_path, group)
    return
  end

  -- Case 3: Other buffers (history, etc.) - do nothing silently
end

function M.toggle_staged_view(ctx)
  local explorer = lifecycle.get_panel_view(ctx.tabpage)
  if not ctx.is_explorer_mode or not explorer then
    vim.notify("Toggle staged view only available in explorer mode", vim.log.levels.WARN)
    return
  end
  local explorer_module = require("codediff.ui.explorer")
  explorer_module.toggle_staged_view(explorer)
end

return M
