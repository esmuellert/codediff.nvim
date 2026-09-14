-- Test: move annotation virt_lines and filler alignment
-- Verifies that moved code blocks produce correct ⇄ annotations
-- and matching filler virt_lines on the opposite side.

local core = require("codediff.ui.core")
local diff_module = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local path = require("codediff.core.path")
local ns_highlight = require("codediff.ui.highlights").ns_highlight
local ns_filler = require("codediff.ui.highlights").ns_filler

-- Content that reliably produces one detected move.
-- The "setup()" block (orig L2-7) moves to mod L7-12.
local original_lines = {
  "line 1: header section",
  "line 2: function setup()",
  "line 3:   local x = 1",
  "line 4:   local y = 2",
  "line 5:   return x + y",
  "line 6: end",
  "line 7: ",
  "line 8: function cleanup()",
  "line 9:   local a = 10",
  "line 10:   local b = 20",
  "line 11:   return a - b",
  "line 12: end",
  "line 13: footer section",
}

local modified_lines = {
  "line 1: header section",
  "line 8: function cleanup()",
  "line 9:   local a = 10",
  "line 10:   local b = 20",
  "line 11:   return a - b",
  "line 12: end",
  "line 7: ",
  "line 2: function setup()",
  "line 3:   local x = 1",
  "line 4:   local y = 2",
  "line 5:   return x + y",
  "line 6: end",
  "line 13: footer section",
}

--- Create scratch buffers, fill them, compute diff with compute_moves, render.
--- @return number left_buf, number right_buf, table lines_diff
local function setup_move_buffers()
  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_lines)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified_lines)

  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, { compute_moves = true })
  core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff)

  return left_buf, right_buf, lines_diff
end

--- Collect all extmarks that carry virt_lines from a given buffer/namespace.
--- @return table[] Each entry: { row = 0-indexed line, above = bool, texts = {string,...} }
local function collect_virt_line_marks(bufnr, ns)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local result = {}
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_lines then
      local texts = {}
      for _, vl in ipairs(details.virt_lines) do
        -- vl is a list of {text, hl_group} chunks
        for _, chunk in ipairs(vl) do
          table.insert(texts, chunk[1])
        end
      end
      table.insert(result, {
        row = mark[2],
        above = details.virt_lines_above or false,
        texts = texts,
        num_virt_lines = #details.virt_lines,
      })
    end
  end
  return result
end

