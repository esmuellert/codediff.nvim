local repositories = require("tests.support.repository")

describe("isolated fixture worktrees", function()
  local repos, tabs
  before_each(function()
    repos, tabs = {}, {}
  end)
  after_each(function()
    for _, repo in ipairs(repos) do
      repo.cleanup()
    end
    for _, tab in ipairs(tabs) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd("tabclose!")
      end
    end
  end)
  local function new(opts)
    local repo = repositories.new(opts)
    repos[#repos + 1] = repo
    return repo
  end

  it("refuses repository overrides that could redirect commands outside the fixture", function()
    local saved = vim.env.GIT_DIR
    vim.env.GIT_DIR = "/not-a-fixture"
    local ok, err = pcall(repositories.new)
    vim.env.GIT_DIR = saved
    assert.is_false(ok)
    assert.is_not_nil(tostring(err):find("inherited GIT_DIR", 1, true))
  end)

  it("preserves an unborn main branch and creates a parentless first commit", function()
    local repo = new({ unborn = true })
    assert.equals(1, vim.fn.filereadable(repo.path(".git")))
    assert.equals(1, select("#", repo.git_path("index")), "git_path returns only a path, not gsub's replacement count")
    assert.equals("true", vim.trim(repo.command({ "rev-parse", "--is-inside-work-tree" })))
    assert.equals("main", vim.trim(repo.command({ "symbolic-ref", "--short", "HEAD" })))
    assert.equals("", repo.command({ "remote" }), "fixtures must not retain a remote pointing at their seed")
    local _, code = repo.git({ "rev-parse", "--verify", "HEAD" })
    assert.not_equal(0, code)
    repo.write_file("first.txt", { "first" })
    repo.commit("first")
    assert.equals("", vim.trim(repo.command({ "log", "-1", "--format=%P" })))
  end)

  it("isolates refs, indexes and objects between worktrees from the same seed", function()
    local first, second = new(), new()
    local before = vim.trim(second.command({ "rev-parse", "HEAD" }))
    assert.equals(before, vim.trim(first.command({ "rev-parse", "HEAD" })))
    assert.not_equal(first.common_dir, second.common_dir)
    assert.not_equal(first.git_path("index"), second.git_path("index"))
    first.write_file("one.txt", { "changed" })
    first.commit("first only")
    first.command({ "branch", "shared-name" })
    second.command({ "branch", "shared-name" })
    assert.equals(before, vim.trim(second.command({ "rev-parse", "shared-name" })))
    assert.not_equal(before, vim.trim(first.command({ "rev-parse", "shared-name" })))
    first.write_file("staged.txt", { "only first" })
    first.command({ "add", "staged.txt" })
    assert.equals("", second.command({ "status", "--porcelain" }))
    assert.equals("", second.command({ "ls-files", "staged.txt" }))
  end)

  it("writes index content without exposing an intermediate working-tree change", function()
    local repo = new()
    repo.write_file("a.txt", { "working" })
    local oid = repo.write_index("a.txt", { "index" })
    assert.same({ "working" }, repo.read_file("a.txt"))
    assert.same({ "index" }, repo.blob_lines(":0", "a.txt"))
    assert.equals(oid, vim.trim(repo.command({ "rev-parse", ":0:a.txt" })))
  end)

  it("retires only a plugin-aware fixture's sessions before removing its directory", function()
    local h = require("tests.support")
    local lifecycle = require("codediff.ui.lifecycle")
    local path = require("codediff.core.path")
    local first, second = h.create_temp_git_repo(), h.create_temp_git_repo()
    repos[#repos + 1], repos[#repos + 2] = first, second
    local function open(repo)
      repo.write_file("a.txt", { "content" })
      vim.cmd("tabnew")
      local tab, win, buf = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      tabs[#tabs + 1] = tab
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "content" })
      lifecycle.create_session(tab, {
        git_root = repo.dir,
        original = path.make_ref("a.txt", repo.dir),
        modified = path.make_ref("a.txt", repo.dir),
      }, { original_bufnr = buf, modified_bufnr = buf, original_win = win, modified_win = win, lines_diff = { changes = {} } })
      return tab, require("codediff.ui.refresh").attach(tab)
    end
    local first_tab, first_controller = open(first)
    local second_tab, second_controller = open(second)
    first.cleanup()
    assert.is_nil(lifecycle.get_session(first_tab))
    assert.is_true(first_controller.closed)
    assert.equals(0, vim.fn.isdirectory(first.root))
    assert.is_not_nil(lifecycle.get_session(second_tab))
    assert.is_true(second_controller:valid())
    assert.equals(1, vim.fn.isdirectory(second.root))
  end)

  it("also supplies regular Git-directory fixtures through the same factory", function()
    local repo = new({ worktree = false, unborn = true })
    assert.equals(1, vim.fn.isdirectory(repo.path(".git")))
    assert.equals("", repo.command({ "remote" }))
    repo.write_file("first.txt", { "first" })
    repo.commit("first")
    assert.equals("", vim.trim(repo.command({ "log", "-1", "--format=%P" })))
  end)

  it("supplies empty bare repositories for local remote fixtures", function()
    local repo = new({ bare = true, unborn = true })
    assert.equals("true", vim.trim(repo.command({ "rev-parse", "--is-bare-repository" })))
    local _, code = repo.git({ "rev-parse", "--verify", "HEAD" })
    assert.not_equal(0, code)
    assert.equals("", repo.command({ "remote" }))
  end)

  it("removes the worktree and its Git metadata and leaves a valid current directory", function()
    local repo = new()
    vim.fn.chdir(repo.dir)
    repo.cleanup()
    assert.equals(0, vim.fn.isdirectory(repo.root))
    assert.equals(1, vim.fn.isdirectory(vim.fn.getcwd()))
    repo.cleanup()
  end)
end)
