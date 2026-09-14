-- Opening the history panel selects the newest commit's first file by itself,
-- so the diff pane is not left empty. In tree view that file may sit inside a
-- directory node, which has to be expanded to reach it.
--
-- Neither had coverage: stubbing the selection, or the directory expansion,
-- left the whole suite green.

local h = require("tests.support")
h.ensure_plugin_loaded()

--- Wait until the history tab has a diff session with content on both sides.
local function wait_for_diff(timeout)
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage
  local ok = vim.wait(timeout or 15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.modified_bufnr and vim.api.nvim_buf_is_valid(s.modified_bufnr) then
        local text = table.concat(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, -1, false), "\n")
        if #vim.trim(text) > 0 then
          tabpage = tp
          return true
        end
      end
    end
    return false
  end, 50)
  return ok, tabpage
end

describe("history opens on a file", function()
  local repo, saved_cwd

  before_each(function()
    require("codediff").setup({})
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    if saved_cwd and vim.fn.isdirectory(saved_cwd) == 1 then
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
  end)

  it("selects the newest commit's file without being asked", function()
    repo.write_file("file.txt", { "version 1" })
    repo.git("add .")
    repo.git("commit -m first")
    repo.write_file("file.txt", { "VERSION 2" })
    repo.git("add .")
    repo.git("commit -m second")

    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("edit " .. repo.path("file.txt"))
    vim.cmd("CodeDiff history")

    local ok, tabpage = wait_for_diff()
    assert.is_true(ok, "history should open a diff on the first file by itself")

    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    local modified = table.concat(vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    h.assert_contains(modified, "VERSION 2", "should show the newest commit's content")
  end)

  it("reaches a file nested in a directory", function()
    -- The first file of this commit is under a directory, so the tree has to
    -- expand it before there is a file node to select.
    vim.fn.mkdir(repo.dir .. "/src/deep", "p")
    vim.fn.writefile({ "nested one" }, repo.dir .. "/src/deep/nested.txt")
    repo.git("add .")
    repo.git("commit -m first")
    vim.fn.writefile({ "NESTED TWO" }, repo.dir .. "/src/deep/nested.txt")
    repo.git("add .")
    repo.git("commit -m second")

    require("codediff").setup({ history = { view_mode = "tree" } })

    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("edit " .. repo.dir .. "/src/deep/nested.txt")
    vim.cmd("CodeDiff history")

    local ok, tabpage = wait_for_diff()
    assert.is_true(ok, "history should walk into directories to find a file")

    local session = require("codediff.ui.lifecycle").get_session(tabpage)
    local modified = table.concat(vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    h.assert_contains(modified, "NESTED TWO", "should show the nested file's newest content")
  end)
end)
