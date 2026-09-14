-- Test: Line-range history (git log -L) for issue #220
-- Validates git log -L argument building, output parsing, and command-level integration

local git = require('codediff.core.git')

-- Helper: create a temp git repo with multiple commits affecting different line ranges
local function create_test_repo()
  local repo = require("tests.framework.repository").new({ unborn = true })
  local function run_git(args)
    return repo.git(args, 0)
  end
  local write_file = repo.write_file

  -- Commit 1: initial file with header + two functions
  write_file("test.lua", {
    "-- header line 1",
    "-- header line 2",
    "-- header line 3",
    "function foo()",
    "  return 1",
    "end",
    "function bar()",
    "  return 2",
    "end",
  })
  run_git("add .")
  run_git('commit -m "initial commit"')

  -- Commit 2: change foo (lines 4-6)
  write_file("test.lua", {
    "-- header line 1",
    "-- header line 2",
    "-- header line 3",
    "function foo()",
    "  return 42",
    "end",
    "function bar()",
    "  return 2",
    "end",
  })
  run_git("add .")
  run_git('commit -m "update foo"')

  -- Commit 3: change bar (lines 7-9)
  write_file("test.lua", {
    "-- header line 1",
    "-- header line 2",
    "-- header line 3",
    "function foo()",
    "  return 42",
    "end",
    "function bar()",
    "  return 99",
    "end",
  })
  run_git("add .")
  run_git('commit -m "update bar"')

  -- Commit 4: change header (lines 1-3)
  write_file("test.lua", {
    "-- new header 1",
    "-- new header 2",
    "-- new header 3",
    "function foo()",
    "  return 42",
    "end",
    "function bar()",
    "  return 99",
    "end",
  })
  run_git("add .")
  run_git('commit -m "update header"')

  return repo
end

describe("Line-range History - get_commit_list with line_range", function()
  local repo

  before_each(function()
    repo = create_test_repo()
  end)

  after_each(function()
    if repo then repo.cleanup() end
  end)

  it("filters commits to only those touching the line range", function()
    local done = false
    local result_commits = nil
    local result_err = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
    }, function(err, commits)
      result_err = err
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done, "Callback should complete")
    assert.is_nil(result_err, "Should not error")
    assert.is_not_nil(result_commits)
    -- Lines 4-6 (foo function): touched by 'initial commit' and 'update foo' only
    assert.equals(2, #result_commits, "Should have 2 commits for lines 4-6")
    assert.matches("update foo", result_commits[1].subject)
    assert.matches("initial", result_commits[2].subject)
  end)

  it("returns all commits when no line_range is set", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.equals(4, #result_commits, "Should have all 4 commits without line_range")
  end)

  it("filters commits for bar function line range", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 7, 9 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.is_not_nil(result_commits)
    -- Lines 7-9 (bar function): touched by 'initial commit' and 'update bar' only
    assert.equals(2, #result_commits, "Should have 2 commits for lines 7-9")
    assert.matches("update bar", result_commits[1].subject)
    assert.matches("initial", result_commits[2].subject)
  end)

  it("filters commits for header line range", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 1, 3 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.is_not_nil(result_commits)
    -- Lines 1-3 (header): touched by 'initial commit' and 'update header' only
    assert.equals(2, #result_commits, "Should have 2 commits for lines 1-3")
    assert.matches("update header", result_commits[1].subject)
    assert.matches("initial", result_commits[2].subject)
  end)

  it("counts insertions and deletions from diff output", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.is_not_nil(result_commits)
    -- The 'update foo' commit changed 1 line (return 1 -> return 42)
    local update_commit = result_commits[1]
    assert.equals(1, update_commit.insertions, "Should have 1 insertion")
    assert.equals(1, update_commit.deletions, "Should have 1 deletion")
    assert.equals(1, update_commit.files_changed, "Should have files_changed=1")
  end)

  it("sets file_path on commits from line-range query", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    for _, commit in ipairs(result_commits) do
      assert.equals("test.lua", commit.file_path, "file_path should be set")
    end
  end)

  it("respects --reverse flag with line_range", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
      reverse = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.equals(2, #result_commits)
    -- With reverse, oldest first
    assert.matches("initial", result_commits[1].subject)
    assert.matches("update foo", result_commits[2].subject)
  end)

  it("respects -n limit with line_range", function()
    local done = false
    local result_commits = nil

    git.get_commit_list("", repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
      limit = 1,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.equals(1, #result_commits, "Should respect limit=1")
    assert.matches("update foo", result_commits[1].subject)
  end)

  it("respects git range with line_range", function()
    local done = false
    local result_commits = nil

    -- Get the hash of the 'update foo' commit to use as range boundary
    local log_output = vim.fn.system(string.format(
      'git -C "%s" log --oneline --reverse', repo.dir))
    local hashes = {}
    for line in log_output:gmatch("[^\n]+") do
      local hash = line:match("^(%S+)")
      if hash then table.insert(hashes, hash) end
    end
    -- hashes: [1]=initial, [2]=update foo, [3]=update bar, [4]=update header
    -- Range from 'update foo' to HEAD should only include 'update foo' for lines 4-6
    local range_arg = hashes[2] .. "^.." .. hashes[2]

    git.get_commit_list(range_arg, repo.dir, {
      path = "test.lua",
      line_range = { 4, 6 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.is_not_nil(result_commits)
    assert.equals(1, #result_commits, "Range should limit to 1 commit")
    assert.matches("update foo", result_commits[1].subject)
  end)

  it("ignores line_range when no path is set", function()
    local done = false
    local result_commits = nil

    -- line_range without path should be ignored (is_line_range = false)
    git.get_commit_list("", repo.dir, {
      line_range = { 4, 6 },
      no_merges = true,
    }, function(err, commits)
      result_commits = commits
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done)
    assert.is_not_nil(result_commits)
    -- Without path, should return all repo commits (not filtered by line range)
    assert.equals(4, #result_commits, "Without path, line_range should be ignored")
  end)
end)
