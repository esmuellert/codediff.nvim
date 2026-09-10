-- Auto-refresh mechanism for diff views
-- Watches buffer changes (internal and external) and triggers diff recomputation
local M = {}

local diff = require("codediff.core.diff")
local core = require("codediff.ui.core")

-- Throttle delay in milliseconds
local THROTTLE_DELAY_MS = 200

-- Track watched buffers for auto-refresh
-- Structure: { bufnr = { timer } }
-- Buffer pair info is retrieved from lifecycle
local watched_buffers = {}

-- Cancel pending timer for a buffer
local function cancel_timer(bufnr)
  local watcher = watched_buffers[bufnr]
  if watcher and watcher.timer then
    vim.fn.timer_stop(watcher.timer)
    watcher.timer = nil
  end
end

-- Perform diff computation and update decorations
-- @param bufnr number: Buffer to update
-- @param skip_watcher_check boolean: If true, don't require buffer to be in watched_buffers
local function do_diff_update(bufnr, skip_watcher_check)
  local watcher = watched_buffers[bufnr]

  -- Check if buffer is being watched (unless skipped for manual trigger)
  if not skip_watcher_check and not watcher then
    return
  end

  -- Clear timer reference if watcher exists
  if watcher then
    watcher.timer = nil
  end

  -- Validate buffers still exist
  if not vim.api.nvim_buf_is_valid(bufnr) then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  -- Get buffer pair from lifecycle
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  if not tabpage then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
  if not original_bufnr or not modified_bufnr then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  if not vim.api.nvim_buf_is_valid(original_bufnr) or not vim.api.nvim_buf_is_valid(modified_bufnr) then
    if watcher then
      watched_buffers[bufnr] = nil
    end
    return
  end

  -- Get fresh buffer content
  local original_lines = vim.api.nvim_buf_get_lines(original_bufnr, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(modified_bufnr, 0, -1, false)

  -- Async diff computation
  vim.schedule(function()
    -- Double-check buffer validity after schedule
    if not vim.api.nvim_buf_is_valid(original_bufnr) or not vim.api.nvim_buf_is_valid(modified_bufnr) then
      if watched_buffers[bufnr] then
        watched_buffers[bufnr] = nil
      end
      return
    end

    -- Compute diff
    local config = require("codediff.config")
    local diff_options = {
      max_computation_time_ms = config.options.diff.max_computation_time_ms,
      ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
      compute_moves = config.options.diff.compute_moves,
    }
    local lines_diff = diff.compute_diff(original_lines, modified_lines, diff_options)
    if not lines_diff then
      return
    end

    -- Update stored diff result in lifecycle (critical for hunk navigation and do/dp)
    lifecycle.update_diff_result(tabpage, lines_diff)

    -- Refresh compact mode folds if active
    require("codediff.ui.view.compact").refresh(tabpage)

    -- Check if the session still owns the tab after the asynchronous diff.
    local session = lifecycle.get_session(tabpage)
    if not session then
      return
    end
    if session.layout == "inline" then
      local inline_mod = require("codediff.ui.inline")
      inline_mod.render_inline_diff(modified_bufnr, lines_diff, original_lines, modified_lines)
      return
    end

    -- Side-by-side mode: Update decorations on both buffers
    core.render_diff(original_bufnr, modified_bufnr, original_lines, modified_lines, lines_diff)

    -- Re-sync scrollbind after filler changes. Use the session's windows rather
    -- than searching by buffer, because a duplicated pane may show the same
    -- buffer without belonging to the diff.
    local original_win = session.original_win
    local modified_win = session.modified_win
    local _, result_win = lifecycle.get_result(tabpage)

    if original_win and modified_win and original_win ~= modified_win and vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win) then
      local current_win = vim.api.nvim_get_current_win()
      if current_win == original_win or current_win == modified_win or current_win == result_win then
        local other_win = current_win == original_win and modified_win or original_win

        local saved_view = vim.fn.winsaveview()
        vim.api.nvim_set_current_win(other_win)
        local other_saved_view = vim.fn.winsaveview()
        local result_saved_view
        if result_win then
          vim.api.nvim_set_current_win(result_win)
          result_saved_view = vim.fn.winsaveview()
        end
        vim.api.nvim_set_current_win(current_win)

        vim.api.nvim_win_set_cursor(original_win, { 1, 0 })
        vim.api.nvim_win_set_cursor(modified_win, { 1, 0 })
        if result_win then
          vim.api.nvim_win_set_cursor(result_win, { 1, 0 })
        end

        vim.wo[original_win].scrollbind = false
        vim.wo[modified_win].scrollbind = false
        if result_win then
          vim.wo[result_win].scrollbind = false
        end
        vim.wo[original_win].scrollbind = true
        vim.wo[modified_win].scrollbind = true
        if result_win then
          vim.wo[result_win].scrollbind = true
        end

        vim.api.nvim_set_current_win(other_win)
        vim.fn.winrestview(other_saved_view)
        if result_win and result_saved_view then
          vim.api.nvim_set_current_win(result_win)
          vim.fn.winrestview(result_saved_view)
        end
        vim.api.nvim_set_current_win(current_win)
        vim.fn.winrestview(saved_view)
      end
    end
  end)
