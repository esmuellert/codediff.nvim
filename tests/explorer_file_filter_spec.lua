-- Test: Explorer File Filter
-- Validates glob pattern matching for file filtering in explorer

local filter = require("vscode-diff.render.explorer.filter")

-- Use filter module functions
local glob_to_pattern = filter.glob_to_pattern
local matches_any_pattern = filter.matches_any_pattern

describe("Explorer File Filter", function()
  describe("glob_to_pattern", function()
    it("escapes Lua magic characters", function()
      local pattern = glob_to_pattern("file.txt")
      assert.is_true(pattern:find("%.txt") ~= nil, "Should escape dots")
    end)

    it("converts single star to match non-slash characters", function()
      local pattern = glob_to_pattern("*.txt")
      assert.equals("^[^/]*%.txt$", pattern)
    end)

    it("converts double star to match any characters", function()
      local pattern = glob_to_pattern("**")
      assert.equals("^.*$", pattern)
    end)

    it("converts question mark to match single character", function()
      local pattern = glob_to_pattern("fo?.txt")
      assert.equals("^fo.%.txt$", pattern)
    end)

    it("handles double star with slash for directory matching", function()
      local pattern = glob_to_pattern("**/foo")
      assert.equals("^.-foo$", pattern)
    end)
  end)

  describe("matches_any_pattern - basename matching (no slash)", function()
    it("matches file in root directory", function()
      assert.is_true(matches_any_pattern("foo.pb.go", {"*.pb.go"}))
    end)

    it("matches file in nested directory", function()
      assert.is_true(matches_any_pattern("internal/foo/bar.pb.go", {"*.pb.go"}))
    end)

    it("does not match different extension", function()
      assert.is_false(matches_any_pattern("foo.go", {"*.pb.go"}))
    end)

    it("matches with multiple patterns", function()
      assert.is_true(matches_any_pattern("package-lock.json", {"*.lock", "package-lock.json"}))
    end)
  end)

  describe("matches_any_pattern - root anchor (leading slash)", function()
    it("matches file in root with leading slash", function()
      assert.is_true(matches_any_pattern("foo.pb.go", {"/*.pb.go"}))
    end)

    it("does not match nested file with leading slash", function()
      assert.is_false(matches_any_pattern("internal/foo.pb.go", {"/*.pb.go"}))
    end)

    it("matches exact root file", function()
      assert.is_true(matches_any_pattern("README.md", {"/README.md"}))
    end)

    it("does not match same filename in subdirectory", function()
      assert.is_false(matches_any_pattern("docs/README.md", {"/README.md"}))
    end)
  end)

  describe("matches_any_pattern - directory patterns (contains slash)", function()
    it("matches file in specific directory", function()
      assert.is_true(matches_any_pattern("foo/bar.pb.go", {"foo/*.pb.go"}))
    end)

    it("does not match file in different directory", function()
      assert.is_false(matches_any_pattern("other/bar.pb.go", {"foo/*.pb.go"}))
    end)

    it("does not match file in nested subdirectory with single star", function()
      assert.is_false(matches_any_pattern("foo/sub/bar.pb.go", {"foo/*.pb.go"}))
    end)

    it("matches nested path exactly", function()
      assert.is_true(matches_any_pattern("src/components/Button.tsx", {"src/components/*.tsx"}))
    end)
  end)

  describe("matches_any_pattern - double star patterns", function()
    it("matches file in root with **/ prefix", function()
      assert.is_true(matches_any_pattern("foo.pb.go", {"**/*.pb.go"}))
    end)

    it("matches deeply nested file with **/ prefix", function()
      assert.is_true(matches_any_pattern("a/b/c/foo.pb.go", {"**/*.pb.go"}))
    end)

    it("matches file directly in specified directory", function()
      assert.is_true(matches_any_pattern("foo/bar.pb.go", {"foo/**/*.pb.go"}))
    end)

    it("matches deeply nested file under directory", function()
      assert.is_true(matches_any_pattern("foo/a/b/bar.pb.go", {"foo/**/*.pb.go"}))
    end)

    it("does not match file in different directory tree", function()
      assert.is_false(matches_any_pattern("other/bar.pb.go", {"foo/**/*.pb.go"}))
    end)

    it("matches everything with double star only", function()
      assert.is_true(matches_any_pattern("any/path/file.txt", {"**"}))
    end)

    it("matches trailing double star", function()
      assert.is_true(matches_any_pattern("foo/bar/baz.txt", {"foo/**"}))
    end)
  end)

  describe("matches_any_pattern - question mark wildcard", function()
    it("matches single character", function()
      assert.is_true(matches_any_pattern("foo.txt", {"fo?.txt"}))
    end)

    it("does not match multiple characters", function()
      assert.is_false(matches_any_pattern("fooo.txt", {"fo?.txt"}))
    end)

    it("does not match zero characters", function()
      assert.is_false(matches_any_pattern("fo.txt", {"fo?.txt"}))
    end)
  end)

  describe("matches_any_pattern - edge cases", function()
    it("returns false for empty patterns", function()
      assert.is_false(matches_any_pattern("file.txt", {}))
    end)

    it("returns false for nil patterns", function()
      assert.is_false(matches_any_pattern("file.txt", nil))
    end)

    it("handles files with multiple dots", function()
      assert.is_true(matches_any_pattern("file.test.spec.js", {"*.spec.js"}))
    end)

    it("handles patterns with multiple wildcards", function()
      assert.is_true(matches_any_pattern("test_file_spec.lua", {"test_*_spec.lua"}))
    end)
  end)

  describe("matches_any_pattern - real world examples", function()
    it("filters Go generated files", function()
      local patterns = {"*.pb.go", "*.gen.go"}
      assert.is_true(matches_any_pattern("api/v1/service.pb.go", patterns))
      assert.is_true(matches_any_pattern("internal/models/user.gen.go", patterns))
      assert.is_false(matches_any_pattern("main.go", patterns))
    end)

    it("filters lock files", function()
      local patterns = {"*.lock", "package-lock.json", "yarn.lock"}
      assert.is_true(matches_any_pattern("Cargo.lock", patterns))
      assert.is_true(matches_any_pattern("package-lock.json", patterns))
      assert.is_true(matches_any_pattern("yarn.lock", patterns))
      assert.is_false(matches_any_pattern("package.json", patterns))
    end)

    it("filters build output directories", function()
      local patterns = {"dist/**", "build/**", "node_modules/**"}
      assert.is_true(matches_any_pattern("dist/bundle.js", patterns))
      assert.is_true(matches_any_pattern("build/output/main.js", patterns))
      assert.is_true(matches_any_pattern("node_modules/lodash/index.js", patterns))
      assert.is_false(matches_any_pattern("src/index.js", patterns))
    end)

    it("filters minified files", function()
      local patterns = {"*.min.js", "*.min.css"}
      assert.is_true(matches_any_pattern("app.min.js", patterns))
      assert.is_true(matches_any_pattern("assets/styles.min.css", patterns))
      assert.is_false(matches_any_pattern("app.js", patterns))
    end)
  end)
end)
