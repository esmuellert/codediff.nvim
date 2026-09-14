local repositories = require("tests.framework.repository")

describe("isolated fixture worktrees", function()
  local repos
  before_each(function()
    repos = {}
  end)
  after_each(function()
    for _, repo in ipairs(repos) do
      repo.cleanup()
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

  for _, cleanup_error in ipairs({ false, true }) do
    it(cleanup_error and "reports cleanup failures even when fixture setup skips a case" or "skips unavailable fixture backends and still runs cleanup", function()
      local repo = new()
      local script = repo.write_file("pending_fixture.lua", {
        "local repo",
        "describe('unavailable backend', function()",
        "  before_each(function()",
        "    repo = require('tests.framework.repository').new({ unborn = true })",
        "    pending('backend unavailable')",
        "  end)",
        "  after_each(function()",
        "    repo.cleanup()",
        cleanup_error and "    error('expected cleanup failure')" or "    assert(vim.fn.isdirectory(repo.root) == 0)",
        "  end)",
        "  it('does not run the body', function() error('body must not run') end)",
        "end)",
      })
      local result = vim
        .system({
          vim.v.progpath,
          "--headless",
          "--noplugin",
          "-u",
          "tests/init.lua",
          "-c",
          "lua require('tests.framework').run_and_exit(" .. string.format("%q", script) .. ")",
        }, { text = true })
        :wait()
      assert.equals(cleanup_error and 1 or 0, result.code, (result.stdout or "") .. (result.stderr or ""))
    end)
  end

  it("removes the worktree and its Git metadata and leaves a valid current directory", function()
    local repo = new()
    vim.fn.chdir(repo.dir)
    repo.cleanup()
    assert.equals(0, vim.fn.isdirectory(repo.root))
    assert.equals(1, vim.fn.isdirectory(vim.fn.getcwd()))
    repo.cleanup()
  end)
end)
