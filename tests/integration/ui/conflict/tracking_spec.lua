local conflict = require('codediff.ui.conflict')
local lifecycle = require('codediff.ui.lifecycle')
local assert = require('luassert')

describe("Conflict Actions with Extmark Tracking", function()
  local tabpage
  local result_bufnr
  local conflict_blocks

  before_each(function()
    tabpage = 1
    -- Create a result buffer with some initial content (simulating BASE)
    -- Lines: 1, 2, 3 (conflict start), 4 (conflict end), 5
    result_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(result_bufnr, 0, -1, false, {
      "Line 1",
      "Line 2",
      "Line 3 (Base Conflict)",
      "Line 4 (Base Conflict)",
      "Line 5"
    })

    -- Define a conflict block covering lines 3-4 (indices 2-4)
    conflict_blocks = {
      {
        base_range = { start_line = 3, end_line = 5 }, -- 1-based, inclusive start, exclusive end? No, usually 1-based logic in Lua
        -- Let's check logic: apply_to_result uses: 
        -- vim.api.nvim_buf_get_lines(result_bufnr, start_line - 1, end_line - 1, false)
        -- So for lines 3 and 4, start_line=3, end_line=5
        
        output1_range = { start_line = 1, end_line = 2 }, -- Dummy range for incoming
        output2_range = { start_line = 1, end_line = 2 }, -- Dummy range for current
      }
    }

    -- Mock session
    local session = {
      result_bufnr = result_bufnr,
      conflict_blocks = conflict_blocks,
      original_bufnr = 998, -- Dummy
      modified_bufnr = 999, -- Dummy
      result_base_lines = {
        "Line 1", "Line 2", "Line 3 (Base Conflict)", "Line 4 (Base Conflict)", "Line 5"
      }
    }
    
    -- Mock lifecycle.get_session
    lifecycle.get_session = function(tp)
      if tp == tabpage then return session end
      return nil
    end
    
    -- Initialize tracking
    conflict.initialize_tracking(result_bufnr, conflict_blocks)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(result_bufnr) then
      vim.api.nvim_buf_delete(result_bufnr, { force = true })
    end
  end)

  it("should track conflict block after inserting lines above", function()
    -- 1. Insert 2 lines at the top of the result buffer
    vim.api.nvim_buf_set_lines(result_bufnr, 0, 0, false, { "New Line A", "New Line B" })
    
    -- Buffer is now:
    -- New Line A
    -- New Line B
    -- Line 1
    -- Line 2
    -- Line 3 (Base Conflict)  <-- Should be tracked here (index 4)
    -- Line 4 (Base Conflict)
    -- Line 5
    
    -- 2. Verify Extmark moved
    -- We can't easily check internal ID, but we can try to apply a change and see where it goes
    
    -- Better: Set up cursor and buffers so `accept_incoming` works.
    local original_bufnr = vim.api.nvim_create_buf(false, true) -- Create real dummy buffer
    vim.api.nvim_buf_set_name(original_bufnr, "Original")
    vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, { "Incoming Content" })
    
    -- Set up session to point to this buffer
    local session = lifecycle.get_session(tabpage)
    session.original_bufnr = original_bufnr
    
    -- Set current buffer to original_bufnr and cursor to line 1 (matching output1_range)
    vim.api.nvim_set_current_buf(original_bufnr)
    vim.api.nvim_win_set_cursor(0, {1, 0})
    
    -- 3. Execute Action
    conflict.accept_incoming(tabpage)
    
    -- 4. Verify Result
    local result_lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    
    -- Expected:
    -- New Line A
    -- New Line B
    -- Line 1
    -- Line 2
    -- Incoming Content   <-- Replaced lines 3-4 (now 5-6)
    -- Line 5
    
    assert.are.equal("New Line A", result_lines[1])
    assert.are.equal("New Line B", result_lines[2])
    assert.are.equal("Line 1", result_lines[3])
    assert.are.equal("Line 2", result_lines[4])
    assert.are.equal("Incoming Content", result_lines[5])
    assert.are.equal("Line 5", result_lines[6])
    assert.are.equal(6, #result_lines)
  end)

  it("should not re-apply change if already resolved", function()
    local original_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(original_bufnr, "Original2")
    vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, { "Incoming Content" })
    
    local session = lifecycle.get_session(tabpage)
    session.original_bufnr = original_bufnr
    
    vim.api.nvim_set_current_buf(original_bufnr)
    vim.api.nvim_win_set_cursor(0, {1, 0})
    
    -- First Apply
    local success1 = conflict.accept_incoming(tabpage)
    assert.is_true(success1)
    
    -- Verify first application
    local result_lines_1 = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Incoming Content", result_lines_1[3]) -- Replaced line 3
    
    -- Second Apply (should fail or do nothing)
    -- Extmark should be gone now
    local success2 = conflict.accept_incoming(tabpage)
    assert.is_false(success2)
  end)

  it("should restore conflict state on undo", function()
    local original_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(original_bufnr, "Original3")
    vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, { "Incoming Content" })
    
    local session = lifecycle.get_session(tabpage)
    session.original_bufnr = original_bufnr
    
    -- Use result buffer as current buffer to allow undo
    vim.api.nvim_set_current_buf(result_bufnr)
    -- But we need to switch back to source buffer to trigger action
    vim.api.nvim_set_current_buf(original_bufnr)
    vim.api.nvim_win_set_cursor(0, {1, 0})
    
    -- 1. Apply Change
    local success1 = conflict.accept_incoming(tabpage)
    assert.is_true(success1)
    
    -- 2. Undo in Result Buffer
    vim.api.nvim_set_current_buf(result_bufnr)
    vim.cmd("undo")
    
    -- Verify content reverted
    local result_lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Line 3 (Base Conflict)", result_lines[3])
    
    -- 3. Apply Again (Should succeed because Undo restored Extmark)
    vim.api.nvim_set_current_buf(original_bufnr)
    local success2 = conflict.accept_incoming(tabpage)
    assert.is_true(success2)
    
    -- Verify content applied again
    local result_lines_2 = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Incoming Content", result_lines_2[3])
  end)

  it("should allow discard (reset to base) even if conflict is resolved", function()
    local original_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(original_bufnr, "Original4")
    vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, { "Incoming Content" })
    
    local session = lifecycle.get_session(tabpage)
    session.original_bufnr = original_bufnr
    
    vim.api.nvim_set_current_buf(original_bufnr)
    vim.api.nvim_win_set_cursor(0, {1, 0})
    
    -- 1. Apply Incoming (Resolves it)
    local success1 = conflict.accept_incoming(tabpage)
    assert.is_true(success1)
    
    local result_lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Incoming Content", result_lines[3])
    
    -- 2. Discard (Should work and reset to Base)
    local success2 = conflict.discard(tabpage)
    assert.is_true(success2)
    
    local result_lines_2 = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Line 3 (Base Conflict)", result_lines_2[3])
    
    -- 3. Accept Incoming AGAIN (Should work because Discard made it Active again)
    local success3 = conflict.accept_incoming(tabpage)
    assert.is_true(success3)
    
    local result_lines_3 = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
    assert.are.equal("Incoming Content", result_lines_3[3])
  end)
end)