end

-- Trigger diff update with throttling
local function trigger_diff_update(bufnr)
  local watcher = watched_buffers[bufnr]
  if not watcher then
    return
  end

  -- Cancel existing timer
  cancel_timer(bufnr)

  -- Start new timer
  watcher.timer = vim.fn.timer_start(THROTTLE_DELAY_MS, function()
    do_diff_update(bufnr)
  end)
end

-- Setup auto-refresh for a buffer
-- @param bufnr number: Buffer to watch for changes
-- Note: Buffer pair info is retrieved from lifecycle when needed
function M.enable(bufnr)
  -- Store watcher info (just timer)
  watched_buffers[bufnr] = {
    timer = nil,
  }

  -- Setup autocmds for this buffer
  local buf_augroup = vim.api.nvim_create_augroup("codediff_auto_refresh_" .. bufnr, { clear = true })

  -- Internal changes (user editing)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  -- External changes (file modified on disk)
  vim.api.nvim_create_autocmd({ "FileChangedShellPost", "FocusGained" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_diff_update(bufnr)
    end,
  })

  -- Cleanup on buffer delete/wipe
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
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
  watched_buffers[bufnr] = nil

  -- Clear autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_auto_refresh_" .. bufnr)
end

-- Track result buffer timers only (base_lines stored in lifecycle)
local result_timers = {}

-- Perform diff update for result buffer against BASE
local function do_result_diff_update(bufnr)
  -- Clear timer reference
  result_timers[bufnr] = nil

  -- Validate buffer still exists
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Get base_lines from lifecycle
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  if not tabpage then
    return
  end

  local base_lines = lifecycle.get_result_base_lines(tabpage)
  if not base_lines then
    return
  end

  -- Get current result buffer content
  local result_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Compute diff: BASE vs result (result shows what was added/changed from BASE)
  local config = require("codediff.config")
  local diff_options = {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  }
  local lines_diff = diff.compute_diff(base_lines, result_lines, diff_options)
  if not lines_diff then
    return
  end

  -- Render highlights on result buffer only (modified side = insertions shown as green)
  core.render_single_buffer(bufnr, lines_diff, "modified")
end

-- Trigger throttled diff update for result buffer
local function trigger_result_diff_update(bufnr)
  -- Cancel existing timer
  if result_timers[bufnr] then
    vim.fn.timer_stop(result_timers[bufnr])
  end

  -- Start new throttled timer
  result_timers[bufnr] = vim.fn.timer_start(THROTTLE_DELAY_MS, function()
    vim.schedule(function()
      do_result_diff_update(bufnr)
    end)
  end)
end

-- Enable auto-refresh for result buffer (diffs against BASE stored in lifecycle)
function M.enable_for_result(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Disable if already enabled
  M.disable_result(bufnr)

  -- Setup autocmds for this buffer
  local buf_augroup = vim.api.nvim_create_augroup("codediff_result_refresh_" .. bufnr, { clear = true })

  -- Internal changes (user editing)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      trigger_result_diff_update(bufnr)
    end,
  })

  -- Cleanup on buffer delete/wipe
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = buf_augroup,
    buffer = bufnr,
    callback = function()
      M.disable_result(bufnr)
    end,
  })

  -- Initial render
  vim.schedule(function()
    do_result_diff_update(bufnr)
  end)
