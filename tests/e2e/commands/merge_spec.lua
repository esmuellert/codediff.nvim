-- Public merge-base and three-way merge commands against real Git fixtures.
local h = require("tests.support")
h.ensure_plugin_loaded()

describe("CodeDiff file A...B", function()
  local repo, saved_cwd

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    -- main and feature share a base commit, then each moves on. A...B compares
    -- against that shared base rather than against B's tip.
    repo.write_file("f.txt", { "base", "shared" })
    repo.git("add -A")
    repo.git("commit -qm base")
    repo.git("checkout -qb feature")
    repo.write_file("f.txt", { "FEATURE", "shared" })
    repo.git("commit -qam feature")
    repo.git("checkout -q main")
    repo.write_file("f.txt", { "MAIN", "shared" })
    repo.git("commit -qam main")
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

  it("compares against the merge base, not the branch tip", function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("edit " .. repo.path("f.txt"))
    vim.cmd("CodeDiff file feature...main")

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local s = lifecycle.get_session(tp)
          if s and s.original_bufnr and vim.api.nvim_buf_is_valid(s.original_bufnr) then
            local left = table.concat(vim.api.nvim_buf_get_lines(s.original_bufnr, 0, -1, false), "\n")
            if #vim.trim(left) > 0 then
              tabpage = tp
              return true
            end
          end
        end
        return false
      end, 50),
      "A...B should open a diff"
    )

    local session = lifecycle.get_session(tabpage)
    local left = table.concat(vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false), "\n")

    -- The merge base is the commit both branches came from.
    h.assert_contains(left, "base", "left side should be the merge base")
    assert.is_nil(left:find("FEATURE", 1, true), "left side must not be feature's tip")
  end)
end)

describe("CodeDiff merge", function()
  local repo, saved_cwd

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    repo.write_file("conf.txt", { "base1", "base2", "base3" })
    repo.git("add -A")
    repo.git("commit -qm base")
    repo.git("checkout -qb feature")
    repo.write_file("conf.txt", { "FEATURE1", "base2", "base3" })
    repo.git("commit -qam feature")
    repo.git("checkout -q main")
    repo.write_file("conf.txt", { "MAIN1", "base2", "base3" })
    repo.git("commit -qam main")
    local out = repo.git("merge feature --no-edit")
    assert.is_true(out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
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

  it("opens the three-way merge view with a result pane", function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("CodeDiff merge conf.txt")

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local s = lifecycle.get_session(tp)
          if s and s.result_win and vim.api.nvim_win_is_valid(s.result_win) then
            tabpage = tp
            return true
          end
        end
        return false
      end, 50),
      ":CodeDiff merge should open a result pane"
    )

    local session = lifecycle.get_session(tabpage)
    assert.is_true(session.merge == true, "session should be a merge view")
    assert.not_equal(session.original_win, session.modified_win, "OURS and THEIRS need their own windows")

    local ours = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.original_win), 0, -1, false), "\n")
    local theirs = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(session.modified_win), 0, -1, false), "\n")
    assert.is_true(
      (ours:find("MAIN1", 1, true) ~= nil and theirs:find("FEATURE1", 1, true) ~= nil) or (ours:find("FEATURE1", 1, true) ~= nil and theirs:find("MAIN1", 1, true) ~= nil),
      "the two panes should hold the two sides of the conflict"
    )
  end)
end)
