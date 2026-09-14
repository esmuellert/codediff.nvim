local h = require("tests.support.e2e")

for _, layout in ipairs({ "side-by-side", "inline" }) do
  describe("file-source refresh E2E / " .. layout, function()
    local repo, screen
    before_each(function()
      repo = h.repo()
      screen = h.screen("files", layout)
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

    it("refreshes a plain two-file comparison after external writes", function()
      h.open(screen, repo, "CodeDiff file a.txt b.txt", "b.txt")
      repo.write_file("b.txt", { "start", "external-B", "end" })
      h.expect_text(screen, "modified", "external-B")
    end)

    it("refreshes a directory comparison without relying on Git metadata", function()
      repo.write_file("left/a.txt", { "start", "left-A", "end" })
      repo.write_file("right/a.txt", { "start", "right-A", "end" })
      h.open(screen, repo, "CodeDiff dir left right")
      repo.write_file("right/a.txt", { "start", "right-B", "end" })
      h.expect_text(screen, "modified", "right-B")
      repo.write_file("right/new.txt", { "new file" })
      screen:await(function()
        return screen:exec([[
          local s = refresh_session()
          local text = table.concat(vim.api.nvim_buf_get_lines(s.panel.view.bufnr, 0, -1, false), '\n')
          return text:find('new.txt', 1, true) ~= nil
        ]])
      end, "directory listing did not update")
    end)

    it("updates unsaved text in a plain comparison through buffer events", function()
      repo.write_file("b.txt", { "start", "base-A", "context", "end", "tail" })
      h.open(screen, repo, "CodeDiff file a.txt b.txt", "b.txt")
      screen:exec("vim.api.nvim_set_current_win(refresh_session().modified_win); vim.api.nvim_win_set_cursor(0, { 2, 0 })")
      h.feed(screen, "ccBUFFER_EDIT<Esc>")
      h.expect_text(screen, "modified", "BUFFER_EDIT")
      screen:await(function()
        return screen:exec([[
          local s = refresh_session()
          return s.stored_diff_result and #s.stored_diff_result.changes > 0
        ]])
      end, "buffer edit was not consumed by the diff")
    end)
  end)
end
