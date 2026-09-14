-- What the history panel lists under a commit.
--
-- history_file_filter_spec covers filter.apply itself; this covers whether
-- session data reaches the history view with the filter applied.

local h = require("tests.support")
h.ensure_plugin_loaded()

--- Expand the newest commit and return the panel's rendered lines.
--- Commits load their files on demand, through the same entry point the <CR>
--- mapping and the refresh watcher use.
local function expand_newest_commit()
  local lifecycle = require("codediff.ui.lifecycle")
  local history
  local opened = vim.wait(15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local view = lifecycle.get_panel_view(tp)
      if view and view.load_commit_files and view.tree then
        history = view
        return true
      end
    end
    return false
  end, 50)
  if not opened then
    return nil
  end

  local commit_node
  for _, node in ipairs(history.tree:get_nodes()) do
    if node.data and node.data.type == "commit" then
      commit_node = node
      break
    end
  end
  if not commit_node then
    return nil
  end

  local done = false
  history.load_commit_files(commit_node, function()
    done = true
  end)
  if not vim.wait(10000, function()
    return done
  end, 50) then
    return nil
  end
  vim.wait(300)

  local _, buf = h.find_window_by_filetype("codediff-history")
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("history panel file list", function()
  local repo, saved_cwd

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    -- git names a commit's files by diffing against its parent, so the commit
    -- under test needs one before it.
    vim.fn.writefile({ "base" }, repo.dir .. "/base.txt")
    repo.git("add .")
    repo.git("commit -m base")
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

  it("rebuilds supplied commit data without fetching files from the renderer", function()
    repo.write_file("kept.txt", { "content" })
    repo.git("add .")
    repo.git("commit -m second")
    require("codediff").setup({})
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("CodeDiff history")
    assert.is_not_nil(expand_newest_commit())
    local session = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
    local history = session.panel.view
    assert.is_true(history.data == session.panel.data)
    local git = require("codediff.core.git")
    local get_files = git.get_commit_files
    git.get_commit_files = function()
      error("history rendering must not fetch commit files")
    end
    local ok, err = pcall(history.on_data, session.panel.data, { list = true })
    git.get_commit_files = get_files
    assert.is_true(ok, tostring(err))
    local text = table.concat(vim.api.nvim_buf_get_lines(history.bufnr, 0, -1, false), "\n")
    h.assert_contains(text, "kept.txt", "expanded files should render from session data")
  end)

  it("hides files matching explorer.file_filter.ignore", function()
    vim.fn.mkdir(repo.dir .. "/dist", "p")
    vim.fn.writefile({ "keep me" }, repo.dir .. "/kept.txt")
    vim.fn.writefile({ "built" }, repo.dir .. "/dist/bundle.js")
    repo.git("add .")
    repo.git("commit -m second")

    require("codediff").setup({ explorer = { file_filter = { ignore = { "dist/**" } } } })

    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("CodeDiff history")

    local text = expand_newest_commit()
    assert.is_not_nil(text, "history panel should render an expanded commit")

    h.assert_contains(text, "kept.txt", "an unfiltered file should be listed")
    assert.is_nil(text:find("bundle.js", 1, true), "an ignored file must not be listed")
  end)
end)
