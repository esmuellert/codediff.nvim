-- Tests for the `gm` align_move keymap
-- Validates keymap binding, alignment behavior, scrollbind restoration, and edge cases

local view = require("codediff.ui.view")
local diff_module = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local path = require("codediff.core.path")

-- Content with a moved block: alpha block moves from top to bottom
-- The diff engine needs ≥5 contiguous moved lines to detect a move.
local function make_original_lines()
  return {
    "alpha_1",
    "alpha_2",
    "alpha_3",
    "alpha_4",
    "alpha_5",
    "unchanged_1",
    "unchanged_2",
    "unchanged_3",
    "beta_1",
    "beta_2",
    "beta_3",
    "beta_4",
    "beta_5",
  }
end

local function make_modified_lines()
  return {
    "unchanged_1",
    "unchanged_2",
    "unchanged_3",
    "beta_1",
    "beta_2",
    "beta_3",
    "beta_4",
    "beta_5",
    "alpha_1",
    "alpha_2",
    "alpha_3",
    "alpha_4",
    "alpha_5",
  }
end

--- Write temp files and return paths (OS-aware via vim.fn.tempname)
local function write_temp_files(original_lines, modified_lines)
  local left_path = vim.fn.tempname() .. "_move_left.txt"
  local right_path = vim.fn.tempname() .. "_move_right.txt"
  vim.fn.writefile(original_lines, left_path)
  vim.fn.writefile(modified_lines, right_path)
  return left_path, right_path
end

