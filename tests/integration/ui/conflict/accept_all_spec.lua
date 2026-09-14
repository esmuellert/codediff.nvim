local conflict = require('codediff.ui.conflict')
local lifecycle = require('codediff.ui.lifecycle')
local assert = require('luassert')

describe("Conflict Accept All Actions", function()
  local tabpage
  local result_bufnr
  local original_bufnr
  local modified_bufnr
  local conflict_blocks

  before_each(function()
    tabpage = 1

    -- Create result buffer with 3 conflict regions
    -- Lines 3-4, 7-8, 11-12 are conflicts
    result_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(result_bufnr, 0, -1, false, {
      "Line 1",                    -- 1
      "Line 2",                    -- 2
      "Base Conflict 1a",          -- 3  (conflict 1)
      "Base Conflict 1b",          -- 4
      "Line 5",                    -- 5
      "Line 6",                    -- 6
      "Base Conflict 2a",          -- 7  (conflict 2)
      "Base Conflict 2b",          -- 8
      "Line 9",                    -- 9
      "Line 10",                   -- 10
      "Base Conflict 3a",          -- 11 (conflict 3)
      "Base Conflict 3b",          -- 12
      "Line 13",                   -- 13
    })

    -- Create incoming (left/theirs) buffer
    original_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(original_bufnr, "AcceptAllOriginal")
    vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, {
      "Incoming 1a",  -- 1
      "Incoming 1b",  -- 2
      "Incoming 2a",  -- 3
      "Incoming 2b",  -- 4
      "Incoming 3a",  -- 5
      "Incoming 3b",  -- 6
    })

    -- Create current (right/ours) buffer
    modified_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(modified_bufnr, "AcceptAllModified")
    vim.api.nvim_buf_set_lines(modified_bufnr, 0, -1, false, {
      "Current 1a",  -- 1
      "Current 1b",  -- 2
      "Current 2a",  -- 3
      "Current 2b",  -- 4
      "Current 3a",  -- 5
      "Current 3b",  -- 6
    })

    -- Define 3 conflict blocks
    conflict_blocks = {
      {
        base_range = { start_line = 3, end_line = 5 },
        output1_range = { start_line = 1, end_line = 3 },
        output2_range = { start_line = 1, end_line = 3 },
      },
      {
        base_range = { start_line = 7, end_line = 9 },
        output1_range = { start_line = 3, end_line = 5 },
        output2_range = { start_line = 3, end_line = 5 },
      },
      {
        base_range = { start_line = 11, end_line = 13 },
        output1_range = { start_line = 5, end_line = 7 },
        output2_range = { start_line = 5, end_line = 7 },
      },
    }

    local session = {
      result_bufnr = result_bufnr,
      conflict_blocks = conflict_blocks,
      original_bufnr = original_bufnr,
      modified_bufnr = modified_bufnr,
      result_base_lines = {
        "Line 1", "Line 2",
        "Base Conflict 1a", "Base Conflict 1b",
        "Line 5", "Line 6",
        "Base Conflict 2a", "Base Conflict 2b",
        "Line 9", "Line 10",
        "Base Conflict 3a", "Base Conflict 3b",
        "Line 13",
      }
    }

    lifecycle.get_session = function(tp)
      if tp == tabpage then return session end
      return nil
    end

    conflict.initialize_tracking(result_bufnr, conflict_blocks)
  end)

  after_each(function()
    for _, bufnr in ipairs({ result_bufnr, original_bufnr, modified_bufnr }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  describe("accept_all_incoming", function()
    it("should replace all conflict regions with incoming content", function()
      local success = conflict.accept_all_incoming(tabpage)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

      -- Non-conflict lines should be unchanged
      assert.are.equal("Line 1", lines[1])
      assert.are.equal("Line 2", lines[2])
      assert.are.equal("Line 5", lines[5])
      assert.are.equal("Line 6", lines[6])
      assert.are.equal("Line 9", lines[9])
      assert.are.equal("Line 10", lines[10])
      assert.are.equal("Line 13", lines[13])

      -- Conflict regions should have incoming content
      assert.are.equal("Incoming 1a", lines[3])
      assert.are.equal("Incoming 1b", lines[4])
      assert.are.equal("Incoming 2a", lines[7])
      assert.are.equal("Incoming 2b", lines[8])
      assert.are.equal("Incoming 3a", lines[11])
      assert.are.equal("Incoming 3b", lines[12])
    end)

    it("should return false when no session exists", function()
      lifecycle.get_session = function() return nil end
      local success = conflict.accept_all_incoming(tabpage)
      assert.is_false(success)
    end)

    it("should return false when no conflicts exist", function()
      local session = lifecycle.get_session(tabpage)
      session.conflict_blocks = {}
      local success = conflict.accept_all_incoming(tabpage)
      assert.is_false(success)
    end)

    it("should skip already resolved conflicts", function()
      -- Resolve conflict 1 manually first
      vim.api.nvim_set_current_buf(original_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      conflict.accept_incoming(tabpage)

      -- Now accept_all should only resolve the remaining 2
      local success = conflict.accept_all_incoming(tabpage)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
      -- All 3 should now be incoming
      assert.are.equal("Incoming 1a", lines[3])
      assert.are.equal("Incoming 1b", lines[4])
      assert.are.equal("Incoming 2a", lines[7])
      assert.are.equal("Incoming 2b", lines[8])
      assert.are.equal("Incoming 3a", lines[11])
      assert.are.equal("Incoming 3b", lines[12])
    end)
  end)

  describe("accept_all_current", function()
    it("should replace all conflict regions with current content", function()
      local success = conflict.accept_all_current(tabpage)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

      -- Non-conflict lines unchanged
      assert.are.equal("Line 1", lines[1])
      assert.are.equal("Line 2", lines[2])
      assert.are.equal("Line 13", lines[13])

      -- Conflict regions should have current content
      assert.are.equal("Current 1a", lines[3])
      assert.are.equal("Current 1b", lines[4])
      assert.are.equal("Current 2a", lines[7])
      assert.are.equal("Current 2b", lines[8])
      assert.are.equal("Current 3a", lines[11])
      assert.are.equal("Current 3b", lines[12])
    end)
  end)

  describe("accept_all_both", function()
    it("should combine both sides for all conflicts (incoming first by default)", function()
      local success = conflict.accept_all_both(tabpage)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

      -- Non-conflict lines unchanged
      assert.are.equal("Line 1", lines[1])
      assert.are.equal("Line 2", lines[2])

      -- Conflict 1: incoming then current (4 lines instead of 2)
      assert.are.equal("Incoming 1a", lines[3])
      assert.are.equal("Incoming 1b", lines[4])
      assert.are.equal("Current 1a", lines[5])
      assert.are.equal("Current 1b", lines[6])
    end)

    it("should respect first_input=2 for current-first ordering", function()
      local success = conflict.accept_all_both(tabpage, 2)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

      -- Conflict 1: current then incoming
      assert.are.equal("Current 1a", lines[3])
      assert.are.equal("Current 1b", lines[4])
      assert.are.equal("Incoming 1a", lines[5])
      assert.are.equal("Incoming 1b", lines[6])
    end)
  end)

  describe("discard_all", function()
    it("should reset all conflicts to base content", function()
      -- First resolve all conflicts
      conflict.accept_all_incoming(tabpage)

      -- Then discard all
      local success = conflict.discard_all(tabpage)
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)

      -- Everything should be back to original base
      assert.are.equal("Base Conflict 1a", lines[3])
      assert.are.equal("Base Conflict 1b", lines[4])
      assert.are.equal("Base Conflict 2a", lines[7])
      assert.are.equal("Base Conflict 2b", lines[8])
      assert.are.equal("Base Conflict 3a", lines[11])
      assert.are.equal("Base Conflict 3b", lines[12])
    end)

    it("should return false when no session exists", function()
      lifecycle.get_session = function() return nil end
      local success = conflict.discard_all(tabpage)
      assert.is_false(success)
    end)
  end)

  describe("atomic undo", function()
    it("should undo all accept_all_incoming changes with a single undo", function()
      -- Set result buffer as current and establish a proper undo break point
      vim.api.nvim_set_current_buf(result_bufnr)
      vim.cmd("let &undolevels = &undolevels")

      conflict.accept_all_incoming(tabpage)

      -- Verify changes applied
      local lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
      assert.are.equal("Incoming 1a", lines[3])
      assert.are.equal("Incoming 2a", lines[7])
      assert.are.equal("Incoming 3a", lines[11])

      -- Single undo should revert all changes
      vim.cmd("undo")

      lines = vim.api.nvim_buf_get_lines(result_bufnr, 0, -1, false)
      assert.are.equal("Base Conflict 1a", lines[3])
      assert.are.equal("Base Conflict 2a", lines[7])
      assert.are.equal("Base Conflict 3a", lines[11])
    end)
  end)
end)
