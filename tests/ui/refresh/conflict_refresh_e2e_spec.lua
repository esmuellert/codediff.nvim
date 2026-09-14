local h = require("tests.ui.refresh.helpers")

local function merge_repo()
  local repo = h.repo()
  repo.git("checkout -b incoming")
  repo.write_file("a.txt", { "start", "incoming-A", "context", "end", "tail" })
  repo.git("commit -am incoming")
  repo.git("checkout main")
  repo.write_file("a.txt", { "start", "current-A", "context", "end", "tail" })
  repo.git("commit -am current")
  local _, code = repo.git("merge incoming --no-edit", 1)
  assert.equals(1, code, "fixture must conflict")
  return repo
end

local function replace_current_stage(repo, stage)
  stage = stage or 2
  repo.write_file("replacement.txt", { "start", "current-B", "context", "end", "tail" })
  local oid = vim.trim(repo.git("hash-object -w replacement.txt"))
  local entries = repo.git("ls-files --stage -- a.txt")
  entries = entries:gsub("(%d+) (%x+) " .. stage .. "\ta.txt", "%1 " .. oid .. " " .. stage .. "\ta.txt")
  local result = vim.system({ "git", "-C", repo.dir, "update-index", "--index-info" }, { stdin = entries, text = true }):wait()
  assert.equals(0, result.code, result.stderr)
end

for _, backend in ipairs({ "native", "polling" }) do
  describe("merge refresh E2E / " .. backend, function()
    local repo, screen
    before_each(function()
      repo = merge_repo()
      screen = h.screen(backend, "side-by-side")
      h.open(screen, repo)
      screen:await(function()
        return screen:exec("return refresh_session().result_bufnr ~= nil")
      end)
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

    local function edit_result()
      screen:exec("vim.api.nvim_set_current_win(refresh_session().result_win); vim.api.nvim_win_set_cursor(0, { 4, 0 })")
      h.feed(screen, "ccUSER_EDIT_KEEP<Esc>")
      h.expect_text(screen, "result", "USER_EDIT_KEEP")
      return h.panes(screen)
    end

    it("#558: unrelated same-status changes preserve Result, focus, cursors and windows", function()
      local expected = edit_result()
      local before = h.checkpoint(screen)
      repo.write_file("background.txt", { "different" })
      h.wait_event(screen, before)
      h.preserved(screen, expected)
    end)

    it("keeps all rendered merge cells stable during a burst of unrelated writes", function()
      local expected = edit_result()
      h.idle(screen)
      local unchanged = h.watch_grid(screen)
      for i = 1, 6 do
        local before = h.checkpoint(screen)
        repo.write_file("background.txt", { "background-" .. i })
        h.wait_event(screen, before)
      end
      h.preserved(screen, expected, 200)
      unchanged()
    end)

    it("preserves merge work when another file is staged", function()
      local expected = edit_result()
      local before = h.checkpoint(screen)
      repo.write_file("b.txt", { "start", "staged-B", "end" })
      repo.git("add b.txt")
      h.wait_event(screen, before)
      h.preserved(screen, expected)
    end)

    it("refreshes actual conflict inputs when the Result is still untouched", function()
      replace_current_stage(repo)
      h.expect_text(screen, "modified", "current-B")
      assert.equals("base-A", h.panes(screen).result.lines[2])
    end)

    it("does not overwrite user work when the conflict inputs change", function()
      edit_result()
      replace_current_stage(repo)
      screen:await(function()
        return screen:exec([[
          for _, message in ipairs(refresh_test.notifications) do
            if message.message:lower():find('conflict inputs changed', 1, true) then return true end
          end
          return false
        ]])
      end, "changed merge inputs were not reported")
      assert.equals("USER_EDIT_KEEP", h.panes(screen).result.lines[4])
    end)

    it("retains pending changes across tab suspension without stealing focus", function()
      local expected = edit_result()
      screen:command("tabnew")
      local other = screen:exec("return vim.api.nvim_get_current_tabpage()")
      repo.write_file("background.txt", { "while-away" })
      vim.wait(700)
      assert.equals(other, screen:exec("return vim.api.nvim_get_current_tabpage()"))
      screen:exec("vim.api.nvim_set_current_tabpage(refresh_test.tab)")
      h.expect_text(screen, "result", "USER_EDIT_KEEP")
      assert.same(expected.result.lines, h.panes(screen).result.lines)
    end)

    it("does not leave work running after its tab closes", function()
      local before = h.checkpoint(screen)
      repo.write_file("background.txt", { "closing" })
      if backend == "native" then
        h.wait_event(screen, before)
      end
      screen:command("tabclose!")
      repo.write_file("background.txt", { "after-close" })
      vim.wait(700)
      h.assert_no_errors(screen)
      assert.is_nil(screen:exec("return refresh_session()"))
    end)
  end)
end

for _, backend in ipairs({ "native", "polling" }) do
  describe("missing merge stage refresh / " .. backend, function()
    local repo, screen
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

    for _, shape in ipairs({ "add/add", "deleted by us", "deleted by them" }) do
      it("settles and refreshes " .. shape .. " conflicts", function()
        repo = h.repo()
        if shape == "add/add" then
          repo.git("rm a.txt")
          repo.git("commit -m remove-base")
        end
        repo.git("checkout -b incoming")
        if shape == "deleted by them" then
          repo.git("rm a.txt")
        else
          repo.write_file("a.txt", { "start", "incoming", "context", "end", "tail" })
        end
        repo.git("add -A")
        repo.git("commit -m incoming")
        repo.git("checkout main")
        if shape == "deleted by us" then
          repo.git("rm a.txt")
        else
          repo.write_file("a.txt", { "start", "current", "context", "end", "tail" })
        end
        repo.git("add -A")
        repo.git("commit -m current")
        local _, code = repo.git("merge incoming --no-edit", 1)
        assert.equals(1, code)
        screen = h.screen(backend, "side-by-side")
        h.open(screen, repo)
        local side = shape == "deleted by us" and "original" or "modified"
        screen:exec("vim.api.nvim_set_current_win(refresh_session()[(...) .. '_win'])", { side })
        h.feed(screen, "ggzt")
        local expected = h.panes(screen)
        local before = h.checkpoint(screen)
        repo.write_file("background.txt", { "changed" })
        h.wait_event(screen, before)
        h.preserved(screen, expected, 200)
        replace_current_stage(repo, shape == "deleted by us" and 3 or 2)
        h.expect_text(screen, side, "current-B")
        h.idle(screen)
      end)
    end
  end)
end
