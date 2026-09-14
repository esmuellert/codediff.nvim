-- Test: ignore_trim_whitespace option
-- Validates that the ignore_trim_whitespace DiffOption works correctly via FFI

local diff = require('codediff.core.diff')

describe("ignore_trim_whitespace", function()
  it("detects whitespace-only changes when disabled", function()
    local result = diff.compute_diff(
      {"  hello", "world"},
      {"    hello", "world"},
      { ignore_trim_whitespace = false }
    )
    assert.is_true(#result.changes > 0, "Should detect leading whitespace change")
  end)

  it("ignores leading whitespace changes when enabled", function()
    local result = diff.compute_diff(
      {"  hello", "world"},
      {"    hello", "world"},
      { ignore_trim_whitespace = true }
    )
    assert.equal(0, #result.changes, "Should ignore leading whitespace difference")
  end)

  it("ignores trailing whitespace changes when enabled", function()
    local result = diff.compute_diff(
      {"hello  ", "world"},
      {"hello    ", "world"},
      { ignore_trim_whitespace = true }
    )
    assert.equal(0, #result.changes, "Should ignore trailing whitespace difference")
  end)

  it("still detects content changes when whitespace is ignored", function()
    local result = diff.compute_diff(
      {"  hello", "world"},
      {"  goodbye", "world"},
      { ignore_trim_whitespace = true }
    )
    assert.is_true(#result.changes > 0, "Should still detect non-whitespace changes")
  end)

  it("ignores indentation-only changes across multiple lines", function()
    local result = diff.compute_diff(
      {"function foo()", "  return 1", "end"},
      {"function foo()", "    return 1", "end"},
      { ignore_trim_whitespace = true }
    )
    assert.equal(0, #result.changes, "Should ignore indentation-only differences")
  end)

  it("defaults to false when not specified", function()
    local with_default = diff.compute_diff(
      {"  hello"},
      {"    hello"}
    )
    local with_false = diff.compute_diff(
      {"  hello"},
      {"    hello"},
      { ignore_trim_whitespace = false }
    )
    assert.equal(#with_default.changes, #with_false.changes,
      "Default behavior should match ignore_trim_whitespace=false")
  end)
end)
