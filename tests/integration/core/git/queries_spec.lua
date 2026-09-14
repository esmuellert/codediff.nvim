-- Git queries run against isolated fixtures, never the source checkout's HEAD.
local git = require("codediff.core.git")
local h = require("tests.support")
local fixture = require("tests.fixtures.refresh_repo")
local config = require("codediff.config")

local function await(start)
  local result
  start(function(...)
    result = { n = select("#", ...), ... }
  end)
  assert.is_true(
    vim.wait(5000, function()
      return result ~= nil
    end, 20),
    "Git callback did not complete"
  )
  return unpack(result, 1, result.n)
end

describe("Git Integration", function()
  local repo, non_repo

  before_each(function()
    repo = fixture.new("history")
    non_repo = h.create_temp_dir()
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
    if non_repo then
      vim.fn.delete(non_repo, "rf")
    end
  end)

  it("Detects non-git directory", function()
    local err, root = await(function(done)
      git.get_git_root(non_repo, done)
    end)
    assert.is_not_nil(err)
    assert.is_nil(root)
  end)

  it("Gets git root for current repo", function()
    local err, root = await(function(done)
      git.get_git_root(repo.path("a.txt"), done)
    end)
    assert.is_nil(err)
    assert.equals(repo.dir, root)
  end)

  it("Error callback for invalid revision", function()
    local err, lines = await(function(done)
      git.get_file_content("invalid-revision-12345", repo.dir, "a.txt", done)
    end)
    assert.is_string(err)
    assert.is_nil(lines)
  end)

  it("Can retrieve file from HEAD (if in git repo)", function()
    local err, revision = await(function(done)
      git.resolve_revision("HEAD", repo.dir, done)
    end)
    assert.is_nil(err)
    assert.equals(repo.second, revision)
    local read_error, lines = await(function(done)
      git.get_file_content(revision, repo.dir, "a.txt", done)
    end)
    assert.is_nil(read_error)
    assert.same(repo.blob_lines("HEAD", "a.txt"), lines)
  end)

  it("Calculates relative path correctly", function()
    assert.equals("nested/deep/beta.txt", git.get_relative_path(repo.path("nested/deep/beta.txt"), repo.dir))
  end)

  it("Provides good error for missing file in revision", function()
    local err, lines = await(function(done)
      git.get_file_content(repo.second, repo.dir, "nonexistent_file_12345.txt", done)
    end)
    assert.is_string(err)
    assert.is_not_nil(err:find("nonexistent_file_12345.txt", 1, true))
    assert.is_nil(lines)
  end)

  it("Handles filenames with spaces", function()
    assert.equals("rename/renamed file.txt", git.get_relative_path(repo.path("rename/renamed file.txt"), repo.dir))
  end)

  it("Multiple async calls work independently", function()
    local results = {}
    for i, revision in ipairs({ repo.first, repo.second }) do
      git.get_file_content(revision, repo.dir, "a.txt", function(err, lines)
        results[i] = { err = err, lines = lines }
      end)
    end
    assert.is_true(vim.wait(5000, function()
      return results[1] ~= nil and results[2] ~= nil
    end, 20))
    assert.is_nil(results[1].err)
    assert.is_nil(results[2].err)
    assert.same(repo.blob_lines(repo.first, "a.txt"), results[1].lines)
    assert.same(repo.blob_lines(repo.second, "a.txt"), results[2].lines)
  end)

  it("LRU cache returns same content", function()
    local function read(done)
      git.get_file_content(repo.second, repo.dir, "a.txt", done)
    end
    local first_error, first = await(read)
    local second_error, second = await(read)
    assert.is_nil(first_error)
    assert.is_nil(second_error)
    assert.same(repo.blob_lines(repo.second, "a.txt"), first)
    assert.same(first, second)
    assert.are_not.equal(first, second, "cached reads must return independent arrays")
  end)

  it("get_merge_base returns merge-base commit", function()
    local err, revision = await(function(done)
      git.get_merge_base("HEAD~1", "HEAD", repo.dir, done)
    end)
    assert.is_nil(err)
    assert.equals(repo.first, revision)
  end)

  it("get_merge_base handles invalid revision", function()
    local err, revision = await(function(done)
      git.get_merge_base("nonexistent-branch-12345", "HEAD", repo.dir, done)
    end)
    assert.is_not_nil(err)
    assert.is_nil(revision)
  end)
end)

