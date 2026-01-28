-- Test: Full Integration
-- Validates all supported commands documented in README.md

local commands = require("codediff.commands")

-- Setup CodeDiff command for tests
local function setup_command()
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

describe("Full Integration Suite", function()
  local temp_dir
  local commit_hash_1
  local commit_hash_2

  before_each(function()
    -- Fix package.path which seems to be reset
    local nui_dir = vim.fn.stdpath("data") .. "/nui.nvim"
    nui_dir = nui_dir:gsub("\\", "/")
    if not package.path:find(nui_dir) then
      package.path = package.path .. ";" .. nui_dir .. "/lua/?.lua;" .. nui_dir .. "/lua/?/init.lua"
    end
    
    -- Setup command
    setup_command()
    
    -- Create temporary git repository for testing
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    
    -- Helper to run git in temp_dir
    local function git(args)
      -- Use -C to run git in the temp directory
      -- On Windows, we need to ensure paths are handled correctly
      -- Use string.format for safer command construction
      -- IMPORTANT: On Windows, shellescape wraps in single quotes which cmd.exe doesn't like for paths
      -- So we use double quotes for the path manually
      local cmd
      if vim.fn.has("win32") == 1 then
        cmd = string.format('git -C "%s" %s', temp_dir, args)
      else
        cmd = string.format('git -C %s %s', vim.fn.shellescape(temp_dir), args)
      end
      return vim.fn.system(cmd)
    end
    
    -- Initialize git repo
    git("init")
    -- Rename branch to main to be sure
    git("branch -m main")
    git('config user.email "test@example.com"')
    git('config user.name "Test User"')
    
    -- Commit 1
    vim.fn.writefile({"line 1", "line 2"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Initial commit"')
    commit_hash_1 = vim.trim(git("rev-parse HEAD"))
    
    -- Tag v1.0.0
    git("tag v1.0.0")

    -- Commit 2
    vim.fn.writefile({"line 1", "line 2 modified"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Second commit"')
    commit_hash_2 = vim.trim(git("rev-parse HEAD"))

    -- Create another file for file comparison
    vim.fn.writefile({"file a content"}, temp_dir .. "/file_a.txt")
    vim.fn.writefile({"file b content"}, temp_dir .. "/file_b.txt")
    
    -- Open the main file
    vim.cmd("edit " .. temp_dir .. "/file.txt")
  end)

  after_each(function()
    -- Reset tabs first to close windows/buffers that might be using the dir
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    
    -- Give enough time for async tasks/handles to close
    vim.wait(200)

    -- Clean up
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  -- Helper to verify explorer opened
  local function assert_explorer_opened()
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr('$') > 1
    end)
    assert.is_true(opened, "Should open a new tab")
    
    local has_explorer = false
    vim.wait(2000, function()
      for i = 1, vim.fn.winnr('$') do
        local winid = vim.fn.win_getid(i)
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "codediff-explorer" then
          has_explorer = true
          return true
        end
      end
      return false
    end)
    assert.is_true(has_explorer, "Should have explorer window")
  end

  -- 1. Explorer Mode: Default
  it("Runs :CodeDiff (Explorer Default)", function()
    -- Make a change so there is something to show
    vim.fn.writefile({"line 1", "line 2 modified", "line 3"}, temp_dir .. "/file.txt")
    
    vim.cmd("CodeDiff")
    assert_explorer_opened()
  end)

  -- 2. Explorer Mode: Revision
  it("Runs :CodeDiff HEAD~1", function()
    vim.cmd("CodeDiff HEAD~1")
    assert_explorer_opened()
  end)

  -- 3. Explorer Mode: Branch
  it("Runs :CodeDiff main", function()
    -- Create a dev branch and switch to it so main is different
    -- Use shellescape for paths to handle spaces/special chars on Windows
    local safe_temp_dir
    if vim.fn.has("win32") == 1 then
      safe_temp_dir = '"' .. temp_dir .. '"'
    else
      safe_temp_dir = vim.fn.shellescape(temp_dir)
    end
    
    vim.fn.system(string.format('git -C %s reset --hard HEAD~1', safe_temp_dir))
    vim.fn.system(string.format('git -C %s checkout -b feature', safe_temp_dir))
    vim.fn.writefile({"feature change"}, temp_dir .. "/file.txt")
    vim.fn.system(string.format('git -C %s commit -am "feature commit"', safe_temp_dir))
    
    -- Now compare against main
    vim.cmd("CodeDiff main")
    assert_explorer_opened()
  end)

  -- 4. Explorer Mode: Commit Hash
  it("Runs :CodeDiff <commit_hash>", function()
    vim.cmd("CodeDiff " .. commit_hash_1)
    assert_explorer_opened()
  end)

  -- 11. Arbitrary Revision Diff (Explorer)
  it("Runs :CodeDiff main HEAD", function()
    -- Ensure there is a diff between main and HEAD
    local safe_temp_dir
    if vim.fn.has("win32") == 1 then
      safe_temp_dir = '"' .. temp_dir .. '"'
    else
      safe_temp_dir = vim.fn.shellescape(temp_dir)
    end
    
    vim.fn.system(string.format('git -C %s checkout HEAD~1', safe_temp_dir))
    -- Now HEAD is commit 1. main is commit 2.
    
    vim.cmd("CodeDiff main HEAD")
    assert_explorer_opened()
  end)

  -- 12. Merge-base Mode (PR-like diff)
  it("Runs :CodeDiff main... (merge-base)", function()
    -- Create a feature branch from commit 1
    local safe_temp_dir
    if vim.fn.has("win32") == 1 then
      safe_temp_dir = '"' .. temp_dir .. '"'
    else
      safe_temp_dir = vim.fn.shellescape(temp_dir)
    end
    
    -- Go back to first commit and create feature branch
    vim.fn.system(string.format('git -C %s checkout %s', safe_temp_dir, commit_hash_1))
    vim.fn.system(string.format('git -C %s checkout -b feature-branch', safe_temp_dir))
    vim.fn.writefile({"feature line 1", "feature line 2"}, temp_dir .. "/feature.txt")
    vim.fn.system(string.format('git -C %s add feature.txt', safe_temp_dir))
    vim.fn.system(string.format('git -C %s commit -m "feature commit"', safe_temp_dir))
    
    -- Now we have:
    -- main: commit_hash_1 -> commit_hash_2
    -- feature-branch: commit_hash_1 -> feature_commit
    -- merge-base(main, HEAD) = commit_hash_1
    -- So :CodeDiff main... should show only the feature.txt change
    
    vim.cmd("CodeDiff main...")
    assert_explorer_opened()
  end)

end)
