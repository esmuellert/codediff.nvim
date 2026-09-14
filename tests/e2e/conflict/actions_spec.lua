local h = require("tests.support.e2e")
local fixture = require("tests.fixtures.refresh_repo")

local function compose(choice, all, first)
  local seed = vim.deepcopy(fixture.files["merge.txt"])
  seed[8], seed[12] = "incoming-only", "current-only"
  if not choice then
    return seed
  end
  local result = {}
  for line, text in ipairs(seed) do
    if line == 4 or all and line == 16 then
      local suffix = line == 4 and "one" or "two"
      if choice == "both" then
        result[#result + 1] = first .. "-" .. suffix
        result[#result + 1] = (first == "current" and "incoming" or "current") .. "-" .. suffix
      else
        result[#result + 1] = choice .. "-" .. suffix
      end
    else
      result[#result + 1] = text
    end
  end
  return result
end

for _, backend in ipairs({ "native", "polling" }) do
  for _, ours in ipairs({ "left", "right" }) do
    for _, position in ipairs({ "bottom", "center" }) do
      describe("merge actions E2E / " .. backend .. " / ours " .. ours .. " / " .. position, function()
        local repo, screen
        local current_side = ours == "left" and "original" or "modified"
        -- The existing bindings address input 1 / input 2. Accept-both starts
        -- with the focused input; accept-all-both defaults to input 1.
        local function role(choice)
          if ours == "left" then
            if choice == "incoming" then
              return "current"
            end
            if choice == "current" then
              return "incoming"
            end
          end
          return choice
        end
        local function expected(choice, all)
          local first = all and (ours == "left" and "current" or "incoming") or "current"
          return compose(role(choice), all, first)
        end
        local function visible(choice, suffix)
          return (choice == "both" and "current" or role(choice)) .. "-" .. (suffix or "one")
        end
        before_each(function()
          repo = h.repo("merge")
          screen = h.screen(backend, "side-by-side", { diff = { conflict_ours_position = ours, conflict_result_position = position } })
          screen:exec([[
            for name, color in pairs({ CodeDiffConflictSign = '#eeee00', CodeDiffConflictSignResolved = '#777777',
              CodeDiffConflictSignAccepted = '#00ff00', CodeDiffConflictSignRejected = '#ff0000' }) do
              vim.api.nvim_set_hl(0, name, { fg = color })
            end
          ]])
          h.open(screen, repo, "CodeDiff -- merge.txt", "merge.txt", "merge.txt")
          h.expect_lines(screen, "result", expected())
        end)
        after_each(function()
          h.close(screen, repo)
          screen, repo = nil, nil
        end)
        local function expect_result(lines, text)
          h.expect_lines(screen, "result", lines)
          h.reveal(screen, "result", text)
        end
        local function act(name)
          h.action(screen, "conflict", name, current_side, 4)
        end

        it("[C01] seeds one-sided changes and renders unresolved conflict markers", function()
          h.reveal(screen, "result", "base-one")
          local row, col = h.cell_for(screen, "result", "base-one")
          assert.equals("[", screen:text(row, col - 2, 1))
          assert.equals(0xeeee00, screen:highlight(row, col - 2).foreground)
          assert.equals("base-one", repo.blob_lines(":1", "merge.txt")[4])
          assert.equals("current-one", repo.blob_lines(":2", "merge.txt")[4])
          assert.equals("incoming-one", repo.blob_lines(":3", "merge.txt")[4])
        end)

        for i, choice in ipairs({ "incoming", "current", "both" }) do
          it(string.format("[C%02d] runs accept_%s for only the current conflict", i + 1, choice), function()
            act("accept_" .. choice)
            expect_result(expected(choice), visible(choice))
            assert.is_true(repo.command({ "ls-files", "--unmerged", "merge.txt" }) ~= "", "resolution must not implicitly stage the file")
          end)
        end

        it("[C05] undo, redo and discard restore the Result and marker state", function()
          act("accept_both")
          expect_result(expected("both"), "current-one")
          h.feed(screen, "u")
          expect_result(expected(), "base-one")
          h.feed(screen, "<C-r>")
          expect_result(expected("both"), "current-one")
          act("discard")
          expect_result(expected(), "base-one")
          local row, col = h.cell_for(screen, "result", "base-one")
          assert.equals(0xeeee00, screen:highlight(row, col - 2).foreground)
        end)

        for i, choice in ipairs({ "incoming", "current", "both" }) do
          it(string.format("[C%02d] runs accept_all_%s including the later conflict", i + 5, choice), function()
            act("accept_all_" .. choice)
            expect_result(expected(choice, true), visible(choice, "two"))
          end)
        end

        it("[C09] discard-all resets resolutions but retains automatic one-sided edits", function()
          act("accept_all_both")
          expect_result(expected("both", true), "current-two")
          act("discard_all")
          expect_result(expected(), "base-two")
        end)

        for i, choice in ipairs({ "incoming", "current" }) do
          it(string.format("[C%02d] numbered diffget obtains input %d from the Result pane", i + 9, i), function()
            h.action(screen, "conflict", "diffget_" .. choice, "result", 4)
            expect_result(expected(choice), visible(choice))
          end)
        end

        it("[C12] next and previous conflict keys use the displayed pane's coordinates", function()
          h.action(screen, "conflict", "next_conflict", current_side, 1)
          assert.equals(4, screen:exec("return vim.api.nvim_win_get_cursor(0)[1]"))
          h.action(screen, "conflict", "next_conflict")
          assert.equals(16, screen:exec("return vim.api.nvim_win_get_cursor(0)[1]"))
          h.action(screen, "conflict", "prev_conflict")
          assert.equals(4, screen:exec("return vim.api.nvim_win_get_cursor(0)[1]"))
          h.expect_text(screen, current_side, "current-one")
        end)

        it("[C13] saves a resolution and preserves it through unrelated index changes", function()
          act("accept_current")
          expect_result(expected("current"), visible("current"))
          h.feed(screen, ":write<CR>")
          assert.same(expected("current"), repo.read_file("merge.txt"))
          h.idle(screen)
          local before, event = h.panes(screen), h.checkpoint(screen)
          repo.write_file("background.txt", { "unrelated staged edit" })
          repo.command({ "add", "background.txt" })
          h.wait_event(screen, event)
          h.preserved(screen, before, 100)
        end)

        it("[C14] cancel and discard on quit respect the real unsaved-results dialog", function()
          act("accept_current")
          expect_result(expected("current"), visible("current"))
          h.confirm(screen, h.key(screen, "view", "quit"), "Discard changes and close", "c")
          h.expect_lines(screen, "result", expected("current"))
          h.confirm(screen, h.key(screen, "view", "quit"), "Discard changes and close", "d")
          screen:await(function()
            return screen:exec("return refresh_session() == nil")
          end)
          assert.is_true(table.concat(repo.read_file("merge.txt"), "\n"):find("<<<<<<<", 1, true) ~= nil)
          assert.is_true(repo.command({ "ls-files", "--unmerged", "merge.txt" }) ~= "")
        end)

        it("[C15] saving and staging a resolved file leaves merge mode cleanly", function()
          act("accept_all_current")
          expect_result(expected("current", true), visible("current", "two"))
          h.feed(screen, ":write<CR>")
          h.action(screen, "view", "toggle_stage", current_side, 4)
          screen:await(function()
            return screen:exec("return refresh_session().result_bufnr == nil and refresh_session().modified_revision == ':0'")
          end)
          h.expect_lines(screen, "modified", expected("current", true))
          h.reveal(screen, "modified", visible("current", "two"))
          assert.equals("", repo.command({ "ls-files", "--unmerged", "merge.txt" }))
          assert.same(expected("current", true), repo.blob_lines(":0", "merge.txt"))
        end)
      end)
    end
  end
end
