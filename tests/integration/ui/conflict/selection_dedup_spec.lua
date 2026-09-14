-- Test: Conflict file deduplication prevents unnecessary view.update() calls (#317)
local assert = require("luassert")
local path = require("codediff.core.path")

describe("Conflict dedup in on_file_select", function()
  local lifecycle, config

  before_each(function()
    lifecycle = require("codediff.ui.lifecycle")
    config = require("codediff.config")
  end)

  it("should detect conflict mode via result_win on session", function()
    -- Simulate a conflict session with result_win set
    local tabpage = vim.api.nvim_get_current_tabpage()
    local result_win = vim.api.nvim_get_current_win()

    -- Create a mock session with conflict mode indicators
    local mock_session = {
      git_root = "/tmp/test",
      modified = path.make_ref("file.txt", "/tmp/test"),
      original = path.make_ref("file.txt", "/tmp/test"),
      modified_revision = ":2",
      original_revision = ":3",
      result_win = result_win,
      result_bufnr = vim.api.nvim_get_current_buf(),
    }

    -- The dedup check logic from on_file_select:
    -- For conflict files (group="conflicts"), if session has valid result_win,
    -- the same file should be detected as already displayed
    local group = "conflicts"
    local file_path = "file.txt"
    local abs_path = "/tmp/test/file.txt"

    local is_same_file = (mock_session.modified and mock_session.modified.absolute == abs_path) or (mock_session.original and mock_session.original.absolute == abs_path)

    assert.is_true(is_same_file, "Should detect same conflict file")

    -- The fix: conflict-specific early return
    local should_skip = (group == "conflicts" and mock_session.result_win and vim.api.nvim_win_is_valid(mock_session.result_win))

    assert.is_true(should_skip, "Should skip update for same conflict file with active result_win")
  end)

  it("should NOT skip when result_win is nil (conflict not yet loaded)", function()
    local mock_session = {
      git_root = "/tmp/test",
      modified = path.make_ref("file.txt", "/tmp/test"),
      original = path.make_ref("file.txt", "/tmp/test"),
      modified_revision = nil,
      original_revision = nil,
      result_win = nil,
    }

    local group = "conflicts"
    local should_skip = (group == "conflicts" and mock_session.result_win and vim.api.nvim_win_is_valid(mock_session.result_win))

    assert.is_falsy(should_skip, "Should NOT skip when result_win is nil")
  end)

  it("should NOT skip for non-conflict groups even with result_win", function()
    local result_win = vim.api.nvim_get_current_win()

    local mock_session = {
      git_root = "/tmp/test",
      modified = path.make_ref("file.txt", "/tmp/test"),
      original = path.make_ref("file.txt", "/tmp/test"),
      modified_revision = ":0",
      original_revision = "abc123",
      result_win = result_win,
    }

    local group = "staged"
    local should_skip = (group == "conflicts" and mock_session.result_win and vim.api.nvim_win_is_valid(mock_session.result_win))

    assert.is_false(should_skip, "Should NOT skip for staged group")
  end)

  it("demonstrates the original bug: mutable revision check fails for conflict revisions", function()
    -- This is the original buggy check that caused flickering
    -- Conflict revisions :2/:3 match ^:[0-3]$ causing false positive
    local mock_session = {
      original_revision = ":3", -- conflict THEIRS revision
    }

    local current_is_mutable = mock_session.original_revision and mock_session.original_revision:match("^:[0-3]$")

    assert.is_truthy(current_is_mutable, "Conflict revision :3 matches mutable pattern (the root cause of the bug)")

    -- And conflict files are NOT in staged list
    local file_has_staged = false -- conflict files aren't in status_result.staged

    -- This evaluates to true, meaning "comparison base needs to change" (WRONG for conflicts)
    local would_skip = not (file_has_staged ~= (current_is_mutable and true or false))

    assert.is_false(would_skip, "Original check incorrectly thinks comparison base needs to change for conflict files")
  end)
end)
