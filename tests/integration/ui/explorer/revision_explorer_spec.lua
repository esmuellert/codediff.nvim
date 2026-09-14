-- `:CodeDiff HEAD~1` takes its own branch of the file-select handler, which
-- had no coverage. What separates it from the fallback is renames: it reads
-- the left side from the file's old name, which is what it was called at that
-- revision. An unrenamed file cannot tell the two apart, so the rename is the
-- test -- and it has to be one `-M` will report, hence a file long enough to
-- stay recognisable after an edit.

local h = require("tests.support")

describe("explorer opened against a revision", function()
  local repo, saved_cwd

  before_each(function()
    h.ensure_plugin_loaded()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    repo.write_file("before.txt", { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "OLD" })
    repo.git("add -A")
    repo.git("commit -qm first")
    repo.git("mv before.txt after.txt")
    repo.write_file("after.txt", { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "RENAMED" })
    repo.git("add -A")
    repo.git("commit -qm renamed")
    repo.write_file("after.txt", { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "WORKING" })
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
  end)

  after_each(function()
    if saved_cwd and vim.fn.isdirectory(saved_cwd) == 1 then
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end
    require("codediff.ui.lifecycle").cleanup_all()
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  it("reads a renamed file's left side from its old name", function()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()

    -- Assert on the explorer's own first selection: a hand-made select
    -- afterwards would only repeat work already done.
    vim.cmd("CodeDiff HEAD~1")

    local tabpage
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local e = lifecycle.get_panel_view(tp)
          if e and e.winid and vim.api.nvim_win_is_valid(e.winid) then
            local s = lifecycle.get_session(tp)
            if s and s.original_bufnr and s.modified_bufnr and vim.api.nvim_buf_is_valid(s.original_bufnr) and vim.api.nvim_buf_is_valid(s.modified_bufnr) then
              -- Wait for content, not for the session: the diff result is set
              -- before both sides have finished loading.
              local l = table.concat(vim.api.nvim_buf_get_lines(s.original_bufnr, 0, -1, false), "\n")
              local r = table.concat(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, -1, false), "\n")
              if #l > 0 and r:find("WORKING", 1, true) then
                tabpage = tp
                return true
              end
            end
          end
        end
        return false
      end, 50),
      "revision explorer should open with both sides loaded"
    )

    local session = lifecycle.get_session(tabpage)
    local left = table.concat(vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false), "\n")
    local right = table.concat(vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")

    h.assert_contains(right, "WORKING", "right side should be the working tree")

    -- before.txt is the name the file had at HEAD~1; reading after.txt there
    -- finds nothing, which is what an empty left side looks like.
    h.assert_contains(left, "OLD", "left side must hold the file's content at HEAD~1")
    assert.equals("before.txt", session.original.relative, "left side must be read from the old name")
  end)
end)
