-- Tests for hunk textobject (ih)
-- Uses direct view creation to test textobject logic

local view = require("codediff.ui.view")
local diff_module = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")

describe("Hunk Textobject", function()
  local left_path, right_path

  before_each(function()
    highlights.setup()

    local original_lines = { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6" }
    local modified_lines = { "line 1", "CHANGED 2", "CHANGED 3", "line 4", "line 5", "CHANGED 6" }

    left_path = vim.fn.tempname() .. "_left.txt"
    right_path = vim.fn.tempname() .. "_right.txt"
    vim.fn.writefile(original_lines, left_path)
    vim.fn.writefile(modified_lines, right_path)

    view.create({
      git_root = nil,
      original = path.make_ref(left_path, nil),
      modified = path.make_ref(right_path, nil),
      original_revision = nil,
      modified_revision = nil,
    })
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
    vim.fn.delete(left_path)
    vim.fn.delete(right_path)
  end)

  -- Helper: get session and focus modified window
  local function get_session_and_focus()
    local tabpage = vim.api.nvim_get_current_tabpage()

    -- Wait for session to be created (view.create defers via vim.schedule)
    local session
    vim.wait(3000, function()
      session = lifecycle.get_session(tabpage)
      return session
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end)
    assert.is_not_nil(session, "Session should exist")
    assert.is_not_nil(session.stored_diff_result, "Diff result should exist")

    if session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) then
      vim.api.nvim_set_current_win(session.modified_win)
    end
    return session
  end

  it("yih yanks a multi-line hunk", function()
    get_session_and_focus()

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.fn.setreg("a", "")
    vim.cmd('normal "ayih')

    local yanked = vim.fn.getreg("a")
    assert.is_not_nil(yanked:match("CHANGED 2"), "Should contain CHANGED 2")
    assert.is_not_nil(yanked:match("CHANGED 3"), "Should contain CHANGED 3")
    assert.is_nil(yanked:match("line 1"), "Should not contain line 1")
  end)

  it("yih yanks a single-line hunk", function()
    get_session_and_focus()

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.fn.setreg("a", "")
    vim.cmd('normal "ayih')

    local yanked = vim.fn.getreg("a")
    assert.is_not_nil(yanked:match("CHANGED 6"), "Should contain CHANGED 6")
    assert.is_nil(yanked:match("CHANGED 2"), "Should not contain lines from hunk 1")
  end)

  it("yih does nothing outside a hunk", function()
    get_session_and_focus()

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.fn.setreg("a", "")
    vim.cmd('normal "ayih')

    local yanked = vim.fn.getreg("a")
    assert.are.equal("", yanked, "Should not yank anything outside a hunk")
  end)
end)
