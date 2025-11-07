-- Test: FFI Integration
-- Validates C <-> Lua boundary and data structure conversion

local diff = require("vscode-diff.diff")

describe("FFI Integration", function()
  -- Test 1: Basic FFI call works
  it("FFI can call compute_diff", function()
    local result = diff.compute_diff({"a"}, {"b"})
    assert.is_not_nil(result, "Result should not be nil")
  end)

  -- Test 2: Return structure format
  it("Returns correct structure format", function()
    local result = diff.compute_diff({"a"}, {"b"})
    assert.equal("table", type(result), "Result should be a table")
    assert.equal("table", type(result.changes), "Should have changes array")
    assert.equal("table", type(result.moves), "Should have moves array")
    assert.equal("boolean", type(result.hit_timeout), "Should have hit_timeout flag")
  end)

  -- Test 3: Changes array structure
  it("Changes have correct nested structure", function()
    local result = diff.compute_diff({"a", "b"}, {"a", "c"})
    assert.is_true(#result.changes > 0, "Should have at least one change")
    
    local mapping = result.changes[1]
    assert.equal("table", type(mapping), "Mapping should be a table")
    assert.is_not_nil(mapping.original, "Should have original range")
    assert.is_not_nil(mapping.modified, "Should have modified range")
    assert.equal("table", type(mapping.inner_changes), "Should have inner_changes array")
  end)

  -- Test 4: LineRange structure
  it("LineRange has correct fields", function()
    local result = diff.compute_diff({"a"}, {"b"})
    local mapping = result.changes[1]
    
    assert.equal("number", type(mapping.original.start_line), "start_line should be number")
    assert.equal("number", type(mapping.original.end_line), "end_line should be number")
    assert.is_true(mapping.original.start_line >= 1, "start_line should be 1-based")
    assert.is_true(mapping.original.end_line >= mapping.original.start_line, "end >= start")
  end)

  -- Test 5: CharRange structure in inner changes
  it("CharRange has correct fields", function()
    local result = diff.compute_diff({"hello"}, {"world"})
    if #result.changes > 0 and #result.changes[1].inner_changes > 0 then
      local inner = result.changes[1].inner_changes[1]
      
      assert.equal("table", type(inner.original), "Should have original CharRange")
      assert.equal("table", type(inner.modified), "Should have modified CharRange")
      assert.equal("number", type(inner.original.start_line))
      assert.equal("number", type(inner.original.start_col))
      assert.equal("number", type(inner.original.end_line))
      assert.equal("number", type(inner.original.end_col))
      assert.is_true(inner.original.start_col >= 1, "Column should be 1-based")
    end
  end)

  -- Test 6: Empty input handling
  it("Handles empty arrays", function()
    local result = diff.compute_diff({}, {})
    assert.is_not_nil(result, "Should handle empty input")
    assert.equal("table", type(result.changes))
    assert.equal(0, #result.changes, "Should have no changes for identical empty inputs")
  end)

  -- Test 7: Same content (no changes)
  it("Handles identical content", function()
    local result = diff.compute_diff({"a", "b", "c"}, {"a", "b", "c"})
    assert.is_not_nil(result)
    assert.equal(0, #result.changes, "Should have no changes for identical content")
  end)

  -- Test 8: Large diff doesn't crash
  it("Handles large diffs", function()
    local large_a = {}
    local large_b = {}
    for i = 1, 100 do
      table.insert(large_a, "line " .. i)
      table.insert(large_b, "modified " .. i)
    end
    
    local result = diff.compute_diff(large_a, large_b)
    assert.is_not_nil(result, "Should handle large diffs")
    assert.is_true(#result.changes > 0, "Should detect changes in large diff")
  end)

  -- Test 9: Memory is freed (basic check - no crash on multiple calls)
  it("Multiple calls don't leak memory", function()
    for i = 1, 10 do
      local result = diff.compute_diff(
        {"line1", "line2", "line3"},
        {"line1", "modified", "line3"}
      )
      assert.is_not_nil(result, "Call " .. i .. " should succeed")
    end
  end)

  -- Test 10: Version string exists
  it("Can get version string", function()
    local version = diff.get_version()
    assert.equal("string", type(version), "Version should be a string")
    assert.is_true(#version > 0, "Version should not be empty")
    -- Note: original had print statement, keeping as comment for parity
    -- print("    (Version: " .. version .. ")")
  end)
end)
