-- Test: Keymap Restoration
-- Validates that user-defined keymaps are restored after closing CodeDiff
-- Addresses: https://github.com/esmuellert/codediff.nvim/issues/211
--
-- Issue scenario:
-- 1. User has keymaps like J, K, ]h, [h defined (globally or buffer-local)
-- 2. User configures CodeDiff to use same keys: next_file=J, prev_file=K, etc.
-- 3. User opens :CodeDiff, presses J (next file), presses q (quit)
-- 4. User's original keymaps are lost

local helpers = require("tests.helpers")
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

describe("Keymap Restoration (Issue #211)", function()
  local repo
  local test_bufnr
  local original_J_called = false
  local original_K_called = false

  before_each(function()
    helpers.ensure_plugin_loaded()
    setup_command()

    -- Create a temp git repo with changes
    repo = helpers.create_temp_git_repo()

    -- Create initial commit
    repo.write_file("test.lua", { "line 1", "line 2", "line 3" })
    repo.git("add -A")
    repo.git('commit -m "Initial commit"')

    -- Make an uncommitted change so CodeDiff has something to show
    repo.write_file("test.lua", { "line 1 modified", "line 2", "line 3" })

    -- Open the file
    vim.cmd("edit " .. repo.path("test.lua"))
    test_bufnr = vim.api.nvim_get_current_buf()

    -- Reset tracking flags
    original_J_called = false
    original_K_called = false
  end)

  after_each(function()
    -- Clean up tabs
    helpers.close_extra_tabs()
    vim.wait(200)

    -- Clean up repo
    if repo then
      repo.cleanup()
    end
  end)

  it("Restores buffer-local keymaps after closing CodeDiff (exact issue #211 scenario)", function()
    -- This test replicates the exact issue:
    -- User has buffer-local keymaps on their working file
    -- CodeDiff opens and sets its own keymaps on buffers
    -- User navigates files (keymaps should be restored on old buffer)
    -- After closing, all remaining buffers should have keymaps restored

    -- Create a second file to switch between
    repo.write_file("other.lua", { "other line 1", "other line 2" })
    repo.git("add other.lua")
    repo.git('commit -m "Add other file"')
    repo.write_file("other.lua", { "other line 1 modified", "other line 2" })

    -- Load the other file buffer and set keymaps on it too
    vim.cmd("edit " .. repo.path("other.lua"))
    local other_bufnr = vim.api.nvim_get_current_buf()

    vim.keymap.set("n", "J", function()
      -- Do nothing, just a marker
    end, { buffer = other_bufnr, desc = "User's J on other.lua" })

    -- Go back to test.lua
    vim.cmd("edit " .. repo.path("test.lua"))
    assert.equals(test_bufnr, vim.api.nvim_get_current_buf())

    -- Set up user's custom buffer-local keymaps on test.lua
    vim.keymap.set("n", "J", function()
      original_J_called = true
    end, { buffer = test_bufnr, desc = "User's J keymap" })

    vim.keymap.set("n", "K", function()
      original_K_called = true
    end, { buffer = test_bufnr, desc = "User's K keymap" })

    -- Open CodeDiff (explorer mode)
    vim.cmd("CodeDiff")

    -- Wait for CodeDiff to open
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr("$") > 1
    end)
    assert.is_true(opened, "Should open CodeDiff in new tab")

    local codediff_tab = vim.api.nvim_get_current_tabpage()

    -- Wait for session to be ready
    local ready = helpers.wait_for_session_ready(codediff_tab, 10000)
    assert.is_true(ready, "CodeDiff session should be ready")

    -- At this point CodeDiff has set keymaps on the modified buffer

    -- Close CodeDiff
    vim.cmd("tabclose")
    vim.wait(500)

    -- Verify we're back to original tab
    assert.equals(1, vim.fn.tabpagenr("$"), "Should be back to single tab")

    -- Buffer must still be valid for keymap restoration to matter
    assert.is_true(vim.api.nvim_buf_is_valid(test_bufnr), "Working file buffer should still be valid")

    -- CRITICAL: Verify the user's keymaps are RESTORED (this was broken before fix)
    local keymaps_after = vim.api.nvim_buf_get_keymap(test_bufnr, "n")
    local found_J_after = false
    local found_K_after = false
    for _, map in ipairs(keymaps_after) do
      if map.lhs == "J" and map.desc == "User's J keymap" then
        found_J_after = true
      end
      if map.lhs == "K" and map.desc == "User's K keymap" then
        found_K_after = true
      end
    end

    assert.is_true(found_J_after, "User's J keymap should be restored after closing CodeDiff")
    assert.is_true(found_K_after, "User's K keymap should be restored after closing CodeDiff")

    -- Verify the restored callbacks actually WORK
    vim.api.nvim_set_current_buf(test_bufnr)
    vim.api.nvim_feedkeys("J", "x", false)
    vim.wait(50)
    assert.is_true(original_J_called, "User's J callback should work after restoration")

    vim.api.nvim_feedkeys("K", "x", false)
    vim.wait(50)
    assert.is_true(original_K_called, "User's K callback should work after restoration")

    -- Also verify other.lua's keymaps are intact
    if vim.api.nvim_buf_is_valid(other_bufnr) then
      local other_keymaps = vim.api.nvim_buf_get_keymap(other_bufnr, "n")
      local found_J_on_other = false
      for _, map in ipairs(other_keymaps) do
        if map.lhs == "J" and map.desc == "User's J on other.lua" then
          found_J_on_other = true
        end
      end
      assert.is_true(found_J_on_other, "User's J keymap on other.lua should be intact")
    end
  end)

  it("Handles buffers without pre-existing keymaps", function()
    -- Don't set any custom keymaps - just open and close CodeDiff
    -- This should not error

    -- Open CodeDiff
    vim.cmd("CodeDiff")

    -- Wait for CodeDiff to open
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr("$") > 1
    end)
    assert.is_true(opened, "Should open CodeDiff in new tab")

    local codediff_tab = vim.api.nvim_get_current_tabpage()
    local ready = helpers.wait_for_session_ready(codediff_tab, 10000)
    assert.is_true(ready, "CodeDiff session should be ready")

    -- Close CodeDiff - should not error
    vim.cmd("tabclose")
    vim.wait(500)

    -- Verify no CodeDiff keymaps remain on the buffer
    if vim.api.nvim_buf_is_valid(test_bufnr) then
      local keymaps = vim.api.nvim_buf_get_keymap(test_bufnr, "n")
      for _, map in ipairs(keymaps) do
        -- Check that codediff keymaps are removed
        assert.is_nil(
          map.desc and map.desc:match("codediff") or map.desc and map.desc:match("Next hunk"),
          "CodeDiff keymaps should be removed: " .. (map.lhs or "")
        )
      end
    end
  end)

  it("Restores keymaps with different options (expr, silent, etc)", function()
    -- Set up a more complex keymap with various options
    local expr_result = "test_expr_result"
    vim.keymap.set("n", "]h", function()
      return expr_result
    end, {
      buffer = test_bufnr,
      expr = true,
      silent = true,
      desc = "User's expr keymap",
    })

    -- Verify keymap exists with correct options
    local keymaps_before = vim.api.nvim_buf_get_keymap(test_bufnr, "n")
    local found_before = false
    for _, map in ipairs(keymaps_before) do
      if map.lhs == "]h" then
        found_before = true
        assert.equals(1, map.expr, "Should have expr=true before")
        assert.equals(1, map.silent, "Should have silent=true before")
      end
    end
    assert.is_true(found_before, "Should have ]h keymap before CodeDiff")

    -- Open and close CodeDiff
    vim.cmd("CodeDiff")
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr("$") > 1
    end)
    assert.is_true(opened, "Should open CodeDiff")

    local codediff_tab = vim.api.nvim_get_current_tabpage()
    helpers.wait_for_session_ready(codediff_tab, 10000)

    vim.cmd("tabclose")
    vim.wait(500)

    -- Verify keymap is restored with correct options
    if vim.api.nvim_buf_is_valid(test_bufnr) then
      local keymaps_after = vim.api.nvim_buf_get_keymap(test_bufnr, "n")
      local found_after = false
      for _, map in ipairs(keymaps_after) do
        if map.lhs == "]h" and map.desc == "User's expr keymap" then
          found_after = true
          assert.equals(1, map.expr, "Should have expr=true after restore")
          assert.equals(1, map.silent, "Should have silent=true after restore")
        end
      end
      assert.is_true(found_after, "User's ]h keymap should be restored with correct options")
    end
  end)
end)