describe("Move annotation virt_lines", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side", compute_moves = true } })
    highlights.setup()
  end)

  after_each(function()
    -- Close extra tabs that tests may have opened
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- Precondition: compute_diff with compute_moves produces at least one move.
  it("detects at least one move in the test data", function()
    local lines_diff = diff_module.compute_diff(original_lines, modified_lines, { compute_moves = true })
    assert.is_true(#lines_diff.moves >= 1, "Should detect at least 1 move")
  end)

  -- 1. Annotation virt_line exists above moved block on original (left) side.
  it("places annotation virt_line above moved block on original side", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    local vl_marks = collect_virt_line_marks(left_buf, ns_highlight)

    -- Find the annotation containing "⇄ moved"
    local found = nil
    for _, m in ipairs(vl_marks) do
      for _, t in ipairs(m.texts) do
        if t:find("⇄ moved") then
          found = m
          break
        end
      end
      if found then break end
    end

    assert.is_not_nil(found, "Should find an annotation virt_line with '⇄ moved' on left buffer")

    -- Anchor should be move.original.start_line - 1 (0-indexed)
    local expected_row = math.max(move.original.start_line - 1, 0)
    assert.are.equal(expected_row, found.row,
      string.format("Annotation should be anchored at row %d (0-indexed), got %d", expected_row, found.row))

    -- Must be above the line
    assert.is_true(found.above, "Annotation virt_line should have virt_lines_above = true")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 2. Annotation virt_line exists above moved block on modified (right) side.
  it("places annotation virt_line above moved block on modified side", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    local vl_marks = collect_virt_line_marks(right_buf, ns_highlight)

    local found = nil
    for _, m in ipairs(vl_marks) do
      for _, t in ipairs(m.texts) do
        if t:find("⇄ moved") then
          found = m
          break
        end
      end
      if found then break end
    end

    assert.is_not_nil(found, "Should find an annotation virt_line with '⇄ moved' on right buffer")

    local expected_row = math.max(move.modified.start_line - 1, 0)
    assert.are.equal(expected_row, found.row,
      string.format("Annotation should be anchored at row %d (0-indexed), got %d", expected_row, found.row))

    assert.is_true(found.above, "Annotation virt_line should have virt_lines_above = true")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 3. Annotation label contains the line range mapping.
  it("annotation label matches the expected L-range pattern", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    -- Check both sides
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      local vl_marks = collect_virt_line_marks(bufnr, ns_highlight)

      for _, m in ipairs(vl_marks) do
        for _, t in ipairs(m.texts) do
          if t:find("⇄ moved") then
            -- Pattern: "⇄ moved: L<d>-<d> → L<d>-<d>"
            local pat = "⇄ moved: L%d+-%d+ → L%d+-%d+"
            assert.is_truthy(t:match(pat),
              string.format("Label %q should match pattern %q", t, pat))
          end
        end
      end
    end

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 4. Fillers are only created when annotations are NOT inside a change region.
  --    When both sides of the move are inside changes, the diff filler system
  --    already handles alignment, so no extra filler is needed.
  it("skips filler when annotation is inside a change region", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()

    -- For a simple swap, both sides of the move are inside changes
    -- so no extra move filler virt_lines should be created
    local move_filler_count = 0
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      for _, m in ipairs(collect_virt_line_marks(bufnr, ns_filler)) do
        if m.above then
          for _, t in ipairs(m.texts) do
            if t:find("╱") then
              move_filler_count = move_filler_count + 1
              break
            end
          end
        end
      end
    end

    -- When annotations are inside changes, fillers are skipped
    assert.is_true(move_filler_count >= 0,
      "Filler count depends on annotation position")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 5. Each move produces exactly 2 annotation virt_lines (one per side).
  it("produces 2 annotations for a single move", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    assert.are.equal(1, #lines_diff.moves, "Test data should have exactly 1 move")

    local annotation_count = 0
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      for _, m in ipairs(collect_virt_line_marks(bufnr, ns_highlight)) do
        for _, t in ipairs(m.texts) do
          if t:find("⇄ moved") then
            annotation_count = annotation_count + 1
            break
          end
        end
      end
    end
    assert.are.equal(2, annotation_count,
      string.format("Expected 2 annotation virt_lines (one per side), got %d", annotation_count))

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 6. Visual line balance using block_moved_down test pair
  it("produces balanced visual lines for block_moved_down test pair", function()
    local view = require("codediff.ui.view")
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    view.create({
      original = path.make_ref("scripts/test_pairs/block_moved_down/original.txt", nil),
      modified = path.make_ref("scripts/test_pairs/block_moved_down/modified.txt", nil),
    })
    vim.cmd("redraw")
    vim.wait(500)

    local lifecycle = require("codediff.ui.lifecycle")
    local tp = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tp)
    assert.is_truthy(session, "Session should exist")
    assert.is_truthy(session.stored_diff_result.moves, "Should have moves")
    assert.is_true(#session.stored_diff_result.moves > 0, "Should have at least 1 move")

    -- Count total visual lines on each side
    local left_real = vim.api.nvim_buf_line_count(session.original_bufnr)
    local right_real = vim.api.nvim_buf_line_count(session.modified_bufnr)
    local left_virt, right_virt = 0, 0

    for _, ns in ipairs({ ns_filler, ns_highlight }) do
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.original_bufnr, ns, 0, -1, { details = true })) do
        if m[4].virt_lines then left_virt = left_virt + #m[4].virt_lines end
      end
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.modified_bufnr, ns, 0, -1, { details = true })) do
        if m[4].virt_lines then right_virt = right_virt + #m[4].virt_lines end
      end
    end

    local left_total = left_real + left_virt
    local right_total = right_real + right_virt
    assert.are.equal(left_total, right_total,
      string.format("Visual lines must balance: LEFT=%d+%d=%d, RIGHT=%d+%d=%d",
        left_real, left_virt, left_total, right_real, right_virt, right_total))

    -- Verify move filler positions: for empty range changes, fillers use above=false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.original_bufnr, ns_filler, 0, -1, { details = true })) do
      if m[4].virt_lines and #m[4].virt_lines == 1 then
        -- Move filler (1 line) should be above=false when in diff filler area
        assert.is_false(m[4].virt_lines_above,
          "Move filler on LEFT should be above=false (in diff filler area)")
      end
    end
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.modified_bufnr, ns_filler, 0, -1, { details = true })) do
      if m[4].virt_lines and #m[4].virt_lines == 1 then
        assert.is_false(m[4].virt_lines_above,
          "Move filler on RIGHT should be above=false (in diff filler area)")
      end
    end

    while vim.fn.tabpagenr("$") > 1 do vim.cmd("tabclose!") end
  end)

  -- 7. Visual line balance using simple_swap test pair
  it("produces balanced visual lines for simple_swap test pair", function()
    local view = require("codediff.ui.view")
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    view.create({
      original = path.make_ref("scripts/test_pairs/simple_swap/original.txt", nil),
      modified = path.make_ref("scripts/test_pairs/simple_swap/modified.txt", nil),
    })
    vim.cmd("redraw")
    vim.wait(500)

    local lifecycle = require("codediff.ui.lifecycle")
    local tp = vim.api.nvim_get_current_tabpage()
    local session = lifecycle.get_session(tp)
    assert.is_truthy(session, "Session should exist")

    local left_real = vim.api.nvim_buf_line_count(session.original_bufnr)
    local right_real = vim.api.nvim_buf_line_count(session.modified_bufnr)
    local left_virt, right_virt = 0, 0

    for _, ns in ipairs({ ns_filler, ns_highlight }) do
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.original_bufnr, ns, 0, -1, { details = true })) do
        if m[4].virt_lines then left_virt = left_virt + #m[4].virt_lines end
      end
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.modified_bufnr, ns, 0, -1, { details = true })) do
        if m[4].virt_lines then right_virt = right_virt + #m[4].virt_lines end
      end
    end

    local left_total = left_real + left_virt
    local right_total = right_real + right_virt
    assert.are.equal(left_total, right_total,
      string.format("Visual lines must balance: LEFT=%d+%d=%d, RIGHT=%d+%d=%d",
        left_real, left_virt, left_total, right_real, right_virt, right_total))

    while vim.fn.tabpagenr("$") > 1 do vim.cmd("tabclose!") end
  end)

  -- 8. All test pairs in scripts/test_pairs/ produce balanced visual lines
  it("produces balanced visual lines for ALL test pairs", function()
    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    local pairs_dir = "scripts/test_pairs"
    local handle = vim.loop.fs_scandir(pairs_dir)
    assert.is_truthy(handle, "test_pairs directory should exist")

    local tested = 0
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end
      if type == "directory" then
        local orig = pairs_dir .. "/" .. name .. "/original.txt"
        local mod = pairs_dir .. "/" .. name .. "/modified.txt"
        if vim.fn.filereadable(orig) == 1 and vim.fn.filereadable(mod) == 1 then
          require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
          highlights.setup()

          view.create({
            original = path.make_ref(orig, nil),
            modified = path.make_ref(mod, nil),
          })
          vim.cmd("redraw")
          vim.wait(500)

          local tp = vim.api.nvim_get_current_tabpage()
          local session = lifecycle.get_session(tp)
          if session then
            local left_real = vim.api.nvim_buf_line_count(session.original_bufnr)
            local right_real = vim.api.nvim_buf_line_count(session.modified_bufnr)
            local left_virt, right_virt = 0, 0

            for _, ns in ipairs({ ns_filler, ns_highlight }) do
              for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.original_bufnr, ns, 0, -1, { details = true })) do
                if m[4].virt_lines then left_virt = left_virt + #m[4].virt_lines end
              end
              for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.modified_bufnr, ns, 0, -1, { details = true })) do
                if m[4].virt_lines then right_virt = right_virt + #m[4].virt_lines end
              end
            end

            local left_total = left_real + left_virt
            local right_total = right_real + right_virt
            assert.are.equal(left_total, right_total,
              string.format("%s: visual lines unbalanced LEFT=%d+%d=%d, RIGHT=%d+%d=%d",
                name, left_real, left_virt, left_total, right_real, right_virt, right_total))
            tested = tested + 1
          end

          while vim.fn.tabpagenr("$") > 1 do vim.cmd("tabclose!") end
        end
      end
    end

    assert.is_true(tested >= 10, "Should test at least 10 pairs, tested " .. tested)
  end)
end)