end

-- Disable auto-refresh for result buffer
function M.disable_result(bufnr)
  if result_timers[bufnr] then
    vim.fn.timer_stop(result_timers[bufnr])
    result_timers[bufnr] = nil
  end

  -- Clear autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, "codediff_result_refresh_" .. bufnr)
end

-- Immediately refresh result buffer diff (call after programmatic changes)
function M.refresh_result_now(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Cancel pending timer if any
  if result_timers[bufnr] then
    vim.fn.timer_stop(result_timers[bufnr])
    result_timers[bufnr] = nil
  end
  do_result_diff_update(bufnr)
end

-- Sync mutable revision buffers (:0-:3) with current git index content.
-- Called when repository state changes. Only writes if content actually changed,
-- which triggers TextChanged → auto_refresh recomputes diff automatically.
-- @param tabpage number: Tabpage whose session buffers to sync
-- @param done function|nil: Called after every mutable target settles
function M.sync_mutable_buffers(tabpage, done)
  done = done or function() end
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if not session then
    done()
    return
  end

  local function is_mutable(revision)
    return revision and revision:match("^:[0-3]$")
  end

  local targets = {}
  local function add_target(side, bufnr, revision, ref)
    local path = ref and ref.relative
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and is_mutable(revision) and path and path ~= "" then
      targets[#targets + 1] = {
        side = side,
        bufnr = bufnr,
        revision = revision,
        path = path,
      }
    end
  end
  add_target("original", session.original_bufnr, session.original_revision, session.original)
  add_target("modified", session.modified_bufnr, session.modified_revision, session.modified)

  if #targets == 0 then
    done()
    return
  end

  local remaining = #targets
  local completed = false
  local function finish_target()
    remaining = remaining - 1
    if remaining == 0 and not completed then
      completed = true
      done()
    end
  end

  local function still_current(target)
    local current = lifecycle.get_session(tabpage)
    if current ~= session then
      return false
    end
    local ref = current[target.side]
    local bufnr = current[target.side .. "_bufnr"]
    local revision = current[target.side .. "_revision"]
    return bufnr == target.bufnr and revision == target.revision and ref and ref.relative == target.path
  end

  local function lines_equal(bufnr, lines)
    local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #current ~= #lines then
      return false
    end
    for i = 1, #lines do
      if current[i] ~= lines[i] then
        return false
      end
    end
    return true
  end

  local git = require("codediff.core.git")
  for _, target in ipairs(targets) do
    git.get_file_content(target.revision, session.git_root, target.path, function(err, lines)
      vim.schedule(function()
        local can_update = not err and lines and vim.api.nvim_buf_is_valid(target.bufnr) and still_current(target)
        if can_update and not lines_equal(target.bufnr, lines) then
          local was_modifiable = vim.bo[target.bufnr].modifiable
          local was_readonly = vim.bo[target.bufnr].readonly
          vim.bo[target.bufnr].readonly = false
          vim.bo[target.bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(target.bufnr, 0, -1, false, lines)
          vim.bo[target.bufnr].modifiable = was_modifiable
          vim.bo[target.bufnr].readonly = was_readonly
          -- TextChanged doesn't fire on nowrite/nofile buffers, trigger explicitly
          M.trigger(target.bufnr)
        end
        finish_target()
      end)
    end)
  end
end

-- Cleanup all watched buffers
function M.cleanup_all()
  for bufnr, _ in pairs(watched_buffers) do
    M.disable(bufnr)
  end
  for bufnr, _ in pairs(result_timers) do
    M.disable_result(bufnr)
  end
end

-- Manually trigger a diff refresh for a buffer (e.g., after programmatic changes)
-- Works for any buffer in a diff session, even if auto-refresh is not enabled for it
-- @param bufnr number: Buffer that was changed
function M.trigger(bufnr)
  if watched_buffers[bufnr] then
    -- Buffer has auto-refresh enabled, use throttled update
    trigger_diff_update(bufnr)
  else
    -- Buffer might not have auto-refresh enabled (e.g., virtual buffer)
    -- Do immediate update, skipping watcher check
    do_diff_update(bufnr, true)
  end
end

return M