-- The untracked policy applies to both status and revision-comparison queries.
describe("Git untracked policy (#389)", function()
  local repo, previous

  before_each(function()
    previous = config.options.explorer.untracked
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "base" })
    repo.commit("initial")
    repo.write_file("tracked.txt", { "changed" })
    repo.write_file("newfile.txt", { "u" })
    repo.write_file("untracked_dir/nested.txt", { "n" })
  end)

  after_each(function()
    config.options.explorer.untracked = previous
    if repo then
      repo.cleanup()
    end
  end)

  local function unstaged_set(mode, revision)
    config.options.explorer.untracked = mode
    local err, status = await(function(done)
      if revision then
        git.get_diff_revision("HEAD", repo.dir, done)
      else
        git.get_status(repo.dir, done)
      end
    end)
    assert.is_nil(err)
    local paths = {}
    for _, file in ipairs(status.unstaged) do
      paths[file.path] = file.status
    end
    return paths
  end

  it("all lists every untracked file individually (get_status)", function()
    local paths = unstaged_set("all")
    assert.is_not_nil(paths["newfile.txt"])
    assert.is_not_nil(paths["untracked_dir/nested.txt"])
  end)

  it("normal collapses untracked directories (get_status)", function()
    local paths = unstaged_set("normal")
    assert.is_not_nil(paths["newfile.txt"])
    assert.is_nil(paths["untracked_dir/nested.txt"])
    assert.is_not_nil(paths["untracked_dir/"])
  end)

  it("no skips untracked files entirely — the hang fix (get_status)", function()
    local paths = unstaged_set("no")
    assert.is_nil(paths["newfile.txt"])
    assert.is_nil(paths["untracked_dir/nested.txt"])
    assert.is_not_nil(paths["tracked.txt"])
  end)

  it("no skips the ls-files untracked scan (get_diff_revision)", function()
    local paths = unstaged_set("no", true)
    assert.is_nil(paths["newfile.txt"])
    assert.is_not_nil(paths["tracked.txt"])
  end)

  it("normal collapses untracked directories (get_diff_revision)", function()
    local paths = unstaged_set("normal", true)
    assert.is_not_nil(paths["untracked_dir/"])
    assert.is_nil(paths["untracked_dir/nested.txt"])
  end)

  it("defaults to all when the config value is invalid", function()
    local paths = unstaged_set("bogus")
    assert.is_not_nil(paths["untracked_dir/nested.txt"])
  end)
end)

-- A read-only poll must not contend with staging for index.lock.
describe("Git read-only queries do not write the index (#494)", function()
  local repo

  before_each(function()
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "base" })
    repo.commit("initial")
    -- Older than the index even on filesystems with coarse mtime resolution.
    local past = os.time() - 60
    assert((vim.uv or vim.loop).fs_utime(repo.path("tracked.txt"), past, past))
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
  end)

  local function index_bytes()
    return table.concat(vim.fn.readfile(repo.git_path("index"), "b"), "\n")
  end

  it("get_status leaves .git/index untouched", function()
    local before = index_bytes()
    local err = await(function(done)
      git.get_status(repo.dir, done)
    end)
    assert.is_nil(err)
    assert.equals(before, index_bytes(), "read-only status must not rewrite the index")
  end)

  it("read-only queries still succeed while another git process holds index.lock", function()
    vim.fn.writefile({ "" }, repo.git_path("index.lock"))
    local err = await(function(done)
      git.get_diff_revision("HEAD", repo.dir, done)
    end)
    assert.is_nil(err, "a held index.lock must not fail a read-only query")
  end)
end)

-- Bootstrap configuration outranks Windows runners' autocrlf setting.
describe("Git output is free of line-ending warnings (#494)", function()
  local repo

  before_each(function()
    repo = h.create_temp_git_repo()
    repo.command({ "config", "core.autocrlf", "true" })
    repo.write_file("file1.txt", { "alpha", "beta", "gamma" })
    repo.commit("initial")
    repo.write_file("file1.txt", { "alpha", "BETA", "gamma" })
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
  end)

  it("git_cmd output carries no CRLF conversion warning", function()
    local output = repo.git("diff --name-only")
    assert.is_nil(output:match("LF will be replaced by CRLF"), "line-ending warning must not pollute Git output")
    assert.equals("file1.txt", vim.trim(output))
  end)

  it("core.autocrlf is pinned off for every git process", function()
    assert.equals("false", vim.trim(repo.command({ "config", "--get", "core.autocrlf" })))
  end)
end)
