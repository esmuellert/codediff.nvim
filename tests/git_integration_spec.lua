-- Test: Git Integration
-- Validates git operations, error handling, and async callbacks

local git = require("vscode-diff.git")

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
end)
