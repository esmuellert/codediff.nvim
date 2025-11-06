-- Auto-refresh mechanism for diff views
-- Watches buffer changes (internal and external) and triggers diff recomputation
local M = {}

local diff = require("vscode-diff.diff")
local core = require("vscode-diff.render.core")

-- Throttle delay in milliseconds
local THROTTLE_DELAY_MS = 200

-- Track active auto-refresh sessions
-- Structure: { bufnr = { timer, left_bufnr, right_bufnr, original_lines, modified_lines } }
local active_sessions = {}

-- Cancel pending timer for a buffer
local function cancel_timer(bufnr)
  local session = active_sessions[bufnr]
  if session and session.timer then
    vim.fn.timer_stop(session.timer)
    session.timer = nil
  end
end

-- Perform diff computation and update decorations
local function do_diff_update(bufnr)
  local session = active_sessions[bufnr]
  if not session then
    return
  end

  -- Clear timer reference
  session.timer = nil

  -- Validate buffers still exist
  if not vim.api.nvim_buf_is_valid(bufnr) then
    active_sessions[bufnr] = nil
    return
  end
  
  if not vim.api.nvim_buf_is_valid(session.left_bufnr) or not vim.api.nvim_buf_is_valid(session.right_bufnr) then
    active_sessions[bufnr] = nil
    return
  end

  -- Get fresh buffer content
  local left_lines = vim.api.nvim_buf_get_lines(session.left_bufnr, 0, -1, false)
  local right_lines = vim.api.nvim_buf_get_lines(session.right_bufnr, 0, -1, false)

  -- Async diff computation
  vim.schedule(function()
    -- Check if session was cleaned up while scheduled
    if not active_sessions[bufnr] then
      return
    end
    
    -- Double-check buffer validity after schedule
    if not vim.api.nvim_buf_is_valid(session.left_bufnr) or not vim.api.nvim_buf_is_valid(session.right_bufnr) then
      active_sessions[bufnr] = nil
      return
    end

    -- Compute diff
    local lines_diff = diff.compute_diff(left_lines, right_lines)
    if not lines_diff then
      return
    end

    -- Update decorations on both buffers
    core.render_diff(session.left_bufnr, session.right_bufnr, left_lines, right_lines, lines_diff)
    
    -- Re-sync scrollbind after filler changes
    -- This ensures both windows stay aligned even if fillers were added/removed
    local left_win, right_win = nil, nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == session.left_bufnr then
        left_win = win
      elseif buf == session.right_bufnr then
        right_win = win
      end
    end
    
    if left_win and right_win then
      local current_win = vim.api.nvim_get_current_win()
      
      -- Only resync if user is in one of the diff windows
      if current_win == left_win or current_win == right_win then
        -- Step 1: Remember cursor position after render
        local saved_line = vim.api.nvim_win_get_cursor(current_win)[1]
        
        -- Step 2: Reset both windows to line 1 (baseline)
        vim.api.nvim_win_set_cursor(left_win, {1, 0})
        vim.api.nvim_win_set_cursor(right_win, {1, 0})
        
        -- Step 3: Re-establish scrollbind (reset sync state)
        vim.wo[left_win].scrollbind = false
        vim.wo[right_win].scrollbind = false
        vim.wo[left_win].scrollbind = true
        vim.wo[right_win].scrollbind = true
        
        -- Step 4: Set both to saved line (like initial creation)
        pcall(vim.api.nvim_win_set_cursor, left_win, {saved_line, 0})
        pcall(vim.api.nvim_win_set_cursor, right_win, {saved_line, 0})
      end
    end
  end)
end

-- Trigger diff update with throttling
local function trigger_diff_update(bufnr)
  local session = active_sessions[bufnr]
  if not session then
    return
  end

  -- Cancel existing timer
  cancel_timer(bufnr)

  -- Start new timer
  session.timer = vim.fn.timer_start(THROTTLE_DELAY_MS, function()
    do_diff_update(bufnr)
  end)
end

-- Setup auto-refresh for a buffer
-- @param bufnr number: Buffer to watch for changes
-- @param left_bufnr number: Left buffer in diff view
-- @param right_bufnr number: Right buffer in diff view
function M.enable(bufnr, left_bufnr, right_bufnr)
  -- Store session info
  active_sessions[bufnr] = {
    timer = nil,
    left_bufnr = left_bufnr,
    right_bufnr = right_bufnr,
  }

  -- Setup autocmds for this buffer
  local buf_augroup = vim.api.nvim_create_augroup('vscode_diff_auto_refresh_' .. bufnr, { clear = true })

  -- Internal changes (user editing)
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  -- External changes (file modified on disk)
  vim.api.nvim_create_autocmd({ 'FileChangedShellPost', 'FocusGained' }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  -- Cleanup on buffer delete/wipe
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })
end

-- Disable auto-refresh for a buffer
function M.disable(bufnr)
  cancel_timer(bufnr)
  active_sessions[bufnr] = nil

  -- Clear autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, 'vscode_diff_auto_refresh_' .. bufnr)
end

-- Cleanup all active sessions
function M.cleanup_all()
  for bufnr, _ in pairs(active_sessions) do
    M.disable(bufnr)
  end
end

return M
