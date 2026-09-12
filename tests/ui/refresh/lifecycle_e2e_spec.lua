local h = require("tests.ui.refresh.helpers")

for _, backend in ipairs({ "native", "polling" }) do
  for _, layout in ipairs({ "side-by-side", "inline" }) do
    describe("refresh lifecycle E2E " .. backend .. " / " .. layout, function()
      local repo, other_repo, screen
      before_each(function()
        repo = h.repo()
        screen = h.screen(backend, layout)
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
        if other_repo then
          other_repo.cleanup()
          other_repo = nil
        end
      end)

      local function write_a(text)
        repo.write_file("a.txt", { "start", text, "context", "end", "tail" })
      end
      local function open_staged()
        write_a("staged-A")
        repo.write_file("b.txt", { "start", "staged-B", "end" })
        repo.git("add a.txt b.txt")
        h.open(screen, repo, "CodeDiff --staged")
      end
      local function wait_held()
        screen:await(function()
          return screen:exec("return #refresh_test.held > 0")
        end, "no real Git response was held")
      end

      it("discards a late refresh after selecting another file, then keeps refreshing", function()
        open_staged()
        h.hold_content(screen, "a.txt")
        write_a("late-A")
        repo.git("add a.txt")
        wait_held()
        h.select(screen, "b.txt")
        h.expect_text(screen, "modified", "staged-B")
        h.release_content(screen)
        h.idle(screen)
        assert.equals("base-B", h.panes(screen).original.lines[2])
        assert.equals("staged-B", h.panes(screen).modified.lines[2])
        repo.write_file("b.txt", { "start", "latest-B", "end" })
        repo.git("add b.txt")
        h.expect_text(screen, "modified", "latest-B")
      end)

      it("ignores delayed Git responses after closing their tab", function()
        open_staged()
        h.hold_content(screen, "a.txt")
        write_a("late-A")
        repo.git("add a.txt")
        wait_held()
        screen:command("tabclose!")
        h.release_content(screen)
        vim.wait(700)
        h.assert_no_errors(screen)
        assert.is_nil(screen:exec("return refresh_session()"))
      end)

      it("retires a pending refresh after a pane buffer is wiped and can open another file", function()
        open_staged()
        h.hold_content(screen, "a.txt")
        write_a("late-A")
        repo.git("add a.txt")
        wait_held()
        screen:exec([[
          local s = refresh_session()
          refresh_test.retired = s.refresh
          vim.api.nvim_buf_delete(s.original_bufnr, { force = true })
        ]])
        h.release_content(screen)
        screen:await(function()
          return screen:exec("return refresh_test.retired.closed == true")
        end, "wiped-buffer refresh was not retired")
        h.assert_no_errors(screen)
        assert.is_nil(screen:exec("return refresh_session()"))
        h.open(screen, repo, "CodeDiff --staged -- b.txt", "b.txt")
        h.expect_text(screen, "modified", "staged-B")
        h.idle(screen)
        repo.write_file("b.txt", { "start", "recovered-B", "end" })
        repo.git("add b.txt")
        h.expect_text(screen, "modified", "recovered-B")
      end)

      it("keeps buffer edits made while new index inputs are in flight", function()
        write_a("index-A")
        repo.git("add a.txt")
        write_a("working-B")
        h.open(screen, repo)
        h.hold_content(screen, "a.txt")
        write_a("index-C")
        repo.git("add a.txt")
        write_a("working-B")
        wait_held()
        screen:exec("vim.api.nvim_set_current_win(refresh_session().modified_win); vim.api.nvim_win_set_cursor(0, { 2, 0 })")
        h.feed(screen, "ccUSER_LATE<CR>USER_LATE_TWO<Esc>")
        h.release_content(screen)
        h.idle(screen)
        h.expect_text(screen, "modified", "USER_LATE_TWO")
        assert.equals("index-C", h.panes(screen).original.lines[2])
        assert.same({ "start", "USER_LATE", "USER_LATE_TWO", "context", "end", "tail" }, h.panes(screen).modified.lines)
        assert.equals(4, screen:exec("return refresh_session().stored_diff_result.changes[1].modified.end_line"))
      end)

      it("keeps the requested HEAD dependency when following a different working file", function()
        write_a("working-A")
        repo.write_file("b.txt", { "start", "working-B", "end" })
        h.open(screen, repo, "CodeDiff file HEAD")
        screen:exec(
          [[
          vim.api.nvim_set_current_win(refresh_session().modified_win)
          vim.cmd('edit ' .. vim.fn.fnameescape((...) .. '/b.txt'))
        ]],
          { repo.dir }
        )
        screen:await(function()
          return screen:exec("return refresh_session().modified.relative == 'b.txt' and refresh_session().stored_diff_result ~= nil")
        end, "working-file follow did not settle")
        repo.git("add b.txt")
        repo.git("commit -m next-B")
        screen:await(function()
          return h.panes(screen).original.lines[2] == "working-B"
        end, "file follow pinned HEAD to the opening SHA")
      end)

      it("watches the new repository after following a file across repository roots", function()
        other_repo = h.repo()
        other_repo.write_file("b.txt", { "start", "other-base", "end" })
        other_repo.git("commit -am other-base")
        other_repo.write_file("b.txt", { "start", "other-working", "end" })
        write_a("working-A")
        h.open(screen, repo, "CodeDiff file HEAD")
        screen:exec(
          [[
          vim.api.nvim_set_current_win(refresh_session().modified_win)
          vim.cmd('edit ' .. vim.fn.fnameescape((...) .. '/b.txt'))
        ]],
          { other_repo.dir }
        )
        screen:await(function()
          return screen:exec("return refresh_session().git_root == (...) and refresh_session().stored_diff_result ~= nil", { other_repo.dir })
        end, "working-file follow did not switch repositories")
        h.idle(screen)
        assert.equals("other-base", h.panes(screen).original.lines[2])
        other_repo.write_file("b.txt", { "start", "other-next", "end" })
        h.expect_text(screen, "modified", "other-next")
      end)

      it("updates diff content while its Explorer panel is hidden", function()
        write_a("working-A")
        h.open(screen, repo)
        screen:exec("require('codediff.ui.view.actions.panes').toggle_explorer({ tabpage = refresh_test.tab })")
        assert.is_true(screen:exec("return refresh_session().panel.view.is_hidden"))
        write_a("working-B")
        repo.write_file("added.txt", { "new" })
        h.expect_text(screen, "modified", "working-B")
        screen:exec("require('codediff.ui.view.actions.panes').toggle_explorer({ tabpage = refresh_test.tab })")
        screen:await(function()
          return screen:exec([[
            local panel = refresh_session().panel.view
            return table.concat(vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false), '\n'):find('added.txt', 1, true) ~= nil
          ]])
        end, "hidden-panel changes were lost")
      end)

      it("shares repository events across tabs and survives closing one subscriber", function()
        write_a("working-A")
        repo.write_file("b.txt", { "start", "working-B", "end" })
        h.open(screen, repo)
        local first = h.panes(screen).tab
        screen:command("tabnew")
        h.open(screen, repo, "CodeDiff -- b.txt", "b.txt")
        local expected = h.panes(screen)
        local before = h.checkpoint(screen)
        write_a("next-A")
        h.wait_event(screen, before)
        h.preserved(screen, expected, 200)
        screen:exec("refresh_test.tab = ...; vim.api.nvim_set_current_tabpage(refresh_test.tab)", { first })
        h.expect_text(screen, "modified", "next-A")
        screen:command("tabclose!")
        screen:exec("refresh_test.tab = ...; vim.api.nvim_set_current_tabpage(refresh_test.tab)", { expected.tab })
        repo.write_file("b.txt", { "start", "next-B", "end" })
        h.expect_text(screen, "modified", "next-B")
      end)

      if backend == "native" then
        it("continues from the real watcher into polling after the process exits", function()
          write_a("working-A")
          h.open(screen, repo)
          screen:exec([[
            assert(refresh_test.watcher_pid, 'watcher PID was not observed')
            assert((vim.uv or vim.loop).kill(refresh_test.watcher_pid, 'sigterm'))
          ]])
          screen:await(function()
            return screen:exec("return refresh_test.fallback == true")
          end, "watcher failure did not enable fallback")
          write_a("after-watcher-exit")
          h.expect_text(screen, "modified", "after-watcher-exit")
        end)
      end
    end)
  end
end
