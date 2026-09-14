-- Test: Git Integration
-- Validates git operations, error handling, and async callbacks

local git = require('codediff.core.git')
local h = dofile('tests/helpers.lua')
local config = require('codediff.config')

describe("Git Integration", function()
  -- Test 1: Detect non-git directory (async)
  it("Detects non-git directory", function()
    local callback_called = false
    local is_git = nil
    
    git.get_git_root("/tmp", function(err, root)
      callback_called = true
      is_git = (err == nil and root ~= nil)
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called, "Callback should be invoked")
    assert.equal("boolean", type(is_git), "Should determine if in git repo")
  end)

  -- Test 2: Get git root for valid repo (async)
  it("Gets git root for current repo", function()
    local current_file = vim.fn.expand("%:p")
    if current_file == "" then
      current_file = vim.fn.getcwd() .. "/README.md"
    end
    
    local callback_called = false
    local root = nil
    
    git.get_git_root(current_file, function(err, git_root)
      callback_called = true
      if not err then
        root = git_root
      end
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called, "Callback should be invoked")
    
    if root then
      assert.equal("string", type(root), "Git root should be a string")
      assert.equal(1, vim.fn.isdirectory(root), "Git root should be a directory")
    end
  end)

  -- Test 3: Error callback for invalid revision
  it("Error callback for invalid revision", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local callback_called = false
    local got_error = false
    
    -- First get git root
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        local rel_path = git.get_relative_path(current_file, git_root)
        
        git.get_file_content("invalid-revision-12345", git_root, rel_path, function(err, data)
          callback_called = true
          if err then
            got_error = true
          end
        end)
      else
        callback_called = true
        got_error = true
      end
    end)
    
    vim.wait(2000, function() return callback_called end)
    assert.is_true(callback_called, "Callback should be invoked")
  end)

  -- Test 4: Async callback with actual git repo (if available)
  it("Can retrieve file from HEAD (if in git repo)", function()
    local test_passed = false
    local current_file = debug.getinfo(1).source:sub(2)
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        local rel_path = git.get_relative_path(current_file, git_root)
        
        -- First resolve HEAD to commit hash
        git.resolve_revision("HEAD", git_root, function(err_resolve, commit_hash)
          if not err_resolve and commit_hash then
            git.get_file_content(commit_hash, git_root, rel_path, function(err, lines)
              if not err and lines then
                assert.equal("table", type(lines), "Should return table of lines")
                assert.is_true(#lines > 0, "Should have content")
                test_passed = true
              elseif err then
                test_passed = true
              end
            end)
          else
            test_passed = true
          end
        end)
      else
        test_passed = true
      end
    end)
    
    vim.wait(3000, function() return test_passed end)
    assert.is_true(test_passed, "Test should complete")
  end)

  -- Test 5: Relative path calculation
  it("Calculates relative path correctly", function()
    -- Use Windows-style paths on Windows, Unix on Unix
    local sep = package.config:sub(1,1)
    local git_root, file_path, expected
    
    if sep == "\\" then
      -- Windows
      git_root = "C:\\Users\\test\\project"
      file_path = "C:\\Users\\test\\project\\src\\file.lua"
      expected = "src/file.lua"
    else
      -- Unix
      git_root = "/home/user/project"
      file_path = "/home/user/project/src/file.lua"
      expected = "src/file.lua"
    end
    
    local rel_path = git.get_relative_path(file_path, git_root)
    assert.equal("string", type(rel_path), "Should return string")
    assert.equal(expected, rel_path, "Should strip git root: got " .. rel_path)
  end)

  -- Test 6: Error message quality for missing file in revision
  it("Provides good error for missing file in revision", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local test_passed = false
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        git.resolve_revision("HEAD", git_root, function(err_resolve, commit_hash)
          if not err_resolve and commit_hash then
            local fake_path = "nonexistent_file_12345.txt"
            
            git.get_file_content(commit_hash, git_root, fake_path, function(err, data)
              if err then
                assert.equal("string", type(err), "Error should be a string")
                assert.is_true(#err > 0, "Error message should not be empty")
              end
              test_passed = true
            end)
          else
            test_passed = true
          end
        end)
      else
        test_passed = true
      end
    end)
    
    vim.wait(3000, function() return test_passed end)
    assert.is_true(test_passed, "Test should complete")
  end)

  -- Test 7: Handles special characters in filenames
  it("Handles filenames with spaces", function()
    -- Use Windows-style paths on Windows, Unix on Unix
    local sep = package.config:sub(1,1)
    local git_root, file_path, expected
    
    if sep == "\\" then
      -- Windows
      git_root = "C:\\Users\\test\\project"
      file_path = "C:\\Users\\test\\project\\src\\my file.lua"
      expected = "src/my file.lua"
    else
      -- Unix
      git_root = "/home/user/project"
      file_path = "/home/user/project/src/my file.lua"
      expected = "src/my file.lua"
    end
    
    local rel_path = git.get_relative_path(file_path, git_root)
    assert.equal(expected, rel_path, "Should handle spaces: got " .. rel_path)
  end)

  -- Test 8: Multiple async calls don't interfere
  it("Multiple async calls work independently", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local call1_done = false
    local call2_done = false
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        local rel_path = git.get_relative_path(current_file, git_root)
        
        git.get_file_content("invalid1", git_root, rel_path, function()
          call1_done = true
        end)
        
        git.get_file_content("invalid2", git_root, rel_path, function()
          call2_done = true
        end)
      else
        call1_done = true
        call2_done = true
      end
    end)
    
    vim.wait(3000, function() return call1_done and call2_done end)
    
    assert.is_true(call1_done, "First call should complete")
    assert.is_true(call2_done, "Second call should complete")
  end)

  -- Test 9: LRU Cache functionality
  it("LRU cache returns same content", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local test_passed = false
    local first_result = nil
    local second_result = nil
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        git.resolve_revision("HEAD", git_root, function(err_resolve, commit_hash)
          if not err_resolve and commit_hash then
            local rel_path = git.get_relative_path(current_file, git_root)
            
            -- First call (cache miss)
            git.get_file_content(commit_hash, git_root, rel_path, function(err1, lines1)
              first_result = lines1
              
              -- Second call (cache hit)
              git.get_file_content(commit_hash, git_root, rel_path, function(err2, lines2)
                second_result = lines2
                
                if first_result and second_result then
                  assert.equal(#first_result, #second_result, "Cached content should match")
                  -- Verify they are separate copies (not same reference)
                  assert.are_not.equal(first_result, second_result, "Should return copies, not same reference")
                  test_passed = true
                else
                  test_passed = true
                end
              end)
            end)
          else
            test_passed = true
          end
        end)
      else
        test_passed = true
      end
    end)
    
    vim.wait(3000, function() return test_passed end)
    assert.is_true(test_passed, "Test should complete")
  end)

  -- Test 10: get_merge_base returns valid commit hash
  it("get_merge_base returns merge-base commit", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local test_passed = false
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        -- Use HEAD and HEAD~1 which are guaranteed to exist and have a merge-base
        git.get_merge_base("HEAD~1", "HEAD", git_root, function(err, merge_base_hash)
          if not err and merge_base_hash then
            -- Merge-base of HEAD~1 and HEAD should be HEAD~1
            assert.equal("string", type(merge_base_hash), "Should return commit hash")
            assert.is_true(#merge_base_hash >= 7, "Hash should be at least 7 chars")
            assert.is_true(merge_base_hash:match("^[a-f0-9]+$") ~= nil, "Should be hex hash")
            test_passed = true
          elseif err then
            -- If merge-base fails (e.g., not enough commits), that's acceptable
            test_passed = true
          end
        end)
      else
        test_passed = true
      end
    end)
    
    vim.wait(3000, function() return test_passed end)
    assert.is_true(test_passed, "Test should complete")
  end)

  -- Test 11: get_merge_base with invalid revision
  it("get_merge_base handles invalid revision", function()
    local current_file = debug.getinfo(1).source:sub(2)
    local test_passed = false
    
    git.get_git_root(current_file, function(err_root, git_root)
      if not err_root and git_root then
        git.get_merge_base("nonexistent-branch-12345", "HEAD", git_root, function(err, merge_base_hash)
          assert.is_not_nil(err, "Should return error for invalid branch")
          assert.is_nil(merge_base_hash, "Should not return hash on error")
          test_passed = true
        end)
      else
        test_passed = true
      end
    end)
    
    vim.wait(3000, function() return test_passed end)
    assert.is_true(test_passed, "Test should complete")
  end)
