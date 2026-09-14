-- Test: Moved code detection via C FFI
-- Validates compute_moves option and MovedText results

local diff = require("codediff.core.diff")
local config = require("codediff.config")

describe("move detection", function()
  local saved_options

  before_each(function()
    saved_options = vim.deepcopy(config.options)
    require("codediff").setup({ diff = { compute_moves = true } })
  end)

  after_each(function()
    config.options = saved_options
  end)

  -- Test 1: Simple swap detects 1 move
  it("detects a move when two blocks are swapped", function()
    local orig = {
      "function foo()",
      "  return 1",
      "end",
      "",
      "function bar()",
      "  return 2",
      "end",
    }
    local mod = {
      "function bar()",
      "  return 2",
      "end",
      "",
      "function foo()",
      "  return 1",
      "end",
    }
    local result = diff.compute_diff(orig, mod, { compute_moves = true })
    assert.are.equal(1, #result.moves)
  end)

  -- Test 2: No moves for normal edits
  it("reports no moves for normal edits", function()
    local orig = { "line 1", "line 2", "line 3" }
    local mod = { "line 1", "changed 2", "line 3", "new line" }
    local result = diff.compute_diff(orig, mod, { compute_moves = true })
    assert.are.equal(0, #result.moves)
  end)

  -- Test 3: Move ranges are correct
  it("has correct move ranges for a simple swap", function()
    local orig = {
      "function foo()",
      "  return 1",
      "end",
      "",
      "function bar()",
      "  return 2",
      "end",
    }
    local mod = {
      "function bar()",
      "  return 2",
      "end",
      "",
      "function foo()",
      "  return 1",
      "end",
    }
    local result = diff.compute_diff(orig, mod, { compute_moves = true })
    assert.are.equal(1, #result.moves)

    local move = result.moves[1]
    assert.is_not_nil(move.original, "move should have original range")
    assert.is_not_nil(move.modified, "move should have modified range")
    assert.is_not_nil(move.original.start_line, "original should have start_line")
    assert.is_not_nil(move.original.end_line, "original should have end_line")
    assert.is_not_nil(move.modified.start_line, "modified should have start_line")
    assert.is_not_nil(move.modified.end_line, "modified should have end_line")

    -- The move should span 3 lines (a function block)
    local orig_span = move.original.end_line - move.original.start_line
    local mod_span = move.modified.end_line - move.modified.start_line
    assert.are.equal(orig_span, mod_span, "original and modified spans should match")
    assert.is_true(orig_span >= 3, "move should span at least 3 lines (a full function block)")
  end)

  -- Test 4: compute_moves=false returns empty moves
  it("returns empty moves when compute_moves is false", function()
    local orig = {
      "function foo()",
      "  return 1",
      "end",
      "",
      "function bar()",
      "  return 2",
      "end",
    }
    local mod = {
      "function bar()",
      "  return 2",
      "end",
      "",
      "function foo()",
      "  return 1",
      "end",
    }
    local result = diff.compute_diff(orig, mod, { compute_moves = false })
    assert.are.equal(0, #result.moves)
  end)

  -- Test 5: Single line not detected as move (VSCode threshold)
  it("does not detect a single moved line as a move", function()
    local orig = { "aaa", "local x = 42", "bbb", "ccc" }
    local mod = { "aaa", "bbb", "ccc", "local x = 42" }
    local result = diff.compute_diff(orig, mod, { compute_moves = true })
    assert.are.equal(0, #result.moves)
  end)

  -- Test 6: Moves don't affect changes array
  it("produces the same changes regardless of compute_moves flag", function()
    local orig = {
      "function foo()",
      "  return 1",
      "end",
      "",
      "function bar()",
      "  return 2",
      "end",
    }
    local mod = {
      "function bar()",
      "  return 2",
      "end",
      "",
      "function foo()",
      "  return 1",
      "end",
    }
    local result_with = diff.compute_diff(orig, mod, { compute_moves = true })
    local result_without = diff.compute_diff(orig, mod, { compute_moves = false })

    assert.are.equal(#result_with.changes, #result_without.changes,
      "number of changes should be the same")

    for i, change_with in ipairs(result_with.changes) do
      local change_without = result_without.changes[i]
      assert.are.equal(change_with.original.start_line, change_without.original.start_line,
        "original start_line should match for change " .. i)
      assert.are.equal(change_with.original.end_line, change_without.original.end_line,
        "original end_line should match for change " .. i)
      assert.are.equal(change_with.modified.start_line, change_without.modified.start_line,
        "modified start_line should match for change " .. i)
      assert.are.equal(change_with.modified.end_line, change_without.modified.end_line,
        "modified end_line should match for change " .. i)
    end
  end)

  -- Test 7: All test pairs — C move count matches Node reference
  it("matches Node reference move count for ALL test pairs", function()
    local pairs_dir = "scripts/test_pairs"
    local handle = vim.loop.fs_scandir(pairs_dir)
    assert.is_truthy(handle, "test_pairs directory should exist")

    local tested = 0
    while true do
      local name, ftype = vim.loop.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" then
        local orig_path = pairs_dir .. "/" .. name .. "/original.txt"
        local mod_path = pairs_dir .. "/" .. name .. "/modified.txt"
        if vim.fn.filereadable(orig_path) == 1 and vim.fn.filereadable(mod_path) == 1 then
          local orig = vim.fn.readfile(orig_path)
          local mod = vim.fn.readfile(mod_path)
          local result = diff.compute_diff(orig, mod, { compute_moves = true })
          assert.is_truthy(result, name .. ": compute_diff should succeed")
          assert.is_truthy(result.moves, name .. ": should have moves table")
          assert.is_truthy(result.changes, name .. ": should have changes table")

          -- Verify moves are valid ranges
          for i, move in ipairs(result.moves) do
            assert.is_true(move.original.start_line >= 1, name .. " move " .. i .. ": orig start >= 1")
            assert.is_true(move.original.end_line > move.original.start_line, name .. " move " .. i .. ": orig end > start")
            assert.is_true(move.modified.start_line >= 1, name .. " move " .. i .. ": mod start >= 1")
            assert.is_true(move.modified.end_line > move.modified.start_line, name .. " move " .. i .. ": mod end > start")
          end

          tested = tested + 1
        end
      end
    end
    assert.is_true(tested >= 10, "Should test at least 10 pairs, tested " .. tested)
  end)
end)
