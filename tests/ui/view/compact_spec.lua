-- Tests for codediff.ui.view.compact (#344).
-- Focus:
--   * compute_visible_lines: pure, deterministic — fully unit-testable.
--   * enable/disable round-trip: fold settings save+restore exactly.
--   * toggle idempotence.
--   * Module-level visible_lines_by_win is populated on enable, cleared on disable.

local compact = require("codediff.ui.view.compact")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local path = require("codediff.core.path")
local side_by_side_update = require("codediff.ui.view.side_by_side.update")

local function get_temp_path(name)
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local dir = is_win and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_win and "\\" or "/"
  return dir .. sep .. name
end

-- Build a real codediff diff session whose left/right buffers contain the
-- given line arrays, returning (tabpage, session, left_path, right_path).
local function create_session(original, modified)
  local left = get_temp_path("compact_spec_left.txt")
  local right = get_temp_path("compact_spec_right.txt")
  vim.fn.writefile(original, left)
  vim.fn.writefile(modified, right)

  local ready = false
  view.create({
    git_root = nil,
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
    original_revision = nil,
    modified_revision = nil,
  }, "", function() ready = true end)

  local tabpage = vim.api.nvim_get_current_tabpage()

  -- view.create for real files schedules its render asynchronously; wait
  -- for the on_ready callback OR the session to gain windows.
  vim.wait(5000, function()
    if ready then return true end
    local s = lifecycle.get_session(tabpage)
    return s ~= nil and s.original_win ~= nil and s.modified_win ~= nil
  end, 20)

  return tabpage, lifecycle.get_session(tabpage), left, right
end

local function folded_lines(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return 0
  end
  return vim.api.nvim_win_call(win, function()
    local count = 0
    for line = 1, vim.fn.line("$") do
      if vim.fn.foldclosed(line) ~= -1 then
        count = count + 1
      end
    end
    return count
  end)
end

local function has_synced_fold_keymap(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if (map.desc or ""):find("codediff: synced fold", 1, true) then
      return true
    end
  end
  return false
end

describe("compact mode (#344)", function()
  before_each(function()
    -- M.setup merges on top of M.options (not defaults), so we have to
    -- reset to defaults each test to undo state from prior tests.
    local config = require("codediff.config")
    config.options = vim.deepcopy(config.defaults)
    require("codediff").setup({
      diff = { layout = "side-by-side", compact_context_lines = 3 },
    })
    highlights.setup()
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
    -- The two scratch buffers backing create_session persist across tests
    -- because their on-disk paths are the same; delete them so each test
    -- starts with a fresh keymap state.
    for _, name in ipairs({
      "compact_spec_left.txt",
      "compact_spec_right.txt",
      "compact_spec_switch_left.txt",
      "compact_spec_switch_right.txt",
    }) do
      local path = get_temp_path(name)
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end)

  -- =====================================================================
  -- compute_visible_lines: pure function tests
  -- =====================================================================

  describe("compute_visible_lines", function()
    local function make_change(orig_start, orig_end, mod_start, mod_end)
      return {
        original = { start_line = orig_start, end_line = orig_end },
        modified = { start_line = mod_start, end_line = mod_end },
      }
    end

    it("returns empty set when there are no changes", function()
      local visible = compact.compute_visible_lines({}, "original", 100, 3)
      assert.same({}, visible)
    end)

    it("includes hunk lines plus N context lines on each side", function()
      -- One hunk at lines 10-13 (exclusive end), context = 3
      -- Expected visible: 7..15 (3 before line 10, the 3 hunk lines, 3 after line 12)
      local changes = { make_change(10, 13, 10, 13) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      for l = 7, 15 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[6], "line 6 should be folded")
      assert.is_nil(visible[16], "line 16 should be folded")
    end)

    it("clamps context to buffer bounds at the top", function()
      -- Hunk at line 1, context = 3 — can't go below line 1.
      local changes = { make_change(1, 2, 1, 2) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      assert.is_true(visible[1])
      assert.is_true(visible[4])
      assert.is_nil(visible[5])
    end)

    it("clamps context to buffer bounds at the bottom", function()
      -- Hunk at last line of 10-line buffer.
      local changes = { make_change(10, 11, 10, 11) }
      local visible = compact.compute_visible_lines(changes, "original", 10, 3)
      assert.is_true(visible[10])
      assert.is_true(visible[7])
      assert.is_nil(visible[11], "buffer only has 10 lines")
    end)

    it("shows context on both sides of zero-width ranges without an extra anchor line", function()
      -- A zero-width range is a boundary between lines, not a changed line.
      -- With context=2, show two real lines on either side: 3..6.
      local changes = { make_change(5, 5, 5, 8) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 2)
      for l = 3, 6 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[2])
      assert.is_nil(visible[7])
    end)

    it("merges overlapping hunks' visible ranges via set union", function()
      -- Two adjacent hunks whose context windows overlap.
      local changes = {
        make_change(10, 11, 10, 11),
        make_change(13, 14, 13, 14),
      }
      local visible = compact.compute_visible_lines(changes, "original", 100, 3)
      -- First: 7..13, second: 10..16. Union: 7..16.
      for l = 7, 16 do
        assert.is_true(visible[l], "line " .. l .. " should be visible")
      end
      assert.is_nil(visible[6])
      assert.is_nil(visible[17])
    end)

    it("uses the requested side (original vs modified) for line ranges", function()
      -- Pure insertion: original range zero-width at line 5, modified at lines 10-13.
      local changes = { make_change(5, 5, 10, 13) }

      local orig_visible = compact.compute_visible_lines(changes, "original", 100, 2)
      local mod_visible = compact.compute_visible_lines(changes, "modified", 100, 2)

      -- Original side: anchor at 5, ±2 context → 3..6.
      assert.is_true(orig_visible[5])
      assert.is_true(orig_visible[3])
      assert.is_true(orig_visible[6])
      assert.is_nil(orig_visible[7])
      assert.is_nil(orig_visible[10])

      -- Modified side: hunk 10..12, ±2 context → 8..14.
      assert.is_true(mod_visible[10])
      assert.is_true(mod_visible[14])
      assert.is_nil(mod_visible[5])
    end)

    it("aligns the first folded line after a pure insertion", function()
      local changes = { make_change(50, 50, 60, 61) }
      local original = compact.compute_visible_lines(changes, "original", 100, 3)
      local modified = compact.compute_visible_lines(changes, "modified", 110, 3)

      -- Context ends at 52/63, so the next folds begin at corresponding
      -- unchanged lines 53/64. Before the fix, the original fold began at 54.
      assert.is_true(original[52])
      assert.is_true(modified[63])
      assert.is_nil(original[53])
      assert.is_nil(modified[64])
      assert.equal(64, compact.compute_corresponding_lnum(changes, "original", "modified", 53))
    end)

    it("supports zero context (only the hunk lines visible)", function()
      local changes = { make_change(10, 13, 10, 13) }
      local visible = compact.compute_visible_lines(changes, "original", 100, 0)
      assert.is_true(visible[10])
      assert.is_true(visible[12])
      assert.is_nil(visible[9])
      assert.is_nil(visible[13])
    end)
  end)

  -- =====================================================================
  -- enable / disable round-trip
  -- =====================================================================

  describe("enable/disable round-trip on a real session", function()
    it("returns false when there is no session", function()
      -- Use a tabpage id that doesn't have a session attached.
      assert.is_false(compact.enable(9999))
    end)

    it("enable sets foldmethod=expr; disable restores prior fold settings", function()
      local original = {}
      local modified = {}
      for i = 1, 30 do
        original[i] = "line " .. i
        modified[i] = "line " .. i
      end
      modified[15] = "line 15 CHANGED"

      local tabpage, session = create_session(original, modified)
      assert.is_not_nil(session.stored_diff_result, "diff must be computed for compact mode to act")
      assert.is_not_nil(session.original_win, "session must have original_win")
      assert.is_not_nil(session.modified_win, "session must have modified_win")

      -- Snapshot the pre-compact fold settings on both panes.
      local pre = {}
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        pre[win] = {
          foldmethod = vim.wo[win].foldmethod,
          foldexpr = vim.wo[win].foldexpr,
          foldlevel = vim.wo[win].foldlevel,
          foldminlines = vim.wo[win].foldminlines,
          foldenable = vim.wo[win].foldenable,
          foldtext = vim.wo[win].foldtext,
        }
      end

      assert.is_true(compact.enable(tabpage))
      assert.is_true(session.compact_mode)
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        assert.equal("expr", vim.wo[win].foldmethod)
        assert.is_true(vim.wo[win].foldexpr:find("compact", 1, true) ~= nil,
          "foldexpr should reference the compact module")
        assert.is_true(vim.wo[win].foldenable)
      end

      assert.is_true(compact.disable(tabpage))
      assert.is_false(session.compact_mode == true,
        "session.compact_mode should be cleared on disable")

      -- Every pre-compact fold setting must be restored exactly.
      for _, win in ipairs({ session.original_win, session.modified_win }) do
        for opt, expected in pairs(pre[win]) do
          assert.equal(expected, vim.wo[win][opt],
            opt .. " should be restored on disable (win " .. win .. ")")
        end
      end
    end)

    it("toggle alternates enable and disable", function()
      local original = {}
      local modified = {}
      for i = 1, 20 do
        original[i] = "L" .. i
        modified[i] = "L" .. i
      end
      modified[10] = "L10 changed"

      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.toggle(tabpage))
      assert.is_true(session.compact_mode)
      assert.is_true(compact.toggle(tabpage))
      assert.is_false(session.compact_mode == true)
      assert.is_true(compact.toggle(tabpage))
      assert.is_true(session.compact_mode)
    end)

    it("enable is idempotent (second call is a no-op success)", function()
      local original, modified = { "a", "b", "c" }, { "a", "B", "c" }
      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.enable(tabpage))
      local saved_state_first = session.compact_saved_fold_state
      -- Second call should still return true without overwriting saved state.
      assert.is_true(compact.enable(tabpage))
      assert.equal(saved_state_first, session.compact_saved_fold_state,
        "second enable must not overwrite the saved fold state")
    end)

    it("returns false when there are no changes to compact", function()
      -- Identical files → no hunks.
      local lines = { "a", "b", "c" }
      local tabpage, session = create_session(lines, lines)
      assert.equal(0, #(session.stored_diff_result.changes or {}),
        "sanity: identical files should produce zero changes")
      assert.is_false(compact.enable(tabpage))
      assert.is_true(session.compact_mode, "enabling compact records the session preference even without hunks")
      assert.is_nil(session.compact_saved_fold_state)
    end)
  end)

  -- =====================================================================
  -- synced folds (#171)
  -- =====================================================================

  describe("compute_corresponding_lnum", function()
    local function make_change(o_start, o_end, m_start, m_end)
      return {
        original = { start_line = o_start, end_line = o_end },
        modified = { start_line = m_start, end_line = m_end },
      }
    end

    it("identity when from_side == to_side", function()
      assert.equal(7, compact.compute_corresponding_lnum({}, "original", "original", 7))
    end)

    it("returns same line when no changes (perfect identity)", function()
      assert.equal(42, compact.compute_corresponding_lnum({}, "original", "modified", 42))
    end)

    it("returns same line when before the first change", function()
      local changes = { make_change(10, 12, 10, 15) }
      assert.equal(5, compact.compute_corresponding_lnum(changes, "original", "modified", 5))
    end)

    it("applies cumulative delta after a change", function()
      -- A 2-line region (original 10-11) was replaced by 5 lines (modified 10-14).
      -- Delta past the change: +3. Original line 20 -> modified line 23.
      local changes = { make_change(10, 12, 10, 15) }
      assert.equal(23, compact.compute_corresponding_lnum(changes, "original", "modified", 20))
    end)

    it("applies negative delta when the modified side is shorter", function()
      -- 5-line region (original 10-14) collapses to 2 lines (modified 10-11). Delta -3.
      local changes = { make_change(10, 15, 10, 12) }
      assert.equal(17, compact.compute_corresponding_lnum(changes, "original", "modified", 20))
    end)

    it("accumulates delta across multiple changes", function()
      local changes = {
        make_change(5, 6, 5, 7),    -- +1
        make_change(15, 16, 16, 19), -- +2 more -> cumulative +3
      }
      assert.equal(53, compact.compute_corresponding_lnum(changes, "original", "modified", 50))
    end)

    it("maps a line inside a change to the corresponding sub-line on the other side", function()
      -- 4-line original 10-13 maps to 4-line modified 10-13. Middle line maps proportionally.
      local changes = { make_change(10, 14, 10, 14) }
      -- Line 11 (offset 1 of 4) -> 10 + floor(1*4/4) = 11
      assert.equal(11, compact.compute_corresponding_lnum(changes, "original", "modified", 11))
    end)

    it("maps a line inside a pure insertion (zero-width source) to the insertion start", function()
      -- Pure insertion at base line 10: original [10,10) -> modified [10,13). Source query
      -- has nothing to map, but if a caller asks about line 10 we return modified.start_line.
      local changes = { make_change(10, 10, 10, 13) }
      -- Line 10 is past from.start_line (10) but also past from.end_line (10), so
      -- treated as past-the-change: delta = (13-10) = +3, mapped to 13.
      assert.equal(13, compact.compute_corresponding_lnum(changes, "original", "modified", 10))
    end)

    it("works in the reverse direction (modified -> original)", function()
      local changes = { make_change(10, 12, 10, 15) }
      -- Modified 23 -> original 20 (inverse of the previous +3 delta case)
      assert.equal(20, compact.compute_corresponding_lnum(changes, "modified", "original", 23))
    end)
  end)

  describe("synced folds integration", function()
    local function counts_with_changes()
      local original, modified = {}, {}
      for i = 1, 40 do
        original[i] = "L" .. i
        modified[i] = "L" .. i
      end
      -- A few isolated changes at lines 10 and 25.
      modified[10] = "L10 CHANGED"
      modified[25] = "L25 CHANGED"
      return original, modified
    end

    it("installs synced-fold keymaps on both panes when enabled", function()
      local tabpage, session = create_session(counts_with_changes())
      assert.is_true(compact.enable(tabpage))

      for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
        local maps = vim.api.nvim_buf_get_keymap(buf, "n")
        local found_zo, found_zc = false, false
        for _, m in ipairs(maps) do
          if m.lhs == "zo" and (m.desc or ""):find("synced fold") then found_zo = true end
          if m.lhs == "zc" and (m.desc or ""):find("synced fold") then found_zc = true end
        end
        assert.is_true(found_zo, "buffer should have synced 'zo' keymap")
        assert.is_true(found_zc, "buffer should have synced 'zc' keymap")
      end
    end)

    it("does NOT install synced-fold keymaps when compact_sync_folds = false", function()
      require("codediff").setup({
        diff = { layout = "side-by-side", compact_context_lines = 3, compact_sync_folds = false },
      })

      local tabpage, session = create_session(counts_with_changes())
      assert.is_true(compact.enable(tabpage))

      for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
        local maps = vim.api.nvim_buf_get_keymap(buf, "n")
        for _, m in ipairs(maps) do
          assert.is_nil(((m.desc or ""):find("codediff: synced fold")),
            "no synced-fold keymap should be installed when option is false")
        end
      end
    end)

    it("removes synced-fold keymaps on disable", function()
      local tabpage, session = create_session(counts_with_changes())
      assert.is_true(compact.enable(tabpage))
      assert.is_true(compact.disable(tabpage))

      for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
        if vim.api.nvim_buf_is_valid(buf) then
          local maps = vim.api.nvim_buf_get_keymap(buf, "n")
          for _, m in ipairs(maps) do
            assert.is_nil((m.desc or ""):find("codediff: synced fold"),
              "synced-fold keymap should be gone after disable")
          end
        end
      end
    end)

    it("does NOT install synced-fold keymaps in inline layout (single pane)", function()
      require("codediff").setup({
        diff = { layout = "inline", compact_context_lines = 3 },
      })

      local original, modified = counts_with_changes()
      local tabpage, session = create_session(original, modified)
      -- In inline mode there's just one pane; "synced" has no meaning.
      assert.is_true(compact.enable(tabpage))

      local buf = session.modified_bufnr
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local maps = vim.api.nvim_buf_get_keymap(buf, "n")
        for _, m in ipairs(maps) do
          assert.is_nil((m.desc or ""):find("codediff: synced fold"),
            "no synced-fold keymap in inline mode")
        end
      end
    end)

    it("pressing zc on one pane folds the corresponding region on the partner pane", function()
      local tabpage, session = create_session(counts_with_changes())
      assert.is_true(compact.enable(tabpage))

      -- Sanity: keymap is installed (otherwise sync can't fire).
      local found = false
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(session.original_bufnr, "n")) do
        if m.lhs == "zc" and (m.desc or ""):find("synced fold") then found = true end
      end
      assert.is_true(found, "synced-fold zc keymap must be installed on original pane")

      -- Open all folds first so both panes start fully expanded; then we
      -- close at line 20 (unchanged region) on the original pane.
      vim.api.nvim_set_current_win(session.original_win)
      vim.cmd("normal! zR")
      vim.api.nvim_set_current_win(session.modified_win)
      vim.cmd("normal! zR")

      -- Both panes should currently show line 20 as not in a closed fold.
      local orig_before = vim.fn.foldclosed(20)
      assert.equal(-1, orig_before)

      -- Move cursor on original pane to line 20 and press zc (close fold).
      vim.api.nvim_set_current_win(session.original_win)
      vim.api.nvim_win_set_cursor(session.original_win, { 20, 0 })
      vim.api.nvim_feedkeys("zc", "tx", false)

      -- After the wrapped zc fires:
      --   * original pane: line 20 should be inside a closed fold
      --   * modified pane: corresponding line should also be inside a closed fold
      local orig_after = vim.fn.foldclosed(20)
      local mod_target = compact.compute_corresponding_lnum(
        session.stored_diff_result.changes, "original", "modified", 20
      )
      local mod_after = vim.api.nvim_win_call(session.modified_win, function()
        return vim.fn.foldclosed(mod_target)
      end)

      assert.is_true(orig_after > 0,
        "original pane: line 20 should be inside a closed fold after zc, got foldclosed=" .. orig_after)
      assert.is_true(mod_after > 0,
        "modified pane: corresponding line " .. mod_target .. " should also be inside a closed fold (synced), got " .. mod_after)
    end)
  end)

  describe("open in compact mode by default (diff.compact)", function()
    local function counts_with_changes()
      local original = {}
      for i = 1, 30 do
        original[i] = "line " .. i
      end
      local modified = vim.deepcopy(original)
      modified[10] = "CHANGED 10"
      modified[20] = "CHANGED 20"
      return original, modified
    end

    it("auto-enables compact mode on open when diff.compact = true", function()
      local config = require("codediff.config")
      config.options = vim.deepcopy(config.defaults)
      require("codediff").setup({ diff = { compact = true, compact_context_lines = 3 } })
      highlights.setup()

      local original, modified = counts_with_changes()
      local tabpage = create_session(original, modified)

      assert.is_true(
        vim.wait(3000, function()
          local s = lifecycle.get_session(tabpage)
          return s and s.compact_mode == true
        end, 20),
        "diff.compact=true should auto-enable compact mode on open"
      )
      local s = lifecycle.get_session(tabpage)
      assert.equals("expr", vim.wo[s.modified_win].foldmethod, "compact should apply the fold-expr to the modified window on open")
    end)

    it("issue #496: applies the default after an empty initial diff", function()
      local config = require("codediff.config")
      config.options = vim.deepcopy(config.defaults)
      require("codediff").setup({ diff = { compact = true, compact_context_lines = 3 } })
      highlights.setup()

      local original = {}
      for i = 1, 30 do
        original[i] = "line " .. i
      end
      local tabpage, session = create_session(original, original)

      assert.is_true(session.compact_mode, "the global default should be stored on the session immediately")
      assert.is_nil(session.compact_saved_fold_state)

      -- An empty result may omit the `changes` field entirely.
      lifecycle.update_diff_result(tabpage, {})
      compact.refresh(tabpage)
      assert.is_true(session.compact_mode)
      assert.is_nil(session.compact_saved_fold_state)

      local modified = vim.deepcopy(original)
      modified[15] = "changed"
      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, modified)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, modified))
      compact.refresh(tabpage)

      assert.is_true(session.compact_mode, "compact should apply when a later file gains a hunk")
      assert.equals("expr", vim.wo[session.modified_win].foldmethod)
    end)

    it("does not auto-enable compact mode when diff.compact = false", function()
      local config = require("codediff.config")
      config.options = vim.deepcopy(config.defaults)
      require("codediff").setup({ diff = { compact = false } })
      highlights.setup()

      local original, modified = counts_with_changes()
      local tabpage = create_session(original, modified)
      vim.wait(500)

      local s = lifecycle.get_session(tabpage)
      assert.is_not.equal(true, s.compact_mode, "compact should stay off when diff.compact is false (the default)")
    end)

    it("allows manual enable before the first hunk when the default is false", function()
      local original, modified = counts_with_changes()
      local tabpage, session = create_session(original, original)

      assert.is_false(session.compact_mode)
      assert.is_false(compact.toggle(tabpage))
      assert.is_true(session.compact_mode)

      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, modified)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, modified))
      compact.refresh(tabpage)

      assert.equals("expr", vim.wo[session.modified_win].foldmethod)
    end)

    it("keeps each session's compact preference isolated", function()
      local config = require("codediff.config")
      config.options = vim.deepcopy(config.defaults)
      require("codediff").setup({ diff = { compact = true, compact_context_lines = 3 } })
      highlights.setup()

      local original, modified = counts_with_changes()
      local first_tabpage, first_session = create_session(original, modified)
      local second_tabpage, second_session = create_session(original, modified)

      assert.is_not.equal(first_tabpage, second_tabpage)
      assert.is_true(first_session.compact_mode)
      assert.is_true(second_session.compact_mode)

      assert.is_true(compact.disable(first_tabpage))
      assert.is_false(first_session.compact_mode)
      assert.is_true(second_session.compact_mode)
      assert.equals("expr", vim.wo[second_session.modified_win].foldmethod)
    end)

    it("does not re-enable compact after a manual gc toggle-off (persists per session)", function()
      local config = require("codediff.config")
      config.options = vim.deepcopy(config.defaults)
      require("codediff").setup({ diff = { compact = true, compact_context_lines = 3 } })
      highlights.setup()

      local original, modified = counts_with_changes()
      local tabpage = create_session(original, modified)
      assert.is_true(
        vim.wait(3000, function()
          local s = lifecycle.get_session(tabpage)
          return s and s.compact_mode == true
        end, 20),
        "should auto-enable on open"
      )

      -- User turns it off with gc
      compact.disable(tabpage)
      assert.is_not.equal(true, lifecycle.get_session(tabpage).compact_mode)

      -- A file switch re-runs the lifecycle hook; the default must NOT force compact back on
      compact.refresh(tabpage)
      assert.is_not.equal(true, lifecycle.get_session(tabpage).compact_mode, "compact must stay off after a manual toggle-off, even with diff.compact=true")
    end)
  end)

  describe("issue #544: compact mode across no-hunk diffs", function()
    local function diff_with_changes()
      local original = {}
      for i = 1, 30 do
        original[i] = "line " .. i
      end
      local modified = vim.deepcopy(original)
      modified[15] = "changed"
      return original, modified
    end

    it("keeps the preference and clears stale folds when changes disappear", function()
      local original, modified = diff_with_changes()
      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.enable(tabpage))
      assert.is_true(folded_lines(session.modified_win) > 0)
      assert.is_true(has_synced_fold_keymap(session.original_bufnr))
      assert.is_true(has_synced_fold_keymap(session.modified_bufnr))

      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, original)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, original))
      compact.refresh(tabpage)

      assert.is_true(session.compact_mode)
      assert.equals(0, folded_lines(session.modified_win))
      assert.is_false(has_synced_fold_keymap(session.original_bufnr))
      assert.is_false(has_synced_fold_keymap(session.modified_bufnr))

      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, modified)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, modified))
      compact.refresh(tabpage)

      assert.is_true(session.compact_mode)
      assert.is_true(folded_lines(session.modified_win) > 0)
      assert.is_true(has_synced_fold_keymap(session.original_bufnr))
      assert.is_true(has_synced_fold_keymap(session.modified_bufnr))
    end)

    it("preserves the preference across a real view update", function()
      local original, modified = diff_with_changes()
      local tabpage, session, left_path, right_path = create_session(original, modified)

      assert.is_true(compact.enable(tabpage))
      assert.is_true(folded_lines(session.original_win) > 0)
      assert.is_true(folded_lines(session.modified_win) > 0)

      local empty_left = get_temp_path("compact_spec_switch_left.txt")
      local empty_right = get_temp_path("compact_spec_switch_right.txt")
      vim.fn.writefile(original, empty_left)
      vim.fn.writefile(original, empty_right)

      assert.is_true(
        side_by_side_update.update(
          tabpage,
          {
            git_root = nil,
            original = path.make_ref(empty_left, nil),
            modified = path.make_ref(empty_right, nil),
            original_revision = nil,
            modified_revision = nil,
          },
          false
        )
      )
      assert.is_true(
        vim.wait(3000, function()
          local current = lifecycle.get_session(tabpage)
          return current
            and current.stored_diff_result
            and current.stored_diff_result.changes
            and #current.stored_diff_result.changes == 0
        end, 20),
        "empty diff did not finish updating"
      )

      assert.is_true(session.compact_mode)
      assert.equals(0, folded_lines(session.original_win))
      assert.equals(0, folded_lines(session.modified_win))

      assert.is_true(
        side_by_side_update.update(
          tabpage,
          {
            git_root = nil,
            original = path.make_ref(left_path, nil),
            modified = path.make_ref(right_path, nil),
            original_revision = nil,
            modified_revision = nil,
          },
          false
        )
      )
      assert.is_true(
        vim.wait(3000, function()
          local current = lifecycle.get_session(tabpage)
          return current
            and current.stored_diff_result
            and current.stored_diff_result.changes
            and #current.stored_diff_result.changes > 0
        end, 20),
        "changed diff did not finish updating"
      )

      assert.is_true(session.compact_mode)
      assert.is_true(folded_lines(session.original_win) > 0)
      assert.is_true(folded_lines(session.modified_win) > 0)
    end)

    it("preserves a manual disable across a no-hunk diff", function()
      local original, modified = diff_with_changes()
      local tabpage, session = create_session(original, modified)

      assert.is_true(compact.enable(tabpage))
      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, original)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, original))
      compact.refresh(tabpage)

      assert.is_true(compact.toggle(tabpage))
      assert.is_false(session.compact_mode)

      vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, modified)
      lifecycle.update_diff_result(tabpage, diff.compute_diff(original, modified))
      compact.refresh(tabpage)

      assert.is_false(session.compact_mode)
      assert.equals(0, folded_lines(session.modified_win))
    end)
  end)
end)