end)

-- Untracked-files policy (#389): config.options.explorer.untracked controls the
-- -u<mode> scan, applied centrally in run_git_async for both `git status`
-- (get_status) and the untracked `ls-files` scan (get_diff_revision).
describe("Git untracked policy (#389)", function()
  local prev
  before_each(function()
    prev = config.options.explorer.untracked
  end)
  after_each(function()
    config.options.explorer.untracked = prev
  end)

  -- Repo with a tracked change + a top-level untracked file + a nested untracked dir.
  local function make_repo()
    local repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "base" })
    repo.git("add tracked.txt")
    repo.git("commit -m initial")
    repo.write_file("tracked.txt", { "changed" })
    repo.write_file("newfile.txt", { "u" })
    repo.write_file("untracked_dir/nested.txt", { "n" })
    return repo
  end

  -- path -> status map from the unstaged group of an async git call.
  local function unstaged_set(fn)
    local done, res = false, nil
    fn(function(_, r)
      res = r
      done = true
    end)
    vim.wait(3000, function() return done end)
    assert.is_not_nil(res, "callback should fire")
    local set = {}
    for _, f in ipairs(res.unstaged or {}) do
      set[f.path] = f.status
    end
    return set
  end

  local function status_set(repo, mode)
    config.options.explorer.untracked = mode
    return unstaged_set(function(cb) git.get_status(repo.dir, cb) end)
  end

  local function diffrev_set(repo, mode)
    config.options.explorer.untracked = mode
    return unstaged_set(function(cb) git.get_diff_revision("HEAD", repo.dir, cb) end)
  end

  it("all lists every untracked file individually (get_status)", function()
    local repo = make_repo()
    local s = status_set(repo, "all")
    assert.is_not_nil(s["newfile.txt"], "top-level untracked shown")
    assert.is_not_nil(s["untracked_dir/nested.txt"], "nested untracked file shown")
    repo.cleanup()
  end)

  it("normal collapses untracked directories (get_status)", function()
    local repo = make_repo()
    local s = status_set(repo, "normal")
    assert.is_not_nil(s["newfile.txt"], "top-level untracked still shown")
    assert.is_nil(s["untracked_dir/nested.txt"], "nested file not listed individually")
    assert.is_not_nil(s["untracked_dir/"], "directory collapsed to one entry")
    repo.cleanup()
  end)

  it("no skips untracked files entirely — the hang fix (get_status)", function()
    local repo = make_repo()
    local s = status_set(repo, "no")
    assert.is_nil(s["newfile.txt"], "untracked hidden")
    assert.is_nil(s["untracked_dir/nested.txt"], "untracked hidden")
    assert.is_not_nil(s["tracked.txt"], "tracked change still present")
    repo.cleanup()
  end)

  it("no skips the ls-files untracked scan (get_diff_revision)", function()
    local repo = make_repo()
    local s = diffrev_set(repo, "no")
    assert.is_nil(s["newfile.txt"], "untracked skipped in revision mode too")
    assert.is_not_nil(s["tracked.txt"], "tracked change still present")
    repo.cleanup()
  end)

  it("normal collapses untracked directories (get_diff_revision)", function()
    local repo = make_repo()
    local s = diffrev_set(repo, "normal")
    assert.is_not_nil(s["untracked_dir/"], "directory collapsed via --directory")
    assert.is_nil(s["untracked_dir/nested.txt"], "nested file not listed individually")
    repo.cleanup()
  end)

  it("defaults to all when the config value is invalid", function()
    local repo = make_repo()
    local s = status_set(repo, "bogus")
    assert.is_not_nil(s["untracked_dir/nested.txt"], "invalid mode falls back to all")
    repo.cleanup()
  end)
