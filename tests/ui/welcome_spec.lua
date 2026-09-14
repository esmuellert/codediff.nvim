-- Test: Welcome page for empty diff panes
-- Validates welcome buffer creation, detection, and integration with refresh

local helpers = require("tests.helpers")

-- Setup CodeDiff command for tests
local function setup_command()
  local commands = require("codediff.commands")
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

describe("Welcome Page", function()
  -- ============================================================================
  -- Unit tests for welcome.lua buffer factory
  -- ============================================================================

  describe("Unit:", function()
    local welcome

    before_each(function()
      welcome = require("codediff.ui.welcome")
    end)

    it("create_buffer returns a valid buffer with logo content", function()
      local bufnr = welcome.create_buffer(80, 24)

      assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
      assert.equals("nofile", vim.bo[bufnr].buftype)
      assert.equals("wipe", vim.bo[bufnr].bufhidden)
      assert.is_false(vim.bo[bufnr].buflisted)
      assert.equals("codediff", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"))

      -- Buffer should contain the logo
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_true(content:find("CODEDIFF") ~= nil or content:find("██") ~= nil, "Buffer should contain logo text")

      -- Buffer should contain hint text
      assert.is_true(content:find("Working tree is clean") ~= nil, "Buffer should contain hint message")
    end)

    it("is_welcome_buffer returns true for welcome buffers", function()
      local bufnr = welcome.create_buffer(80, 24)
      assert.is_true(welcome.is_welcome_buffer(bufnr))
    end)

    it("is_welcome_buffer returns false for non-welcome buffers", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      assert.is_false(welcome.is_welcome_buffer(bufnr))

      -- Cleanup
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("is_welcome_buffer returns false for invalid buffer", function()
      assert.is_false(welcome.is_welcome_buffer(nil))
      assert.is_false(welcome.is_welcome_buffer(-1))
      assert.is_false(welcome.is_welcome_buffer(999999))
    end)

    it("create_buffer does not modify any window options", function()
      -- Capture window options before
      local win = vim.api.nvim_get_current_win()
      local number_before = vim.wo[win].number
      local signcolumn_before = vim.wo[win].signcolumn
      local wrap_before = vim.wo[win].wrap

      welcome.create_buffer(80, 24)

      -- Window options should be unchanged
      assert.equals(number_before, vim.wo[win].number)
      assert.equals(signcolumn_before, vim.wo[win].signcolumn)
      assert.equals(wrap_before, vim.wo[win].wrap)
    end)

    it("create_buffer centers logo based on dimensions", function()
      local bufnr = welcome.create_buffer(120, 40)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- First line with logo content should have leading spaces (centered)
      local found_logo = false
      for _, line in ipairs(lines) do
        if line:find("██") then
          found_logo = true
          -- Should have leading spaces for centering
          assert.is_true(line:match("^%s") ~= nil, "Logo line should have leading spaces for centering")
          break
        end
      end
      assert.is_true(found_logo, "Should find logo in buffer")
    end)

    it("welcome window override is saved and restored per window", function()
      local lifecycle = require("codediff.ui.lifecycle")
      local welcome_window = require("codediff.ui.view.welcome_window")
      local tabpage = vim.api.nvim_get_current_tabpage()
      local main_win = vim.api.nvim_get_current_win()
      local regular_buf = vim.api.nvim_create_buf(false, true)
      local other_buf = vim.api.nvim_create_buf(false, true)
      local welcome_buf = welcome.create_buffer(80, 24)

      vim.wo[main_win].number = true
      vim.wo[main_win].relativenumber = true
      vim.wo[main_win].signcolumn = "yes:1"
      vim.wo[main_win].foldcolumn = "2"
      vim.wo[main_win].statuscolumn = "%l"

      vim.cmd("vsplit")
      local other_win = vim.api.nvim_get_current_win()
      vim.wo[other_win].number = true
      vim.wo[other_win].relativenumber = false
      vim.wo[other_win].signcolumn = "yes"
      vim.wo[other_win].statuscolumn = "%=%l"

      lifecycle.create_session(tabpage, {
        original = "",
        modified = "",
      }, {
        original_bufnr = regular_buf,
        modified_bufnr = other_buf,
        original_win = main_win,
        modified_win = other_win,
        lines_diff = {},
      })
      vim.api.nvim_set_current_win(main_win)

      vim.api.nvim_win_set_buf(main_win, welcome_buf)
      welcome_window.sync(main_win)

      assert.is_false(vim.wo[main_win].number)
      assert.is_false(vim.wo[main_win].relativenumber)
      assert.equals("yes:1", vim.wo[main_win].signcolumn)
      assert.equals("0", vim.wo[main_win].foldcolumn)
      assert.equals("%l", vim.wo[main_win].statuscolumn)

      assert.is_true(vim.wo[other_win].number)
      assert.is_false(vim.wo[other_win].relativenumber)
      assert.equals("yes", vim.wo[other_win].signcolumn)
      assert.equals("%=%l", vim.wo[other_win].statuscolumn)

      vim.api.nvim_win_set_buf(main_win, regular_buf)
      welcome_window.sync(main_win)

      assert.is_true(vim.wo[main_win].number)
      assert.is_true(vim.wo[main_win].relativenumber)
      assert.equals("yes:1", vim.wo[main_win].signcolumn)
      assert.equals("2", vim.wo[main_win].foldcolumn)
      assert.equals("%l", vim.wo[main_win].statuscolumn)

      lifecycle.cleanup(tabpage)
      vim.api.nvim_set_current_win(main_win)
      if vim.api.nvim_win_is_valid(other_win) then
        vim.api.nvim_win_close(other_win, true)
      end
      if vim.api.nvim_buf_is_valid(regular_buf) then
        vim.api.nvim_buf_delete(regular_buf, { force = true })
      end
      if vim.api.nvim_buf_is_valid(other_buf) then
        vim.api.nvim_buf_delete(other_buf, { force = true })
      end
    end)
  end)

  -- ============================================================================
  -- E2E integration test: refresh triggers welcome, then file select restores
  -- ============================================================================

  describe("E2E:", function()
    local repo
    local original_cwd

    before_each(function()
      require("codediff").setup({ diff = { layout = "side-by-side" } })
      setup_command()
      original_cwd = vim.fn.getcwd()
      repo = helpers.create_temp_git_repo()
    end)

    after_each(function()
      -- Create a safe tab to avoid closing last tab
      vim.cmd("tabnew")
      vim.cmd("tabonly")
      vim.fn.chdir(original_cwd)
      vim.wait(200)
      if repo then
        repo.cleanup()
      end
    end)

    it("shows welcome when all changes are discarded, restores on file select", function()
      -- Setup: create a file, commit, then modify
      repo.write_file("test.txt", { "line 1", "line 2" })
      repo.git("add .")
      repo.git("commit -m 'initial'")
      repo.write_file("test.txt", { "line 1", "line 2 modified", "line 3" })

      vim.fn.chdir(repo.dir)
      vim.cmd("edit " .. repo.path("test.txt"))

      -- Open CodeDiff explorer
      vim.cmd("CodeDiff")

      -- Wait for explorer and diff to be ready
      -- CodeDiff opens a new tab, so we need to find the right tabpage
      local lifecycle = require("codediff.ui.lifecycle")

      local tabpage
      local explorer_ready = vim.wait(10000, function()
        -- Find the tabpage with a session (CodeDiff creates a new tab)
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local s = lifecycle.get_session(tp)
          if s then
            tabpage = tp
            break
          end
        end
        if not tabpage then
          return false
        end
        local session = lifecycle.get_session(tabpage)
        if not session then
          return false
        end
        if not (session.panel or {}).view then
          return false
        end
        -- Wait for diff to render (buffers loaded)
        local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
        if not orig_buf or not mod_buf then
          return false
        end
        return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
      end, 100)

      assert.is_true(explorer_ready, "Explorer and diff should be ready")

      local session = lifecycle.get_session(tabpage)
      assert.is_not_nil(session, "Session should exist")
      assert.is_not_nil((session.panel or {}).view, "Explorer should exist")

      -- Verify two windows are valid (before discard)
      local orig_win = session.original_win
      local mod_win = session.modified_win
      assert.is_true(vim.api.nvim_win_is_valid(orig_win), "Original window should be valid")
      assert.is_true(vim.api.nvim_win_is_valid(mod_win), "Modified window should be valid")

      vim.wo[mod_win].number = true
      vim.wo[mod_win].relativenumber = true
      vim.wo[mod_win].signcolumn = "yes:1"
      vim.wo[mod_win].foldcolumn = "2"
      vim.wo[mod_win].statuscolumn = "%l"

      -- Discard changes: run git checkout
      vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " checkout -- test.txt")

      -- Trigger refresh
      local refresh = require("codediff.ui.refresh")
      local explorer = (session.panel or {}).view
      refresh.request(explorer.tabpage, { full = true })

      -- Wait for welcome buffer to appear
      local welcome = require("codediff.ui.welcome")
      local welcome_appeared = vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        if not s then
          return false
        end
        return welcome.is_welcome_buffer(s.modified_bufnr)
      end, 100)

      assert.is_true(welcome_appeared, "Welcome buffer should appear after discarding all changes")

      -- Verify welcome state
      session = lifecycle.get_session(tabpage)
      assert.is_true(session.single_pane == true, "Session should be in single_pane mode")
      assert.is_false(vim.wo[session.modified_win].number)
      assert.is_false(vim.wo[session.modified_win].relativenumber)
      assert.equals("yes:1", vim.wo[session.modified_win].signcolumn)
      assert.equals("0", vim.wo[session.modified_win].foldcolumn)
      assert.equals("%l", vim.wo[session.modified_win].statuscolumn)

      -- Restore changes: modify the file again
      repo.write_file("test.txt", { "line 1", "line 2 changed again" })

      -- Trigger refresh again
      refresh.request(explorer.tabpage, { full = true })

      -- Wait for tree to update (refresh is async)
      local tree_updated = vim.wait(10000, function()
        -- The tree should now have files
        local files = require("codediff.ui.explorer.tree").get_all_files(explorer.tree)
        return #files > 0
      end, 100)

      assert.is_true(tree_updated, "Tree should update with new files")

      -- Verify NO auto-select: diff panes still show welcome content
      session = lifecycle.get_session(tabpage)
      assert.is_true(welcome.is_welcome_buffer(session.modified_bufnr), "Welcome buffer should still be shown (no auto-select on refresh)")

      -- Simulate user click: select the file
      explorer.on_file_select({
        path = repo.path("test.txt"),
        status = "M",
        git_root = repo.dir,
        group = "unstaged",
      })

      -- Wait for diff to restore
      local diff_restored = vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        if not s then
          return false
        end
        -- single_pane should be cleared and both windows valid
        if s.single_pane then
          return false
        end
        return vim.api.nvim_win_is_valid(s.original_win) and vim.api.nvim_win_is_valid(s.modified_win)
      end, 100)

      assert.is_true(diff_restored, "Diff should be restored after file select")

      -- Verify diff content is visible
      session = lifecycle.get_session(tabpage)
      assert.is_false(welcome.is_welcome_buffer(session.modified_bufnr), "Welcome buffer should be replaced with diff content")
      assert.is_true(vim.wo[session.modified_win].number)
      assert.is_true(vim.wo[session.modified_win].relativenumber)
      assert.equals("yes:1", vim.wo[session.modified_win].signcolumn)
      assert.equals("2", vim.wo[session.modified_win].foldcolumn)
      assert.equals("%l", vim.wo[session.modified_win].statuscolumn)
    end)
  end)
end)
