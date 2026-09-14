local h = require("tests.support.e2e")

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

      it("[T09] defers ordinary-file updates while hidden and restores them without moving focus", function()
        write_a("working-A")
        h.open(screen, repo)
        h.focus(screen, "modified", 4)
        local view = h.panes(screen).modified.view
        screen:command("tabnew")
        local away = screen:exec("return vim.api.nvim_get_current_tabpage()")
        write_a("changed-while-away")
        vim.wait(650)
        assert.equals(away, screen:exec("return vim.api.nvim_get_current_tabpage()"))
        screen:command("tabprevious")
        h.expect_text(screen, "modified", "changed-while-away")
        h.idle(screen)
        assert.same(view, h.panes(screen).modified.view)
      end)

      it("[T10] a hidden input wipe retires its controller before the tab is resumed", function()
        write_a("working-A")
        h.open(screen, repo)
        local buf = h.panes(screen).original.buf
        screen:exec("refresh_test.retired = refresh_session().refresh")
        screen:command("tabnew")
        screen:command("bwipeout! " .. buf)
        screen:command("tabprevious")
        screen:await(function()
          return screen:exec("return refresh_test.retired.closed and refresh_session() == nil")
        end)
        write_a("after-wipe")
        vim.wait(100)
        h.assert_no_errors(screen)
      end)

      it("[T11] closing a diff pane releases the session and its pending work", function()
        write_a("working-A")
        h.open(screen, repo)
        h.focus(screen, "modified")
        screen:command("close!")
        screen:await(function()
          return screen:exec("return refresh_session() == nil")
        end)
        write_a("after-close")
        vim.wait(100)
        h.assert_no_errors(screen)
      end)

      it("[T12] retries a real Git read failure without publishing partial inputs", function()
        open_staged()
        local expected = h.panes(screen).modified.lines
        screen:command("tabnew")
        write_a("recovered-index")
        repo.command({ "add", "a.txt" })
        local oid = vim.trim(repo.command({ "rev-parse", ":0:a.txt" }))
        local object = repo.git_path("objects") .. "/" .. oid:sub(1, 2) .. "/" .. oid:sub(3)
        assert((vim.uv or vim.loop).fs_rename(object, object .. ".held"))
        screen:command("tabprevious")
        screen:await(function()
          return screen:exec([[
            for _, message in ipairs(refresh_test.notifications) do
              if message.message:find('CodeDiff refresh:', 1, true) then return true end
            end
            return false
          ]])
        end, "failed Git read was not reported")
        assert.same(expected, h.panes(screen).modified.lines)
        assert((vim.uv or vim.loop).fs_rename(object .. ".held", object))
        h.expect_text(screen, "modified", "recovered-index")
        h.idle(screen)
      end)

      it("[T13] follows a file outside Git and can return to another repository", function()
        write_a("working-A")
        repo.write_file("../outside.txt", { "outside-repository" })
        other_repo = h.repo()
        other_repo.replace("b.txt", 2, "other-working")
        h.open(screen, repo, "CodeDiff file HEAD")
        h.focus(screen, "modified")
        h.feed(screen, ":edit " .. vim.fn.fnameescape(repo.root .. "/outside.txt") .. "<CR>")
        h.expect_text(screen, "modified", "outside-repository")
        h.expect_lines(screen, "original", { "" })
        h.idle(screen)
        assert.is_nil(screen:exec("return refresh_session().git_root"))
        h.feed(screen, ":edit " .. vim.fn.fnameescape(other_repo.path("b.txt")) .. "<CR>")
        h.expect_text(screen, "original", "base-B")
        h.expect_text(screen, "modified", "other-working")
      end)

      it("[T14] restores user buffer mappings after a refreshed session closes", function()
        write_a("working-A")
        screen:exec(
          [[
          local filename = ...
          require('codediff').setup({ keymaps = { view = { stage_hunk = '<F7>' } } })
          vim.cmd('edit ' .. vim.fn.fnameescape(filename))
          vim.keymap.set('n', '<F7>', function()
            vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'USER-MAPPING' })
          end, { buffer = true })
        ]],
          { repo.path("a.txt") }
        )
        h.open(screen, repo)
        h.action(screen, "view", "stage_hunk", "modified", 2)
        screen:await(function()
          return screen:exec("return refresh_session().modified_revision == ':0'")
        end)
        h.idle(screen)
        h.action(screen, "view", "quit", "modified")
        screen:await(function()
          return screen:exec("return refresh_session() == nil")
        end)
        h.feed(screen, "<F7>")
        screen:await(function()
          return h.grid_contains(screen, "USER-MAPPING")
        end)
        assert.equals("working-A", repo.blob_lines(":0", "a.txt")[2])
      end)

      it("[T15] restores the working buffer's original inlay-hint setting after refresh", function()
        write_a("working-A")
        local buf = screen:exec(
          [[
          vim.cmd('edit ' .. vim.fn.fnameescape((...)))
          local buf = vim.api.nvim_get_current_buf()
          vim.lsp.inlay_hint.enable(true, { bufnr = buf })
          return buf
        ]],
          { repo.path("a.txt") }
        )
        h.open(screen, repo, "CodeDiff file HEAD")
        assert.is_false(screen:exec("return vim.lsp.inlay_hint.is_enabled({ bufnr = ... })", { buf }))
        repo.git("commit -am moved-head")
        h.expect_text(screen, "original", "working-A")
        h.idle(screen)
        h.action(screen, "view", "quit", "modified")
        screen:await(function()
          return screen:exec("return refresh_session() == nil")
        end)
        assert.is_true(screen:exec("return vim.lsp.inlay_hint.is_enabled({ bufnr = ... })", { buf }))
      end)

      it("[T16] shares a working buffer across tabs without losing edits when one closes", function()
        write_a("working-A")
        local buf = screen:exec(
          [[
          vim.cmd('edit ' .. vim.fn.fnameescape((...)))
          local buf = vim.api.nvim_get_current_buf()
          vim.lsp.inlay_hint.enable(true, { bufnr = buf })
          return buf
        ]],
          { repo.path("a.txt") }
        )
        h.open(screen, repo)
        local first = h.panes(screen).tab
        screen:command("tabnew")
        h.open(screen, repo)
        write_a("next-A")
        h.expect_text(screen, "modified", "next-A")
        h.focus(screen, "modified", 2)
        h.feed(screen, "ccSHARED-EDIT<Esc>")
        h.expect_text(screen, "modified", "SHARED-EDIT")
        h.action(screen, "view", "quit", "modified")
        screen:exec("refresh_test.tab = ...; vim.api.nvim_set_current_tabpage(refresh_test.tab)", { first })
        h.expect_text(screen, "modified", "SHARED-EDIT")
        h.idle(screen)
        assert.equals("next-A", repo.read_file("a.txt")[2])
        assert.is_false(screen:exec("return vim.lsp.inlay_hint.is_enabled({ bufnr = ... })", { buf }))
        h.action(screen, "view", "quit", "modified")
        screen:await(function()
          return screen:exec("return refresh_session() == nil")
        end)
        assert.is_true(screen:exec("return vim.lsp.inlay_hint.is_enabled({ bufnr = ... })", { buf }))
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