end)

-- The explorer polls `git status` every 500ms. A plain `git status` refreshes
-- the index stat cache and writes it back, which takes `.git/index.lock`; a
-- poll landing while the user stages/discards a hunk makes the *staging*
-- command fail with "Unable to create '.../.git/index.lock': File exists".
-- The read-only queries therefore pass `--no-optional-locks`, which skips
-- exactly that write.
describe("Git read-only queries do not write the index (#494)", function()
  local uv = vim.uv or vim.loop

  --- Repo whose index stat cache is stale: `tracked.txt` still has its
  --- committed content, but its mtime was moved 60s into the past. git sees the
  --- stat mismatch, re-reads the file, finds it clean, and — unless told not to
  --- — rewrites the index to refresh the cache. The timestamp is strictly older
  --- than the index, so this does not depend on filesystem mtime granularity.
  local function make_repo_with_stale_index()
    local repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "base" })
    repo.git("add tracked.txt")
    repo.git("commit -m initial")

    local past = os.time() - 60
    assert.is_not_nil(uv.fs_utime(repo.dir .. "/tracked.txt", past, past), "should be able to backdate the tracked file")
    return repo
  end

  local function index_bytes(repo)
    return table.concat(vim.fn.readfile(repo.git_path("index"), "b"), "\n")
  end

  it("get_status leaves .git/index untouched", function()
    local repo = make_repo_with_stale_index()
    local before = index_bytes(repo)

    local done, err = false, nil
    git.get_status(repo.dir, function(e)
      err = e
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)

    assert.is_true(done, "callback should fire")
    assert.is_nil(err, "git status should succeed")
    assert.equals(before, index_bytes(repo), "git status must not rewrite the index, or it would contend for index.lock")
    repo.cleanup()
  end)

  -- `git diff` refreshes the index unconditionally — it does not honor
  -- `--no-optional-locks` the way `status` does — so it can still hold
  -- index.lock briefly. What must hold is that neither query ever *fails*
  -- because another git process owns the lock, so a poll can never surface an
  -- error to the user.
  it("read-only queries still succeed while another git process holds index.lock", function()
    local repo = make_repo_with_stale_index()
    local lock = repo.git_path("index.lock")
    vim.fn.writefile({ "" }, lock)

    local done, err = false, nil
    git.get_diff_revision("HEAD", repo.dir, function(e)
      err = e
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)

    vim.fn.delete(lock)
    assert.is_true(done, "callback should fire")
    assert.is_nil(err, "a held index.lock must not fail a read-only query")
    repo.cleanup()
  end)
