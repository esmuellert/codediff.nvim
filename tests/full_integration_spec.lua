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
  local temp_dir, repo
  local commit_hash_1
  local commit_hash_2

  -- Helper to run git in temp_dir (cross-platform)
  local function git(args)
    local h = dofile("tests/helpers.lua")
    return h.git_cmd(temp_dir, args)
  end

  before_each(function()
    -- Setup command
    setup_command()

    repo = require("tests.framework.repository").new({ unborn = true })
    temp_dir = repo.dir

    -- Commit 1
    vim.fn.writefile({ "line 1", "line 2" }, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Initial commit"')
    commit_hash_1 = vim.trim(git("rev-parse HEAD"))

    -- Tag v1.0.0
    git("tag v1.0.0")

    -- Commit 2
    vim.fn.writefile({ "line 1", "line 2 modified" }, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Second commit"')
    commit_hash_2 = vim.trim(git("rev-parse HEAD"))

    -- Create another file for file comparison
    vim.fn.writefile({ "file a content" }, temp_dir .. "/file_a.txt")
    vim.fn.writefile({ "file b content" }, temp_dir .. "/file_b.txt")

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
    if repo then
      repo.cleanup()
      repo = nil
    end
  end)

  -- Helper to verify explorer opened
  local function assert_explorer_opened()
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr("$") > 1
    end)
    assert.is_true(opened, "Should open a new tab")

    local has_explorer = false
    vim.wait(2000, function()
      for i = 1, vim.fn.winnr("$") do
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
    vim.fn.writefile({ "line 1", "line 2 modified", "line 3" }, temp_dir .. "/file.txt")

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
    git("reset --hard HEAD~1")
    git("checkout -b feature")
    vim.fn.writefile({ "feature change" }, temp_dir .. "/file.txt")
    git('commit -am "feature commit"')

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
    git("checkout HEAD~1")
    -- Now HEAD is commit 1. main is commit 2.

    vim.cmd("CodeDiff main HEAD")
    assert_explorer_opened()
  end)

  -- 12. Merge-base Mode (PR-like diff)
  it("Runs :CodeDiff main... (merge-base)", function()
    -- Go back to first commit and create feature branch
    git("checkout " .. commit_hash_1)
    git("checkout -b feature-branch")
    vim.fn.writefile({ "feature line 1", "feature line 2" }, temp_dir .. "/feature.txt")
    git("add feature.txt")
    git('commit -m "feature commit"')

    -- Now we have:
    -- main: commit_hash_1 -> commit_hash_2
    -- feature-branch: commit_hash_1 -> feature_commit
    -- merge-base(main, HEAD) = commit_hash_1
    -- So :CodeDiff main... should show only the feature.txt change

    vim.cmd("CodeDiff main...")
    assert_explorer_opened()
  end)

  -- 7. CodeDiffOpen autocmd fires on open
  it("Fires CodeDiffOpen User autocmd", function()
    vim.fn.writefile({ "line 1", "line 2 modified", "line 3" }, temp_dir .. "/file.txt")

    local event_data = nil
    local au_id = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffOpen",
      callback = function(args)
        event_data = args.data
      end,
    })

    vim.cmd("CodeDiff")
    assert_explorer_opened()

    assert.is_not_nil(event_data, "CodeDiffOpen should fire")
    assert.equal("explorer", event_data.mode, "Mode should be explorer")
    assert.is_not_nil(event_data.tabpage, "tabpage should be set")

    vim.api.nvim_del_autocmd(au_id)
  end)

  -- 8. CodeDiffClose autocmd fires on close
  it("Fires CodeDiffClose User autocmd", function()
    vim.fn.writefile({ "line 1", "line 2 modified", "line 3" }, temp_dir .. "/file.txt")

    -- Ensure lifecycle autocmds are set up (TabClosed handler)
    require("codediff.ui.lifecycle").setup()

    local close_data = nil
    local au_id = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffClose",
      callback = function(args)
        close_data = args.data
      end,
    })

    vim.cmd("CodeDiff")
    assert_explorer_opened()

    -- Close via tabclose (triggers TabClosed autocmd -> cleanup_diff)
    vim.cmd("tabclose")
    vim.wait(2000, function()
      return close_data ~= nil
    end)

    assert.is_not_nil(close_data, "CodeDiffClose should fire")
    assert.equal("explorer", close_data.mode, "Mode should be explorer")

    vim.api.nvim_del_autocmd(au_id)
  end)

  -- 9. Hardening: reject :CodeDiff file on a non-file buffer (buftype ~= "")
  it("Rejects :CodeDiff file on a non-file (scratch) buffer", function()
    local scratch = vim.api.nvim_create_buf(true, false)
    vim.bo[scratch].buftype = "nofile"
    vim.api.nvim_set_current_buf(scratch)

    local tabs_before = vim.fn.tabpagenr("$")
    -- Rejection surfaces as an error notify; pcall so the expected rejection
    -- does not abort the test. The assertion is that no diff view was created.
    pcall(vim.cmd, "CodeDiff file HEAD")
    vim.wait(300)

    assert.equals(tabs_before, vim.fn.tabpagenr("$"), "Should not open a diff for a non-file buffer")
  end)
end)
