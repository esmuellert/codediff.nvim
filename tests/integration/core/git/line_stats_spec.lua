local config = require("codediff.config")
local git = require("codediff.core.git")
local h = require("tests.support")

local get_file = function(files, path)
  for _, file in ipairs(files or {}) do
    if file.path == path then
      return file
    end
  end
end

local await_result = function(invoke)
  local done = false
  local callback_error
  local result
  invoke(function(err, value)
    callback_error = err
    result = value
    done = true
  end)
  assert.is_true(vim.wait(3000, function()
    return done
  end, 20))
  return callback_error, result
end

local expect_result = function(invoke)
  local err, result = await_result(invoke)
  assert.is_nil(err)
  assert.is_not_nil(result)
  return result
end

local write_raw_file = function(path, contents)
  local uv = vim.uv or vim.loop
  local fd = assert(uv.fs_open(path, "w", 420))
  uv.fs_write(fd, contents, 0)
  uv.fs_close(fd)
end

local commit_all = function(repo, message)
  repo.git("add -A")
  repo.git("commit -m " .. message)
  return vim.trim(repo.git("rev-parse HEAD"))
end

describe("Git line stats", function()
  local repo
  local base_revision

  before_each(function()
    config.options = vim.deepcopy(config.defaults)
    config.options.explorer.line_stats.enabled = true
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "one", "two" })
    repo.write_file("renamed.txt", { "same" })
    repo.write_file("deleted.txt", { "gone", "soon" })
    repo.write_file("conflict.txt", { "base" })
    repo.write_file("src/included.txt", { "base" })
    repo.write_file("outside.txt", { "base" })
    base_revision = commit_all(repo, "initial")
  end)

  after_each(function()
    config.options = vim.deepcopy(config.defaults)
    repo.cleanup()
  end)

  it("adds separate staged, unstaged, rename, deletion, and binary stats", function()
    repo.write_file("tracked.txt", { "one", "staged", "three" })
    repo.git("add tracked.txt")
    repo.write_file("tracked.txt", { "one", "working", "three", "four" })
    repo.write_file("staged.txt", { "alpha", "beta" })
    write_raw_file(repo.path("binary.dat"), "binary\0content")
    repo.git("add staged.txt binary.dat")
    repo.git("mv renamed.txt moved.txt")
    repo.git("rm deleted.txt")

    local result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback)
    end)

    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.staged, "tracked.txt").line_stats)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.staged, "staged.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = false }, get_file(result.staged, "moved.txt").line_stats)
    assert.same({ insertions = 0, deletions = 2, binary = false }, get_file(result.staged, "deleted.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = true }, get_file(result.staged, "binary.dat").line_stats)
  end)

  it("optionally counts bounded untracked text and binary files", function()
    write_raw_file(repo.path("untracked.txt"), "first\nsecond")
    write_raw_file(repo.path("untracked.bin"), "binary\0content")

    local result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback)
    end)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    config.options.explorer.line_stats.count_untracked = true
    config.options.explorer.line_stats.max_untracked_bytes = 1
    result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback)
    end)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    config.options.explorer.line_stats.max_untracked_bytes = 1024 * 1024
    result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback)
    end)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "untracked.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = true }, get_file(result.unstaged, "untracked.bin").line_stats)
  end)

  it("adds aggregate working tree stats relative to one revision", function()
    repo.write_file("tracked.txt", { "one", "changed", "three" })
    repo.write_file("staged.txt", { "alpha", "beta" })
    repo.git("add staged.txt")
    repo.write_file("untracked.txt", { "first", "second" })

    local result = expect_result(function(callback)
      git.get_diff_revision_with_line_stats(base_revision, repo.dir, callback)
    end)
    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "staged.txt").line_stats)
    assert.is_nil(get_file(result.unstaged, "untracked.txt").line_stats)

    config.options.explorer.line_stats.count_untracked = true
    result = expect_result(function(callback)
      git.get_diff_revision_with_line_stats(base_revision, repo.dir, callback)
    end)
    assert.same({ insertions = 2, deletions = 0, binary = false }, get_file(result.unstaged, "untracked.txt").line_stats)
  end)

  it("adds destination-path stats between two revisions", function()
    repo.write_file("tracked.txt", { "one", "changed", "three" })
    repo.git("mv renamed.txt moved.txt")
    write_raw_file(repo.path("binary.dat"), "binary\0content")
    local target_revision = commit_all(repo, "changes")

    local result = expect_result(function(callback)
      git.get_diff_revisions_with_line_stats(base_revision, target_revision, repo.dir, callback)
    end)
    assert.same({ insertions = 2, deletions = 1, binary = false }, get_file(result.unstaged, "tracked.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = false }, get_file(result.unstaged, "moved.txt").line_stats)
    assert.same({ insertions = 0, deletions = 0, binary = true }, get_file(result.unstaged, "binary.dat").line_stats)
    assert.is_nil(get_file(result.unstaged, "renamed.txt"))
  end)

  it("attaches stats to conflicts", function()
    repo.git("checkout -b conflict-side")
    repo.write_file("conflict.txt", { "side" })
    commit_all(repo, "side")
    repo.git("checkout main")
    repo.write_file("conflict.txt", { "main" })
    commit_all(repo, "main")
    repo.git("merge conflict-side")

    local result = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback)
    end)
    local stats = get_file(result.conflicts, "conflict.txt").line_stats
    assert.is_not_nil(stats)
    assert.is_number(stats.insertions)
    assert.is_number(stats.deletions)
    assert.is_false(stats.binary)
  end)

  it("preserves pathspecs in all explorer modes", function()
    repo.write_file("src/included.txt", { "base", "included" })
    repo.write_file("outside.txt", { "base", "outside" })

    local status = expect_result(function(callback)
      git.get_status_with_line_stats(repo.dir, callback, { "src" })
    end)
    assert.is_not_nil(get_file(status.unstaged, "src/included.txt").line_stats)
    assert.is_nil(get_file(status.unstaged, "outside.txt"))

    local one_revision = expect_result(function(callback)
      git.get_diff_revision_with_line_stats(base_revision, repo.dir, callback, { "src" })
    end)
    assert.is_not_nil(get_file(one_revision.unstaged, "src/included.txt").line_stats)
    assert.is_nil(get_file(one_revision.unstaged, "outside.txt"))

    local target_revision = commit_all(repo, "pathspec")
    local two_revisions = expect_result(function(callback)
      git.get_diff_revisions_with_line_stats(base_revision, target_revision, repo.dir, callback, { "src" })
    end)
    assert.is_not_nil(get_file(two_revisions.unstaged, "src/included.txt").line_stats)
    assert.is_nil(get_file(two_revisions.unstaged, "outside.txt"))
  end)

  it("returns unchanged base results when disabled", function()
    repo.write_file("tracked.txt", { "one", "committed", "three" })
    local target_revision = commit_all(repo, "target")
    repo.write_file("tracked.txt", { "one", "working", "three", "four" })
    config.options.explorer.line_stats.enabled = false
    local cases = {
      {
        base = function(callback)
          git.get_status(repo.dir, callback, { "tracked.txt" })
        end,
        with_stats = function(callback)
          git.get_status_with_line_stats(repo.dir, callback, { "tracked.txt" })
        end,
      },
      {
        base = function(callback)
          git.get_diff_revision(target_revision, repo.dir, callback, { "tracked.txt" })
        end,
        with_stats = function(callback)
          git.get_diff_revision_with_line_stats(target_revision, repo.dir, callback, { "tracked.txt" })
        end,
      },
      {
        base = function(callback)
          git.get_diff_revisions(base_revision, target_revision, repo.dir, callback, { "tracked.txt" })
        end,
        with_stats = function(callback)
          git.get_diff_revisions_with_line_stats(base_revision, target_revision, repo.dir, callback, { "tracked.txt" })
        end,
      },
    }

    for _, case in ipairs(cases) do
      assert.same(expect_result(case.base), expect_result(case.with_stats))
    end
  end)

  it("propagates repository and revision errors", function()
    local missing_revision = "missing-line-stats-revision"
    local cases = {
      function(callback)
        git.get_status_with_line_stats(repo.path("missing"), callback)
      end,
      function(callback)
        git.get_diff_revision_with_line_stats(missing_revision, repo.dir, callback)
      end,
      function(callback)
        git.get_diff_revisions_with_line_stats(base_revision, missing_revision, repo.dir, callback)
      end,
    }

    for _, invoke in ipairs(cases) do
      local err, result = await_result(invoke)
      assert.is_not_nil(err)
      assert.is_nil(result)
    end
  end)
end)