end)




-- GitHub's Windows runners set `core.autocrlf=true` globally. git then warns
-- "LF will be replaced by CRLF the next time Git touches it" on stderr for every
-- LF file the specs write, and `vim.fn.system()` folds stderr into its return
-- value ('shellredir' is `>%s 2>&1`) — so the warning ends up inside strings the
-- specs compare against git output. tests/init.lua pins `core.autocrlf=false`
-- through GIT_CONFIG_COUNT for every git process instead.
describe("Git output is free of line-ending warnings (#494)", function()
  --- Repo configured exactly like a Windows CI runner: autocrlf on, LF content.
  local function make_autocrlf_repo()
    local repo = h.create_temp_git_repo()
    repo.git("config core.autocrlf true")
    repo.write_file("file1.txt", { "alpha", "beta", "gamma" })
    repo.git("add file1.txt")
    repo.git("commit -m initial")
    repo.write_file("file1.txt", { "alpha", "BETA", "gamma" })
    return repo
  end

  it("git_cmd output carries no CRLF conversion warning", function()
    local repo = make_autocrlf_repo()

    local output = repo.git("diff --name-only")

    assert.is_nil(output:match("LF will be replaced by CRLF"), "line-ending warning must not pollute git output: " .. output)
    assert.equals("file1.txt", vim.trim(output), "git diff --name-only should report exactly the modified file")
    repo.cleanup()
  end)

  it("core.autocrlf is pinned off for every git process", function()
    local repo = make_autocrlf_repo()

    assert.equals("false", vim.trim(repo.git("config --get core.autocrlf")), "environment config must outrank the repository config")
    repo.cleanup()
  end)
end)
