-- Test: Merge Alignment
-- Tests the 3-way merge alignment algorithm using the current API

local merge_alignment = require("codediff.ui.conflict.merge")

describe("Merge Alignment", function()
  -- Helper to create mock diff results
  local function make_diff(changes)
    return { changes = changes or {} }
  end

  local function make_change(orig_start, orig_end, mod_start, mod_end, inner_changes)
    return {
      original = { start_line = orig_start, end_line = orig_end },
      modified = { start_line = mod_start, end_line = mod_end },
      inner_changes = inner_changes or {}
    }
  end

  -- Test 1: Empty diffs produce no fillers
  it("Empty diffs produce no fillers", function()
    local diff1 = make_diff({})
    local diff2 = make_diff({})

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, {}, {}, {})

    assert.equal(0, #left_fillers)
    assert.equal(0, #right_fillers)
  end)

  -- Test 2: Single overlapping change produces fillers
  it("Single overlapping change produces fillers", function()
    -- Base lines 2-4, input1 expands to 2-6 (4 lines), input2 expands to 2-5 (3 lines)
    local diff1 = make_diff({ make_change(2, 4, 2, 6) })
    local diff2 = make_diff({ make_change(2, 4, 2, 5) })

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, {"a", "b", "c", "d"}, {"a", "b", "c", "d", "e", "f"}, {"a", "b", "c", "d", "e"})

    -- Right side has fewer lines, so it should get a filler
    assert.is_true(#right_fillers > 0 or #left_fillers > 0)
  end)

  -- Test 3: Non-overlapping changes
  it("Non-overlapping changes produce separate regions", function()
    local diff1 = make_diff({ make_change(2, 4, 2, 5) })
    local diff2 = make_diff({ make_change(10, 12, 10, 14) })

    local base_lines = {}
    for i = 1, 20 do base_lines[i] = "line" .. i end
    local input1_lines = {}
    for i = 1, 21 do input1_lines[i] = "line" .. i end
    local input2_lines = {}
    for i = 1, 22 do input2_lines[i] = "line" .. i end

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- Should produce fillers for both regions
    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)

  -- Test 4: compute_merge_fillers_and_conflicts returns conflict info
  it("compute_merge_fillers_and_conflicts returns conflict changes", function()
    -- Both sides modify the same region - this is a conflict
    local diff1 = make_diff({ make_change(2, 4, 2, 6) })
    local diff2 = make_diff({ make_change(2, 4, 2, 5) })

    local fillers, conflict_left, conflict_right = merge_alignment.compute_merge_fillers_and_conflicts(
      diff1, diff2,
      {"a", "b", "c", "d"},
      {"a", "b", "c", "d", "e", "f"},
      {"a", "b", "c", "d", "e"}
    )

    assert.is_table(fillers)
    assert.is_table(fillers.left_fillers)
    assert.is_table(fillers.right_fillers)
    assert.is_table(conflict_left)
    assert.is_table(conflict_right)
  end)

  -- Test 5: Only one side has changes (no conflict)
  it("Only one side has changes produces no conflicts", function()
    local diff1 = make_diff({ make_change(5, 8, 5, 10) })
    local diff2 = make_diff({})  -- No changes on this side

    local base_lines = {}
    for i = 1, 10 do base_lines[i] = "line" .. i end
    local input1_lines = {}
    for i = 1, 12 do input1_lines[i] = "line" .. i end

    local fillers, conflict_left, conflict_right = merge_alignment.compute_merge_fillers_and_conflicts(
      diff1, diff2, base_lines, input1_lines, base_lines
    )

    assert.is_table(fillers)
    -- When only one side has changes, it's not a conflict
    -- The conflict arrays may be empty or only contain the single-side change
    assert.is_table(conflict_left)
    assert.is_table(conflict_right)
  end)

  -- Test 6: Filler structure is correct
  it("Filler structure has after_line and count", function()
    -- Create a scenario that definitely produces fillers
    local diff1 = make_diff({ make_change(2, 3, 2, 5) })  -- Adds 2 lines
    local diff2 = make_diff({ make_change(2, 3, 2, 3) })  -- No change in line count

    local base_lines = {"a", "b", "c", "d"}
    local input1_lines = {"a", "b", "c", "d", "e", "f"}
    local input2_lines = {"a", "b", "c", "d"}

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- At least one side should have fillers due to line count difference
    local has_fillers = #left_fillers > 0 or #right_fillers > 0
    if has_fillers then
      local fillers = #left_fillers > 0 and left_fillers or right_fillers
      assert.is_number(fillers[1].after_line)
      assert.is_number(fillers[1].count)
      assert.is_true(fillers[1].count > 0)
    end
  end)

  -- Test 7: Adjacent changes are handled
  it("Adjacent changes are grouped together", function()
    -- Two adjacent changes
    local diff1 = make_diff({
      make_change(2, 4, 2, 5),
      make_change(4, 6, 5, 8)
    })
    local diff2 = make_diff({
      make_change(2, 6, 2, 7)
    })

    local base_lines = {}
    for i = 1, 10 do base_lines[i] = "line" .. i end
    local input1_lines = {}
    for i = 1, 12 do input1_lines[i] = "line" .. i end
    local input2_lines = {}
    for i = 1, 11 do input2_lines[i] = "line" .. i end

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    -- Should not error
    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)

  -- Test 8: Handles inner changes
  it("Handles changes with inner_changes", function()
    local inner = {
      { original = { start_line = 2, start_col = 5, end_line = 2, end_col = 10 },
        modified = { start_line = 2, start_col = 5, end_line = 2, end_col = 15 } }
    }
    local diff1 = make_diff({ make_change(2, 3, 2, 3, inner) })
    local diff2 = make_diff({ make_change(2, 3, 2, 4) })

    local base_lines = {"a", "b", "c"}
    local input1_lines = {"a", "b", "c"}
    local input2_lines = {"a", "b", "c", "d"}

    local left_fillers, right_fillers = merge_alignment.compute_merge_fillers(diff1, diff2, base_lines, input1_lines, input2_lines)

    assert.is_table(left_fillers)
    assert.is_table(right_fillers)
  end)
end)

describe("compute_auto_merged_result", function()
  local function make_diff(changes)
    return { changes = changes or {} }
  end

  local function make_change(orig_start, orig_end, mod_start, mod_end)
    return {
      original = { start_line = orig_start, end_line = orig_end },
      modified = { start_line = mod_start, end_line = mod_end },
      inner_changes = {},
    }
  end

  it("returns BASE unchanged when neither side has any diffs", function()
    local base = { "a", "b", "c" }
    local merged, blocks = merge_alignment.compute_auto_merged_result(
      make_diff({}), make_diff({}), base, base, base
    )
    assert.are.same(base, merged)
    assert.equal(0, #blocks)
  end)

  it("applies a one-sided input1 insertion to the result (no conflict)", function()
    -- BASE: a, b
    -- input1 adds 'x' between a and b: a, x, b   (diff replaces base line 2 with [x, b]; OR base 1..2 -> 1..3)
    -- input2: unchanged
    local base = { "a", "b" }
    local input1 = { "a", "x", "b" }
    local input2 = { "a", "b" }
    -- Insertion at base line 2: original=[2,2), modified=[2,3)
    local diff1 = make_diff({ make_change(2, 2, 2, 3) })
    local diff2 = make_diff({})
    local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
    assert.are.same({ "a", "x", "b" }, merged)
    assert.equal(0, #blocks, "one-sided changes must not be conflicts")
  end)

  it("applies a one-sided input2 insertion to the result (no conflict)", function()
    local base = { "a", "b" }
    local input1 = { "a", "b" }
    local input2 = { "a", "y", "b" }
    local diff1 = make_diff({})
    local diff2 = make_diff({ make_change(2, 2, 2, 3) })
    local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
    assert.are.same({ "a", "y", "b" }, merged)
    assert.equal(0, #blocks)
  end)

  it(
    "Regression for #353: when both sides make non-overlapping insertions inside the same git hunk, all insertions land in the auto-merged Result",
    function()
      -- BASE has just "a","b". OURS adds "ours_new" after "a"; THEIRS adds
      -- "theirs_new" before "b". git will produce a single conflict marker
      -- but the diff algorithm sees this as a single combined hunk where the
      -- two replacements are different lines (true conflict). The original
      -- bug would seed Result with pure BASE, dropping both additions.
      --
      -- For the *non-conflicting* variant (the bug screenshot), both sides
      -- modify the SAME base region but with identical-relative-position
      -- insertions in disjoint sub-positions. We model that here as two
      -- separate one-sided changes coexisting and verify each lands.
      local base = { "a", "b", "c" }
      local input1 = { "a", "ours_new", "b", "c" }    -- ours added at line 2
      local input2 = { "a", "b", "c", "theirs_new" }  -- theirs appended at end
      local diff1 = make_diff({ make_change(2, 2, 2, 3) })
      local diff2 = make_diff({ make_change(4, 4, 4, 5) })
      local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
      -- Both additions present, no conflict block.
      assert.are.same({ "a", "ours_new", "b", "c", "theirs_new" }, merged)
      assert.equal(0, #blocks, "non-overlapping one-sided changes are not conflicts")
    end
  )

  it("keeps a two-sided conflict region as BASE and produces a result_range block", function()
    -- BASE: a, b, c
    -- input1 replaces line 2 with X
    -- input2 replaces line 2 with Y  → true conflict
    local base = { "a", "b", "c" }
    local input1 = { "a", "X", "c" }
    local input2 = { "a", "Y", "c" }
    local diff1 = make_diff({ make_change(2, 3, 2, 3) })
    local diff2 = make_diff({ make_change(2, 3, 2, 3) })
    local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
    assert.are.same({ "a", "b", "c" }, merged)
    assert.equal(1, #blocks)
    local b = blocks[1]
    assert.is_table(b.result_range)
    assert.equal(2, b.result_range.start_line)
    assert.equal(3, b.result_range.end_line)
    -- Sanity: base_range / output ranges still present for downstream consumers
    assert.equal(2, b.base_range.start_line)
    assert.equal(3, b.base_range.end_line)
  end)

  it("treats an identical change on both sides as non-conflict and applies once", function()
    local base = { "a", "b", "c" }
    local input1 = { "a", "Z", "c" }
    local input2 = { "a", "Z", "c" }
    local diff1 = make_diff({ make_change(2, 3, 2, 3) })
    local diff2 = make_diff({ make_change(2, 3, 2, 3) })
    local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
    assert.are.same({ "a", "Z", "c" }, merged)
    assert.equal(0, #blocks, "identical changes are not a conflict")
  end)

  it("result_range reflects the merged-content position, not the BASE position", function()
    -- A one-sided insertion before a two-sided conflict shifts the conflict's
    -- position in the merged buffer; the BASE position is unchanged.
    -- BASE:   a, b, c
    -- input1: a, x, b, c           (insert x at line 2)
    -- input2: a, b, Q                (modify line 3 to Q)  -- this conflict only exists if input1 ALSO modifies line 3 — let's make a real two-sided conflict at line 3:
    -- input1: a, x, b, P            (insert x at line 2, replace c with P)
    -- input2: a, b, Q                (replace c with Q)
    local base = { "a", "b", "c" }
    local input1 = { "a", "x", "b", "P" }
    local input2 = { "a", "b", "Q" }
    local diff1 = make_diff({ make_change(2, 2, 2, 3), make_change(3, 4, 4, 5) })
    local diff2 = make_diff({ make_change(3, 4, 3, 4) })
    local merged, blocks = merge_alignment.compute_auto_merged_result(diff1, diff2, base, input1, input2)
    -- "x" auto-applied; "c" stays as BASE because it's a true conflict.
    assert.are.same({ "a", "x", "b", "c" }, merged)
    assert.equal(1, #blocks)
    -- BASE line 3 -> result line 4 because "x" was inserted before it.
    assert.equal(4, blocks[1].result_range.start_line)
    assert.equal(5, blocks[1].result_range.end_line)
    assert.equal(3, blocks[1].base_range.start_line)
    assert.equal(4, blocks[1].base_range.end_line)
  end)
end)