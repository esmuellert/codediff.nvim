-- Keymap lifecycle contract.
--
-- The golden matrix locks *which* mappings get installed. This file locks the
-- other half: ownership and teardown — what happens to mappings that already
-- existed, and whether codediff's own mappings are fully released.
--
-- Two groups:
--   "invariants"  behavior that must not change across the registry refactor.
--   "ownership"   the lifecycle contract the registry refactor introduces.
--                 These fail against the pre-refactor implementation; that is
--                 the point — they are the executable specification.

local h = require("tests.support")
local matrix = require("tests.support.keymaps")
local path = require("codediff.core.path")

h.ensure_plugin_loaded()

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local commands = require("codediff.commands")

local function reset_config(opts)
  local config = require("codediff.config")
  config.options = vim.deepcopy(config.defaults)
  require("codediff").setup(opts or {})
  require("codediff.ui.highlights").setup()
end

local function temp_file(suffix, lines)
  local file = vim.fn.tempname() .. suffix
  vim.fn.writefile(lines, file)
  return file
end

local function wait_for_diff(tabpage, timeout_ms)
  return vim.wait(timeout_ms or 10000, function()
    local session = lifecycle.get_session(tabpage)
    return session ~= nil and session.stored_diff_result ~= nil
  end, 50)
end

