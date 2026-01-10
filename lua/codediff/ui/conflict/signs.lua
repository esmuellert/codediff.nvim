-- Conflict sign management for merge tool
-- Handles sign refresh and autocmd setup
local M = {}

local lifecycle = require("codediff.ui.lifecycle")

-- Will be injected by init.lua
local tracking = nil
M._set_tracking_module = function(t)
  tracking = t
end

--- Refresh all conflict signs based on current state (event-driven approach)
--- Called on TextChanged to keep signs in sync with actual buffer content
--- Also used for initial sign setup after initialize_tracking
--- @param session table The diff session
function M.refresh_all_conflict_signs(session)
  if not session or not session.conflict_blocks then
    return
  end

  local highlights = require("codediff.ui.highlights")
  local ns_conflict = highlights.ns_conflict

  -- Check if extmarks need re-initialization (e.g., after undo to original state)
  -- If any extmark is missing or invalid, re-initialize all tracking
  local needs_reinit = false
  for _, block in ipairs(session.conflict_blocks) do
    if not block.extmark_id then
      needs_reinit = true
      break
    end
    local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking.tracking_ns, block.extmark_id, { details = true })
    if not mark or #mark < 3 or not mark[3] then
      needs_reinit = true
      break
    end
    -- Check if extmark position is reasonable (not spanning entire buffer or starting at 0 when it shouldn't)
    local mark_start = mark[1]
    local mark_end = mark[3].end_row
    local expected_start = block.base_range.start_line - 1
    -- If extmark start moved to 0 but expected start is not 0, it's corrupted (common after undo/redo)
    if mark_start == 0 and expected_start > 0 then
      needs_reinit = true
      break
    end
  end

  if needs_reinit and session.result_bufnr and vim.api.nvim_buf_is_valid(session.result_bufnr) then
    tracking.initialize_tracking(session.result_bufnr, session.conflict_blocks)
  end

  -- Helper to set signs for a buffer range (for non-empty ranges)
  local function set_signs_for_range(bufnr, start_line, end_line, namespace, hl_group, is_active)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    if start_line == end_line then
      -- Empty range: show a top-aligned horizontal bar sign to indicate "something goes here"
      if start_line >= 0 and start_line < line_count then
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, { start_line, 0 }, { start_line, -1 }, {})
        for _, mark in ipairs(marks) do
          vim.api.nvim_buf_del_extmark(bufnr, namespace, mark[1])
        end
        vim.api.nvim_buf_set_extmark(bufnr, namespace, start_line, 0, {
          sign_text = "▔▔", -- Upper block - appears at top of line, like between two lines
          sign_hl_group = hl_group,
          priority = 50,
        })
      end
    else
      for line = start_line, end_line - 1 do
        if line >= 0 and line < line_count then
          local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, { line, 0 }, { line, -1 }, {})
          for _, mark in ipairs(marks) do
            vim.api.nvim_buf_del_extmark(bufnr, namespace, mark[1])
          end
          vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
            sign_text = "▌",
            sign_hl_group = hl_group,
            priority = 50,
          })
        end
      end
    end
  end

  -- Clear result buffer signs (they move with content, so clear and re-add)
  if session.result_bufnr and vim.api.nvim_buf_is_valid(session.result_bufnr) then
    vim.api.nvim_buf_clear_namespace(session.result_bufnr, tracking.result_signs_ns, 0, -1)
  end

  -- Update signs for each block based on is_block_active state
  for _, block in ipairs(session.conflict_blocks) do
    local is_active = tracking.is_block_active(session, block)

    -- Determine highlight groups for left/right/result based on accepted side
    local left_hl, right_hl, result_hl
    if is_active then
      -- Unresolved: all orange
      left_hl = "CodeDiffConflictSign"
      right_hl = "CodeDiffConflictSign"
      result_hl = "CodeDiffConflictSign"
    else
      -- Resolved: check which side was accepted
      local accepted = tracking.get_accepted_side(session, block)
      if accepted == "incoming" then
        left_hl = "CodeDiffConflictSignAccepted" -- Green (chosen)
        right_hl = "CodeDiffConflictSignRejected" -- Red (not chosen)
      elseif accepted == "current" then
        left_hl = "CodeDiffConflictSignRejected" -- Red (not chosen)
        right_hl = "CodeDiffConflictSignAccepted" -- Green (chosen)
      elseif accepted == "both" then
        left_hl = "CodeDiffConflictSignAccepted" -- Green (both chosen)
        right_hl = "CodeDiffConflictSignAccepted" -- Green (both chosen)
      else
        -- Manual edit or unknown - use gray
        left_hl = "CodeDiffConflictSignResolved"
        right_hl = "CodeDiffConflictSignResolved"
      end
      -- Result buffer always uses gray for resolved
      result_hl = "CodeDiffConflictSignResolved"
    end

    -- Update left buffer (incoming)
    local left_start = block.output1_range.start_line - 1
    local left_end = block.output1_range.end_line - 1
    set_signs_for_range(session.original_bufnr, left_start, left_end, ns_conflict, left_hl, is_active)

    -- Update right buffer (current)
    local right_start = block.output2_range.start_line - 1
    local right_end = block.output2_range.end_line - 1
    set_signs_for_range(session.modified_bufnr, right_start, right_end, ns_conflict, right_hl, is_active)

    -- Update result buffer (use tracked extmark position)
    if session.result_bufnr and vim.api.nvim_buf_is_valid(session.result_bufnr) and block.extmark_id then
      local mark = vim.api.nvim_buf_get_extmark_by_id(session.result_bufnr, tracking.tracking_ns, block.extmark_id, { details = true })
      if mark and #mark >= 3 then
        local result_start = mark[1]
        local result_end = mark[3].end_row
        local line_count = vim.api.nvim_buf_line_count(session.result_bufnr)

        if result_start == result_end then
          -- Empty conflict region: show a top-aligned horizontal bar sign
          if result_start >= 0 and result_start < line_count then
            vim.api.nvim_buf_set_extmark(session.result_bufnr, tracking.result_signs_ns, result_start, 0, {
              sign_text = "▔▔", -- Upper block - appears at top of line, like between two lines
              sign_hl_group = result_hl,
              priority = 50,
            })
          end
        else
          for line = result_start, result_end - 1 do
            if line >= 0 and line < line_count then
              vim.api.nvim_buf_set_extmark(session.result_bufnr, tracking.result_signs_ns, line, 0, {
                sign_text = "▌",
                sign_hl_group = result_hl,
                priority = 50,
              })
            end
          end
        end
      end
    end
  end
end

--- Setup autocmd to refresh signs when result buffer changes
--- @param tabpage number The tabpage ID
--- @param result_bufnr number The result buffer handle
function M.setup_sign_refresh_autocmd(tabpage, result_bufnr)
  if not result_bufnr or not vim.api.nvim_buf_is_valid(result_bufnr) then
    return
  end

  local group = vim.api.nvim_create_augroup("CodeDiffConflictSigns_" .. tabpage, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = result_bufnr,
    callback = function()
      local session = lifecycle.get_session(tabpage)
      if session then
        M.refresh_all_conflict_signs(session)
      end
    end,
  })
end

return M