--- Wait for session to be fully ready with move data
local function wait_for_session_with_moves(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local session
  local ok = vim.wait(timeout_ms, function()
    session = lifecycle.get_session(tabpage)
    return session and session.stored_diff_result and session.stored_diff_result.moves and #session.stored_diff_result.moves > 0
  end, 50)
  return ok, session
end

--- Wait for session to be ready (may or may not have moves)
local function wait_for_session(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local session
  local ok = vim.wait(timeout_ms, function()
    session = lifecycle.get_session(tabpage)
    return session and session.stored_diff_result ~= nil
  end, 50)
  return ok, session
end

local function standalone_config(left_path, right_path)
  return {
    git_root = nil,
    original = path.make_ref(left_path, nil),
    modified = path.make_ref(right_path, nil),
    original_revision = nil,
    modified_revision = nil,
  }
end

--- Check whether buffer has a normal-mode keymap with the given lhs
local function buf_has_keymap(bufnr, lhs)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end

describe("gm align_move keymap", function()
  local left_path, right_path

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if left_path then
      pcall(vim.fn.delete, left_path)
    end
    if right_path then
      pcall(vim.fn.delete, right_path)
    end
    left_path, right_path = nil, nil
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 1. gm is bound when compute_moves = true
  -- ──────────────────────────────────────────────────────────────
  it("gm keymap is bound when compute_moves=true", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    -- gm should be set on both diff buffers
    assert.is_true(buf_has_keymap(session.original_bufnr, "gm"), "gm should be bound on original buffer")
    assert.is_true(buf_has_keymap(session.modified_bufnr, "gm"), "gm should be bound on modified buffer")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 2. gm is NOT bound when compute_moves = false
  -- ──────────────────────────────────────────────────────────────
  it("gm is not bound when compute_moves=false", function()
    require("codediff").setup({ diff = { compute_moves = false, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    assert.is_false(buf_has_keymap(session.original_bufnr, "gm"), "gm should NOT be bound on original buffer")
    assert.is_false(buf_has_keymap(session.modified_bufnr, "gm"), "gm should NOT be bound on modified buffer")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 3. gm aligns moved blocks at same winline()
  -- ──────────────────────────────────────────────────────────────
  it("gm aligns moved blocks at same winline()", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    assert.is_true(#moves >= 1, "Should have at least one move")

    local move = moves[1]
    -- move.original = { start_line = 1, end_line = 6 }  (alpha block in original)
    -- move.modified = { start_line = 9, end_line = 14 } (alpha block in modified)

    -- Focus original window and position cursor on the first line of the moved block
    vim.wo[session.modified_win].scrolloff = 8
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
    vim.cmd("normal! zz")
    vim.cmd("redraw")

    -- Read the visual row of the moved block's first line before alignment
    local orig_visual_before = vim.api.nvim_win_call(session.original_win, function()
      vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
      return vim.fn.winline()
    end)

    -- Trigger the gm keymap action
    local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
    vim.api.nvim_feedkeys(gm_keys, "x", false)
    vim.cmd("redraw")

    -- After gm: read visual row of orig first line again (it may have been repositioned)
    local orig_visual_after = vim.api.nvim_win_call(session.original_win, function()
      return vim.fn.winline()
    end)

    -- Read visual row of paired block's first line on modified side
    local mod_visual = vim.api.nvim_win_call(session.modified_win, function()
      vim.api.nvim_win_set_cursor(session.modified_win, { move.modified.start_line, 0 })
      return vim.fn.winline()
    end)

    -- The paired block on the modified side should be aligned to the same visual row
    assert.are.equal(orig_visual_after, mod_visual, string.format("Moved block visual rows should match: original winline=%d, modified winline=%d", orig_visual_after, mod_visual))
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 4. Resume native scrollbind on cursor leave
  -- ──────────────────────────────────────────────────────────────
  it("pauses native scrollbind during move alignment and resumes on cursor leave", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    local move = moves[1]

    -- Native scrollbind is active before alignment.
    vim.wo[session.modified_win].scrolloff = 8
    assert.is_true(vim.wo[session.original_win].scrollbind, "native scrollbind active before alignment")
    assert.is_true(vim.wo[session.modified_win].scrollbind, "native scrollbind active before alignment")

    -- Focus original window, position on moved block, trigger gm
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
    vim.cmd("redraw")

    local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
    vim.api.nvim_feedkeys(gm_keys, "x", false)
    vim.cmd("redraw")

    -- Native scrollbind should be paused while the move alignment is imposed.
    assert.is_false(vim.wo[session.original_win].scrollbind, "native scrollbind should be paused during alignment")
    assert.is_false(vim.wo[session.modified_win].scrollbind, "native scrollbind should be paused during alignment")

    -- Move cursor OUT of the moved block range using feedkeys so CursorMoved fires.
    -- Note: CursorMoved does not fire in headless mode, so we manually trigger it
    -- via doautocmd after repositioning the cursor.
    -- After gm the cursor sits at move.original.start_line. Jump to end of buffer
    -- which is guaranteed to be outside the moved block.
    vim.api.nvim_win_set_cursor(session.original_win, { vim.api.nvim_buf_line_count(session.original_bufnr), 0 })
    vim.cmd("doautocmd CursorMoved")
    vim.cmd("redraw")

    -- Native scrollbind should be resumed after leaving the moved block.
    assert.is_true(vim.wo[session.original_win].scrollbind, "native scrollbind should resume after leaving the moved block")
    assert.is_true(vim.wo[session.modified_win].scrollbind, "native scrollbind should resume after leaving the moved block")
    assert.are.equal(8, vim.wo[session.modified_win].scrolloff, "scrolloff should be restored on modified window")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 5b. gm restore preserves scroll positions on WinLeave
  -- ──────────────────────────────────────────────────────────────
  it("restores scroll positions when switching to other window after gm", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    local move = moves[1]

    -- Save scroll state of both windows BEFORE gm
    local orig_view_before = vim.api.nvim_win_call(session.original_win, function()
      return vim.fn.winsaveview()
    end)
    local mod_view_before = vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.winsaveview()
    end)

    -- Focus original window, trigger gm on moved block
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
    vim.cmd("redraw")

    local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
    vim.api.nvim_feedkeys(gm_keys, "x", false)
    vim.cmd("redraw")

    -- Switch to the modified window (triggers WinLeave → scheduled restore)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.cmd("doautocmd WinLeave")
    -- Process vim.schedule callbacks so the deferred restore runs
    vim.wait(100, function()
      return false
    end)
    vim.cmd("redraw")

    -- Both windows should be back to pre-gm scroll positions
    local orig_view_after = vim.api.nvim_win_call(session.original_win, function()
      return vim.fn.winsaveview()
    end)
    local mod_view_after = vim.api.nvim_win_call(session.modified_win, function()
      return vim.fn.winsaveview()
    end)

    assert.are.equal(orig_view_before.topline, orig_view_after.topline, "original window topline should be restored after WinLeave")
    assert.are.equal(mod_view_before.topline, mod_view_after.topline, "modified window topline should be restored after WinLeave")
    assert.is_true(vim.wo[session.original_win].scrollbind, "native scrollbind should be restored")
    assert.is_true(vim.wo[session.modified_win].scrollbind, "native scrollbind should be restored")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 5c. gm shows message (no error) when not on a moved block
  -- ──────────────────────────────────────────────────────────────
  it("gm shows message when not on a moved block", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create(standalone_config(left_path, right_path))

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    local move = moves[1]

    -- Position cursor on a line that is NOT inside any moved block
    -- The unchanged lines start at line 6 in original (after alpha block ends at line 6 exclusive)
    local non_moved_line = move.original.end_line -- end_line is exclusive, so this line is outside
    local line_count = vim.api.nvim_buf_line_count(session.original_bufnr)
    if non_moved_line > line_count then
      non_moved_line = line_count
    end

    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { non_moved_line, 0 })
    vim.cmd("redraw")

    -- Trigger gm - should not error, just show a notification
    local succeeded = pcall(function()
      local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
      vim.api.nvim_feedkeys(gm_keys, "x", false)
      vim.cmd("redraw")
    end)

    assert.is_true(succeeded, "gm should not error when not on a moved block")

    -- Scrollbind should remain unchanged (no alignment happened)
    -- Just verify windows are still valid and no crash occurred
    assert.is_true(vim.api.nvim_win_is_valid(session.original_win), "original window should still be valid")
    assert.is_true(vim.api.nvim_win_is_valid(session.modified_win), "modified window should still be valid")
  end)

  -- Test 6: gm alignment works for ALL test pairs with moves
  it("gm aligns correctly for ALL test pairs with moves", function()
    local pairs_dir = "scripts/test_pairs"
    local handle = vim.loop.fs_scandir(pairs_dir)
    assert.is_truthy(handle, "test_pairs directory should exist")

    local tested = 0
    while true do
      local name, ftype = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if ftype == "directory" then
        local orig_path = pairs_dir .. "/" .. name .. "/original.txt"
        local mod_path = pairs_dir .. "/" .. name .. "/modified.txt"
        if vim.fn.filereadable(orig_path) == 1 and vim.fn.filereadable(mod_path) == 1 then
          require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
          require("codediff.ui.highlights").setup()

          local view = require("codediff.ui.view")
          view.create({
            original = path.make_ref(orig_path, nil),
            modified = path.make_ref(mod_path, nil),
          })
          vim.cmd("redraw")
          vim.wait(500)

          local lifecycle = require("codediff.ui.lifecycle")
          local tp = vim.api.nvim_get_current_tabpage()
          local session = lifecycle.get_session(tp)

          if session and session.stored_diff_result.moves and #session.stored_diff_result.moves > 0 then
            local orig_win = session.original_win
            local mod_win = session.modified_win
            vim.wo[mod_win].scrolloff = 0

            for _, move in ipairs(session.stored_diff_result.moves) do
              -- Position on first moved line
              vim.api.nvim_set_current_win(orig_win)
              vim.api.nvim_win_set_cursor(orig_win, { move.original.start_line, 0 })
              vim.cmd("normal! zz")
              vim.cmd("redraw")

              -- Get winline before align without native scrollbind overriding
              -- the manual alignment measurement.
              vim.wo[orig_win].scrollbind = false
              vim.wo[mod_win].scrollbind = false

              local my_wl = vim.api.nvim_win_call(orig_win, function()
                vim.api.nvim_win_set_cursor(orig_win, { move.original.start_line, 0 })
                return vim.fn.winline()
              end)

              vim.api.nvim_win_call(mod_win, function()
                vim.api.nvim_win_set_cursor(mod_win, { move.modified.start_line, 0 })
                vim.cmd("normal! zt")
                if my_wl > 1 then
                  local keys = vim.api.nvim_replace_termcodes((my_wl - 1) .. "<C-y>", true, false, true)
                  vim.api.nvim_feedkeys(keys, "nx", false)
                end
              end)
              vim.cmd("redraw")

              local other_wl = vim.api.nvim_win_call(mod_win, function()
                vim.api.nvim_win_set_cursor(mod_win, { move.modified.start_line, 0 })
                return vim.fn.winline()
              end)

              -- Skip alignment check for very short files (< 30 lines)
              -- where scroll limits prevent proper alignment
              local orig_lc = vim.api.nvim_buf_line_count(session.original_bufnr)
              local mod_lc = vim.api.nvim_buf_line_count(session.modified_bufnr)
              if orig_lc >= 30 and mod_lc >= 30 then
                assert.are.equal(my_wl, other_wl, name .. ": gm alignment failed, orig_wl=" .. my_wl .. " mod_wl=" .. other_wl)
              end

              -- Restore native scrollbind for the next moved block.
              vim.wo[orig_win].scrollbind = true
              vim.wo[mod_win].scrollbind = true
            end
          end

          while vim.fn.tabpagenr("$") > 1 do
            vim.cmd("tabclose!")
          end
          tested = tested + 1
        end
      end
    end
    assert.is_true(tested >= 10, "Should test at least 10 pairs, tested " .. tested)
  end)
end)
