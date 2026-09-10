local Screen = require("tests.framework.screen")
local gutter = require("tests.ui.conflict.gutter_helpers")

describe("conflict gutter lifecycle on the screen grid", function()
  local screen, repo, panes

  before_each(function()
    repo = gutter.create_repo()
    screen = Screen.new(120, 40)
    panes = gutter.open_merge(screen, repo)
  end)

  after_each(function()
    if screen then
      screen:close()
      screen = nil
    end
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  local function expect_merge(rows, colors)
    rows = rows or gutter.merge_rows
    for _, focus in ipairs({ "original", "modified", "result" }) do
      screen:exec("vim.api.nvim_set_current_win(...)", { panes[focus] })
      screen:flush()
      for _, side in ipairs({ "original", "modified", "result" }) do
        gutter.expect_pane(screen, panes[side], rows[side], side .. " while focused on " .. focus, colors and colors[side])
      end
    end
  end

  local function colors(original, modified, result)
    return screen:exec(
      [[
      local names = ...
      local values = {}
      for side, name in pairs(names) do
        values[side] = vim.api.nvim_get_hl(0, { name = 'CodeDiffConflictSign' .. name, link = false }).fg
      end
      return values
    ]],
      { { original = original, modified = modified, result = result } }
    )
  end

  it("renders a real merge with the full block shape in all three panes", function()
    expect_merge(nil, colors("", "", ""))
  end)

  it("removes conflict markers when the same windows show an ordinary diff", function()
    panes = gutter.open_plain(screen, repo)
    gutter.expect_no_conflict_markers(screen, panes.original)
    gutter.expect_no_conflict_markers(screen, panes.modified)
  end)

  it("survives repeated ordinary-diff round trips", function()
    for _ = 1, 3 do
      panes = gutter.open_plain(screen, repo)
      gutter.expect_no_conflict_markers(screen, panes.original)
      gutter.expect_no_conflict_markers(screen, panes.modified)
      panes = gutter.return_to_merge(screen)
      expect_merge()
    end
  end)

  it("restores the surviving window's option in single-file mode", function()
    screen:exec(
      [[
      require('codediff.ui.view.side_by_side').show_untracked_file(gutter_test_tab, ...)
    ]],
      { repo.path("fresh.txt") }
    )
    assert.equals("", screen:exec("return vim.wo[...].statuscolumn", { panes.modified }))
  end)

  it("rebinds a recreated incoming pane after an untracked file", function()
    for _ = 1, 2 do
      screen:exec(
        [[
        require('codediff.ui.view.side_by_side').show_untracked_file(gutter_test_tab, ...)
      ]],
        { repo.path("fresh.txt") }
      )
      panes = gutter.return_to_merge(screen)
      expect_merge()
    end
  end)

  it("rebinds a recreated current pane after a deleted file", function()
    panes = gutter.return_to_merge(screen, "other.txt")
    expect_merge(gutter.other_merge_rows)
    screen:exec(
      [[
      local root = ...
      require('codediff.ui.view.side_by_side').show_deleted_file(gutter_test_tab, root, 'deleted.txt', root .. '/deleted.txt', 'unstaged')
    ]],
      { repo.dir }
    )
    panes = gutter.return_to_merge(screen, "other.txt")
    expect_merge(gutter.other_merge_rows)
  end)

  it("replaces marker maps when switching between two conflict files", function()
    panes = gutter.return_to_merge(screen, "other.txt")
    expect_merge(gutter.other_merge_rows)
    panes = gutter.return_to_merge(screen)
    expect_merge()
  end)

  it("restores conflict geometry and markers after leaving and returning to the tab", function()
    screen:command("tabnew")
    screen:exec("vim.api.nvim_set_current_tabpage(gutter_test_tab)")
    screen:wait_for(function()
      return screen:exec("return not require('codediff.ui.lifecycle').get_session(gutter_test_tab).suspended")
    end)
    expect_merge()
  end)

  it("keeps both panes correct after resizing the attached UI", function()
    screen:request("nvim_ui_try_resize", { 100, 36 })
    screen:flush()
    expect_merge()
  end)

  it("updates shapes and colors on accept, undo, redo and discard", function()
    screen:exec([[
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      vim.api.nvim_set_current_win(s.modified_win)
      vim.api.nvim_win_set_cursor(s.modified_win, { 2, 0 })
      assert(require('codediff.ui.conflict').accept_current(gutter_test_tab))
    ]])
    local resolved = vim.deepcopy(gutter.merge_rows)
    resolved.result = { "  before", "╭─OURS1", "│ inserted", "│ OURS2", "╰─base3", "  after", "  tail" }
    expect_merge(resolved, colors("Rejected", "Accepted", "Resolved"))

    screen:exec("vim.api.nvim_set_current_win(...)", { panes.result })
    screen:input("u")
    screen:wait_for(function()
      return screen:exec("return vim.api.nvim_buf_line_count(...) == 6", { panes.result_buf })
    end, "undo did not restore the seed")
    expect_merge(nil, colors("", "", ""))

    screen:exec("vim.api.nvim_set_current_win(...)", { panes.result })
    screen:input("<C-r>")
    screen:wait_for(function()
      return screen:exec("return vim.api.nvim_buf_line_count(...) == 7", { panes.result_buf })
    end, "redo did not restore the resolution")
    expect_merge(resolved, colors("Rejected", "Accepted", "Resolved"))

    screen:exec([[
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      vim.api.nvim_set_current_win(s.modified_win)
      vim.api.nvim_win_set_cursor(s.modified_win, { 2, 0 })
      assert(require('codediff.ui.conflict').discard(gutter_test_tab))
    ]])
    expect_merge(nil, colors("", "", ""))
  end)

  it("preserves resolved Result content and colors across a tab round trip", function()
    screen:exec([[
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      vim.api.nvim_set_current_win(s.modified_win)
      vim.api.nvim_win_set_cursor(s.modified_win, { 2, 0 })
      assert(require('codediff.ui.conflict').accept_current(gutter_test_tab))
      vim.cmd('tabnew')
      vim.api.nvim_set_current_tabpage(gutter_test_tab)
    ]])
    screen:wait_for(function()
      return screen:exec("return not require('codediff.ui.lifecycle').get_session(gutter_test_tab).suspended")
    end)
    local rows = vim.deepcopy(gutter.merge_rows)
    rows.result = { "  before", "╭─OURS1", "│ inserted", "│ OURS2", "╰─base3", "  after", "  tail" }
    expect_merge(rows, colors("Rejected", "Accepted", "Resolved"))
  end)

  it("removes Result markers when manual editing empties its tracked range", function()
    screen:exec("vim.api.nvim_set_current_win(...)", { panes.result })
    screen:input("2G3dd")
    screen:wait_for(function()
      return screen:exec("return vim.api.nvim_buf_line_count(...) == 3", { panes.result_buf })
    end)
    local rows = vim.deepcopy(gutter.merge_rows)
    rows.result = { "before", "after", "tail" }
    expect_merge(rows, colors("Resolved", "Resolved", "Resolved"))
  end)

  it("refreshes marker colors after a manual Result edit", function()
    screen:exec("vim.api.nvim_set_current_win(...); vim.api.nvim_win_set_cursor(0, { 2, 0 })", { panes.result })
    screen:input("ccMANUAL<Esc>")
    screen:wait_for(function()
      return screen:exec("return vim.api.nvim_buf_get_lines(..., 1, 2, false)[1] == 'MANUAL'", { panes.result_buf })
    end)
    local rows = vim.deepcopy(gutter.merge_rows)
    rows.result[2] = "╭─MANUAL"
    expect_merge(rows, colors("Resolved", "Resolved", "Resolved"))
  end)

  it("does not run the old Result refresh against a retargeted session", function()
    local old_result = panes.result_buf
    panes = gutter.open_plain(screen, repo)
    screen:exec(
      [[
      local buf = ...
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'changed after leaving conflict' })
      local ok, err = pcall(vim.api.nvim_exec_autocmds, 'TextChanged', { buffer = buf })
      assert(ok, tostring(err))
    ]],
      { old_result }
    )
    screen:flush()
    gutter.expect_no_conflict_markers(screen, panes.original)
    gutter.expect_no_conflict_markers(screen, panes.modified)
  end)

  it("releases the surviving pane when a suspended session loses an input buffer", function()
    local value = screen:exec([[
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      local state = require('codediff.ui.lifecycle.state')
      state.suspend_diff(gutter_test_tab)
      vim.api.nvim_buf_delete(s.original_bufnr, { force = true })
      state.resume_diff(gutter_test_tab)
      return vim.wo[s.modified_win].statuscolumn
    ]])
    assert.equals("", value)
  end)

  it("restores statuscolumns when the session is explicitly cleaned up", function()
    screen:exec("require('codediff.ui.lifecycle').cleanup(gutter_test_tab)")
    assert.is_nil(screen:exec("return require('codediff.ui.lifecycle').get_session(gutter_test_tab)"))
    local columns = screen:exec([[
      local values = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do values[#values + 1] = vim.wo[win].statuscolumn end
      return values
    ]])
    assert.is_true(#columns > 0)
    for _, value in ipairs(columns) do
      assert.equals("", value)
    end
  end)
end)
