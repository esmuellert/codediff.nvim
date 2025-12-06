-- Test: Merge Alignment
-- Tests the 3-way merge alignment algorithm

local merge_alignment = require("vscode-diff.render.merge_alignment")

describe("Merge Alignment", function()
  -- Test 1: LineRange basic operations
  it("LineRange basic operations", function()
    local r1 = merge_alignment.LineRange.new(1, 5)
    assert.equal(4, r1:length())
    assert.is_false(r1:is_empty())

    local r2 = merge_alignment.LineRange.new(3, 3)
    assert.equal(0, r2:length())
    assert.is_true(r2:is_empty())
  end)

  -- Test 2: LineRange intersects_or_touches
  it("LineRange intersects_or_touches", function()
    local r1 = merge_alignment.LineRange.new(1, 5)
    local r2 = merge_alignment.LineRange.new(3, 7)
    local r3 = merge_alignment.LineRange.new(5, 8)  -- Touches r1
    local r4 = merge_alignment.LineRange.new(6, 10)  -- No touch

    assert.is_true(r1:intersects_or_touches(r2))
    assert.is_true(r1:intersects_or_touches(r3))
    assert.is_false(r1:intersects_or_touches(r4))
  end)

  -- Test 3: LineRange join
  it("LineRange join", function()
    local r1 = merge_alignment.LineRange.new(1, 5)
    local r2 = merge_alignment.LineRange.new(3, 7)
    local joined = r1:join(r2)

    assert.equal(1, joined.start_line)
    assert.equal(7, joined.end_line)
  end)

  -- Test 4: LineRangeMapping basic operations
  it("LineRangeMapping basic operations", function()
    local input = merge_alignment.LineRange.new(1, 3)
    local output = merge_alignment.LineRange.new(1, 5)
    local mapping = merge_alignment.LineRangeMapping.new(input, output)

    assert.equal(2, mapping:resulting_delta())
  end)

  -- Test 5: compute_alignments with single overlapping change
  it("compute_alignments with single overlapping change", function()
    local mappings1 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 6)
      )
    }
    local mappings2 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 5)
      )
    }

    local alignments = merge_alignment.compute_alignments(mappings1, mappings2)

    assert.equal(1, #alignments)
    assert.equal(2, alignments[1].input_range.start_line)
    assert.equal(4, alignments[1].input_range.end_line)
    assert.equal(4, alignments[1].output1_range:length())  -- 2 to 6
    assert.equal(3, alignments[1].output2_range:length())  -- 2 to 5
  end)

  -- Test 6: compute_alignments with non-overlapping changes
  it("compute_alignments with non-overlapping changes", function()
    local mappings1 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 5)
      )
    }
    local mappings2 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(10, 12),
        merge_alignment.LineRange.new(11, 14)
      )
    }

    local alignments = merge_alignment.compute_alignments(mappings1, mappings2)

    assert.equal(2, #alignments)
  end)

  -- Test 7: calculate_merge_fillers
  it("calculate_merge_fillers", function()
    local mappings1 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 6)  -- 4 lines
      )
    }
    local mappings2 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 5)  -- 3 lines
      )
    }

    local alignments = merge_alignment.compute_alignments(mappings1, mappings2)
    local fillers = merge_alignment.calculate_merge_fillers(alignments)

    assert.equal(1, #fillers)
    assert.equal("right", fillers[1].buffer)  -- Right has fewer lines
    assert.equal(1, fillers[1].count)
  end)

  -- Test 8: compute_merge_alignments from diff format
  it("compute_merge_alignments from diff format", function()
    local base_to_input1_diff = {
      changes = {
        { original = { start_line = 2, end_line = 4 }, modified = { start_line = 2, end_line = 6 } },
      }
    }
    local base_to_input2_diff = {
      changes = {
        { original = { start_line = 2, end_line = 4 }, modified = { start_line = 2, end_line = 5 } },
      }
    }

    local alignments = merge_alignment.compute_merge_alignments(base_to_input1_diff, base_to_input2_diff)

    assert.equal(1, #alignments)
    assert.equal(2, alignments[1].input_range.start_line)
  end)

  -- Test 9: Empty diffs produce no alignments
  it("Empty diffs produce no alignments", function()
    local alignments = merge_alignment.compute_alignments({}, {})
    assert.equal(0, #alignments)
  end)

  -- Test 10: Only one side has changes
  it("Only one side has changes", function()
    local mappings1 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(5, 8),
        merge_alignment.LineRange.new(5, 10)
      )
    }
    local mappings2 = {}

    local alignments = merge_alignment.compute_alignments(mappings1, mappings2)

    assert.equal(1, #alignments)
    -- Output1 should have the change, output2 should be identity
    assert.equal(5, alignments[1].output1_range:length())  -- 5 to 10
    assert.equal(3, alignments[1].output2_range:length())  -- identity: same as input 5 to 8
  end)

  -- Test 11: Adjacent changes should merge
  it("Adjacent changes should merge into single alignment", function()
    local mappings1 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(2, 4),
        merge_alignment.LineRange.new(2, 5)
      )
    }
    local mappings2 = {
      merge_alignment.LineRangeMapping.new(
        merge_alignment.LineRange.new(4, 6),  -- Touches mappings1's input range
        merge_alignment.LineRange.new(5, 8)
      )
    }

    local alignments = merge_alignment.compute_alignments(mappings1, mappings2)

    -- Should merge into one alignment because input ranges touch
    assert.equal(1, #alignments)
    assert.equal(2, alignments[1].input_range.start_line)
    assert.equal(6, alignments[1].input_range.end_line)
  end)
end)