--- Open a standalone diff between two real files.
--- @return number tabpage, number modified_bufnr, function cleanup
local function open_standalone(original_lines, modified_lines, pre_open)
  local left = temp_file("_lifecycle_left.txt", original_lines)
  local right = temp_file("_lifecycle_right.txt", modified_lines)

  -- Load the modified side up front so a caller can install its own mappings
  -- on the exact buffer codediff will reuse.
  local right_buf = vim.fn.bufadd(right)
  vim.fn.bufload(right_buf)
  if pre_open then
    pre_open(right_buf)
  end

  view.create({
    git_root = nil,
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  assert.is_true(wait_for_diff(tabpage), "standalone session should be ready")

  local session = lifecycle.get_session(tabpage)
  assert.equals(right_buf, session.modified_bufnr, "codediff should reuse the preloaded buffer")

  return tabpage, right_buf, function()
    vim.fn.delete(left)
    vim.fn.delete(right)
  end
end

describe("keymap lifecycle", function()
  before_each(function()
    reset_config()
  end)

  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
  end)

  -- =========================================================================
  -- Invariants: must hold before and after the registry refactor.
  -- =========================================================================
  describe("invariants", function()
    it("installs no mapping for a key configured as false", function()
      reset_config({ keymaps = { view = { quit = false, toggle_compact = false } } })

      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" })
      local maps = matrix.map_index(mod_buf, "n")

      assert.is_nil(maps["q"], "quit=false must install nothing")
      assert.is_nil(maps["gc"], "toggle_compact=false must install nothing")
      assert.is_not_nil(maps["]c"], "other mappings must still be installed")

      cleanup()
    end)

    it("honors a remapped key and never installs the default", function()
      reset_config({ keymaps = { view = { quit = "Q" } } })

      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" })
      local maps = matrix.map_index(mod_buf, "n")

      assert.is_not_nil(maps["Q"], "remapped quit should be installed")
      assert.is_nil(maps["q"], "default quit must not be installed when remapped")

      cleanup()
    end)

    it("emits CodeDiffClose exactly once, before the session is destroyed", function()
      -- Note: lifecycle.close() runs `tabclose` first, and the resulting
      -- TabLeave already strips view mappings, so CodeDiffClose fires after
      -- mappings are gone. What must stay stable is that the event fires once
      -- and the session is still queryable while handlers run.
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" })

      local fired = 0
      local session_visible_during_event
      local autocmd = vim.api.nvim_create_autocmd("User", {
        pattern = "CodeDiffClose",
        callback = function()
          fired = fired + 1
          session_visible_during_event = lifecycle.get_session(tabpage) ~= nil
        end,
      })

      lifecycle.close(tabpage)
      vim.wait(100)
      vim.api.nvim_del_autocmd(autocmd)

      assert.equals(1, fired, "CodeDiffClose must fire exactly once per close")
      assert.is_true(session_visible_during_event, "the session must still be queryable while CodeDiffClose handlers run")
      assert.is_nil(lifecycle.get_session(tabpage), "the session must be gone after close completes")

      cleanup()
    end)

    it("removes view mappings from real buffers when leaving the tab", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" })

      assert.is_not_nil(matrix.map_index(mod_buf, "n")["q"], "quit should be mapped while the tab is active")

      vim.cmd("tabnew")
      vim.wait(100)

      assert.is_nil(matrix.map_index(mod_buf, "n")["q"], "codediff mappings must not leak into other tabs")

      cleanup()
    end)
  end)

  -- =========================================================================
  -- Ownership contract: the behavior the registry refactor must deliver.
  -- =========================================================================
  describe("ownership", function()
    it("restores a pre-existing buffer-local mapping after close", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" }, function(bufnr)
        vim.keymap.set("n", "q", "<Cmd>echo 'user'<CR>", { buffer = bufnr, desc = "user-quit" })
      end)

      assert.equals("Close codediff tab", matrix.map_index(mod_buf, "n")["q"], "codediff should own q during the session")

      lifecycle.close(tabpage)
      vim.wait(100)

      assert.equals("user-quit", matrix.map_index(mod_buf, "n")["q"], "the user's own q mapping must be restored on close")

      cleanup()
    end)

    it("restores a pre-existing hunk-navigation mapping after close (gitsigns case)", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b", "c" }, { "a", "X", "c" }, function(bufnr)
        vim.keymap.set("n", "]c", function() end, { buffer = bufnr, desc = "gitsigns-next-hunk" })
        vim.keymap.set("n", "[c", function() end, { buffer = bufnr, desc = "gitsigns-prev-hunk" })
      end)

      lifecycle.close(tabpage)
      vim.wait(100)

      local maps = matrix.map_index(mod_buf, "n")
      assert.equals("gitsigns-next-hunk", maps["]c"], "a plugin's ]c must survive a codediff session")
      assert.equals("gitsigns-prev-hunk", maps["[c"], "a plugin's [c must survive a codediff session")

      cleanup()
    end)

    it("releases operator-pending and visual mappings on close", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b", "c" }, { "a", "X", "c" })

      assert.is_not_nil(matrix.map_index(mod_buf, "o")["ih"], "ih should be mapped during the session")

      lifecycle.close(tabpage)
      vim.wait(100)

      assert.is_nil(matrix.map_index(mod_buf, "o")["ih"], "ih must be removed from operator-pending mode on close")
      assert.is_nil(matrix.map_index(mod_buf, "x")["ih"], "ih must be removed from visual mode on close")

      cleanup()
    end)

    it("releases operator-pending and visual mappings when leaving the tab", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b", "c" }, { "a", "X", "c" })

      vim.cmd("tabnew")
      vim.wait(100)

      assert.is_nil(matrix.map_index(mod_buf, "o")["ih"], "ih must not leak into other tabs in operator-pending mode")
      assert.is_nil(matrix.map_index(mod_buf, "x")["ih"], "ih must not leak into other tabs in visual mode")

      cleanup()
    end)

    it("detaches mappings from the previous file when the diff switches files", function()
      local repo = h.create_temp_git_repo()
      repo.write_file("one.txt", { "one", "original" })
      repo.write_file("two.txt", { "two", "original" })
      repo.git("add .")
      repo.git("commit -m initial")
      repo.write_file("one.txt", { "one", "changed" })
      repo.write_file("two.txt", { "two", "changed" })

      vim.cmd("edit " .. vim.fn.fnameescape(repo.path("one.txt")))
      commands.vscode_diff({ fargs = {} })

      local tabpage
      assert.is_true(vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local session = lifecycle.get_session(tp)
          if session and (session.panel or {}).view and (session.panel or {}).view.bufnr then
            tabpage = tp
            return true
          end
        end
        return false
      end, 50), "explorer session should be created")

      local explorer = (lifecycle.get_session(tabpage).panel or {}).view
      explorer.on_file_select({ path = "one.txt", group = "unstaged", status = "M", git_root = repo.dir })
      assert.is_true(wait_for_diff(tabpage), "first file diff should be ready")
      local first_buf = lifecycle.get_session(tabpage).modified_bufnr
      assert.is_not_nil(matrix.map_index(first_buf, "n")["q"], "first file should be mapped while displayed")

      explorer.on_file_select({ path = "two.txt", group = "unstaged", status = "M", git_root = repo.dir })
      assert.is_true(vim.wait(10000, function()
        local session = lifecycle.get_session(tabpage)
        return session and session.modified_bufnr ~= first_buf and session.stored_diff_result ~= nil
      end, 50), "second file diff should be ready")

      assert.is_nil(matrix.map_index(first_buf, "n")["q"], "the previous file's buffer must be detached on file switch")

      repo.cleanup()
    end)

    it("releases compact fold wraps when leaving the tab", function()
      -- The wraps live on real diff buffers, so they must not follow those
      -- buffers into other tabs.
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b", "c" }, { "a", "X", "c" })
      assert.is_true(require("codediff.ui.view.compact").enable(tabpage), "compact should enable")
      assert.is_not_nil(matrix.map_index(mod_buf, "n")["zo"], "zo should be wrapped while compact is active")

      vim.cmd("tabnew")
      vim.wait(100)

      assert.is_nil(matrix.map_index(mod_buf, "n")["zo"], "compact fold wraps must not leak into other tabs")
      cleanup()
    end)

    it("retires layout-specific mappings when the layout changes", function()
      reset_config({ diff = { compute_moves = true, layout = "side-by-side" } })
      local left = temp_file("_move_left.txt", { "a1", "a2", "a3", "a4", "a5", "u1", "u2", "u3", "b1", "b2", "b3", "b4", "b5" })
      local right = temp_file("_move_right.txt", { "u1", "u2", "u3", "b1", "b2", "b3", "b4", "b5", "a1", "a2", "a3", "a4", "a5" })

      view.create({
        git_root = nil,
        original = path.make_ref(left, nil),
        modified = path.make_ref(right, nil),
      })
      local tabpage = vim.api.nvim_get_current_tabpage()
      assert.is_true(wait_for_diff(tabpage), "session should be ready")

      local session = lifecycle.get_session(tabpage)
      assert.is_not_nil(matrix.map_index(session.modified_bufnr, "n")["gm"], "gm should be bound in side-by-side")

      view.toggle_layout(tabpage)
      assert.is_true(vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s and s.layout == "inline" and s.stored_diff_result ~= nil
      end, 50), "layout should toggle to inline")

      session = lifecycle.get_session(tabpage)
      assert.is_nil(matrix.map_index(session.modified_bufnr, "n")["gm"], "gm applies only to side-by-side and must be retired")

      vim.fn.delete(left)
      vim.fn.delete(right)
    end)

    it("retires the previous key when the configuration is changed and reapplied", function()
      local tabpage, mod_buf, cleanup = open_standalone({ "a", "b" }, { "a", "c" })
      assert.is_not_nil(matrix.map_index(mod_buf, "n")["q"], "default quit should be bound")

      require("codediff").setup({ keymaps = { view = { quit = "Q" } } })
      local session = lifecycle.get_session(tabpage)
      if session.reapply_keymaps then
        session.reapply_keymaps()
      end
      vim.wait(200)

      assert.is_not_nil(matrix.map_index(mod_buf, "n")["Q"], "the new quit key should be bound")
      assert.is_nil(matrix.map_index(mod_buf, "n")["q"], "the previous quit key must be released")

      cleanup()
    end)

    it("restores the user's do/dp instead of deleting them in conflict mode", function()
      local repo = h.create_temp_git_repo()
      repo.write_file("conf.txt", { "l1", "l2", "l3" })
      repo.git("add -A")
      repo.git("commit -m base")
      repo.git("checkout -b feature")
      repo.write_file("conf.txt", { "FEATURE", "l2", "l3" })
      repo.git("commit -am feature")
      repo.git("checkout main")
      repo.write_file("conf.txt", { "MAIN", "l2", "l3" })
      repo.git("commit -am main")
      assert.is_truthy(repo.git("merge feature --no-edit"):find("CONFLICT", 1, true), "merge must conflict")

      vim.cmd("edit " .. vim.fn.fnameescape(repo.path("conf.txt")))
      local conflict_buf = vim.api.nvim_get_current_buf()
      vim.keymap.set("n", "do", "<Cmd>echo 'user-do'<CR>", { buffer = conflict_buf, desc = "user-do" })

      local ready = false
      view.create({
        git_root = repo.dir,
        original = path.make_ref("conf.txt", repo.dir),
        modified = path.make_ref("conf.txt", repo.dir),
        original_revision = ":3",
        modified_revision = ":2",
        conflict = true,
      }, "", function()
        ready = true
      end)
      assert.is_true(vim.wait(15000, function()
        return ready
      end, 50), "conflict view should become ready")

      assert.equals("user-do", matrix.map_index(conflict_buf, "n")["do"], "conflict mode must not destroy the user's own do mapping")

      repo.cleanup()
    end)
  end)
end)
