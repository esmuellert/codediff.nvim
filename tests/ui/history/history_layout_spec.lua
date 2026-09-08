-- History panel layout and content.

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

describe("History layout", function()
  local repo
  local original_statuscolumn

  before_each(function()
    original_statuscolumn = vim.o.statuscolumn
    vim.o.statuscolumn = "%s%=%l %C "
    require("codediff").setup({})
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "version 1" })
    repo.git("add .")
    repo.git("commit -m first")
    repo.write_file("file.txt", { "version 2" })
    repo.git("add .")
    repo.git("commit -m second")
    repo.write_file("file.txt", { "version 3" })
    repo.git("add .")
    repo.git("commit -m third")
    vim.cmd("edit " .. repo.path("file.txt"))
  end)

  after_each(function()
    vim.o.statuscolumn = original_statuscolumn
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  for _, position in ipairs({ "left", "bottom" }) do
    for _, original_position in ipairs({ "left", "right" }) do
      it("restores panes with history " .. position .. " and original " .. original_position, function()
        require("codediff").setup({
          diff = { layout = "side-by-side", original_position = original_position },
          history = { position = position },
        })
        vim.cmd("CodeDiff history")
        local lifecycle = require("codediff.ui.lifecycle")
        local tabpage, session, history
        assert.is_true(vim.wait(5000, function()
          tabpage = vim.api.nvim_get_current_tabpage()
          session = lifecycle.get_session(tabpage)
          history = lifecycle.get_panel_view(tabpage)
          return session and history and history.current_selection and session.stored_diff_result
            and session.original_revision ~= nil
        end, 10))
        local selection = vim.deepcopy(history.current_selection)
        for _, closed_side in ipairs({ "original", "modified", "both" }) do
          if closed_side ~= "modified" then
            vim.api.nvim_win_close(session.original_win, false)
          end
          if closed_side ~= "original" then
            vim.api.nvim_win_close(session.modified_win, false)
          end
          vim.wait(100)
          assert.equals(session, lifecycle.get_session(tabpage))
          vim.api.nvim_set_current_win(history.winid)
          history.on_file_select(selection)
          assert.is_true(vim.wait(2000, function()
            return session.original_win and vim.api.nvim_win_is_valid(session.original_win)
              and session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
          end, 10), "History selection must restore the panes")
          assert.is_true(h.wait_for_diff_ready())
          assert.same({ "version 2" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))
          assert.same({ "version 3" }, vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false))
          assert.equals(3, #vim.api.nvim_tabpage_list_wins(tabpage))
          local orig_pos = vim.api.nvim_win_get_position(session.original_win)
          local mod_pos = vim.api.nvim_win_get_position(session.modified_win)
          local panel_pos = vim.api.nvim_win_get_position(history.winid)
          assert.equals(original_position == "left", orig_pos[2] < mod_pos[2])
          if position == "bottom" then
            assert.is_true(panel_pos[1] > orig_pos[1] and panel_pos[1] > mod_pos[1])
          else
            assert.is_true(panel_pos[2] < orig_pos[2] and panel_pos[2] < mod_pos[2])
          end
        end
      end)
    end
  end

  it("opens a history panel at the bottom with commit content", function()
    vim.cmd("CodeDiff history")

    -- Wait for the history panel to appear.
    local appeared = vim.wait(5000, function()
      return h.find_window_by_filetype("codediff-history") ~= nil
    end, 50)
    assert.is_true(appeared, "history panel should appear within 5s")

    local history_win, history_buf = h.find_window_by_filetype("codediff-history")
    assert.is_not_nil(history_win)
    assert.is_not_nil(history_buf)
    assert.equal("", vim.wo[history_win].statuscolumn,
      "history should not inherit the user's status column")
    assert.equal(0, vim.fn.getwininfo(history_win)[1].textoff,
      "history rows should use the full window width")

    local content = h.get_buffer_content(history_buf)
    local lines = h.get_buffer_lines(history_buf)
    assert.is_true(#lines > 0, "history buffer should have lines")
    h.assert_contains(content, "Commit History",
      "history panel should show 'Commit History' title")

    -- History is at the bottom: its row position is >= every other window's.
    local history_row = vim.api.nvim_win_get_position(history_win)[1]
    for _, other_win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if other_win ~= history_win then
        local other_row = vim.api.nvim_win_get_position(other_win)[1]
        assert.is_true(history_row >= other_row,
          "history should be at bottom (row " .. history_row .. " vs other " .. other_row .. ")")
      end
    end
  end)
end)
