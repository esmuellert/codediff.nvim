-- Test: History File Filter Integration
-- Validates that explorer.file_filter.ignore patterns apply to history file listings

local filter = require("codediff.ui.explorer.filter")

describe("History File Filter", function()
  describe("filter.apply with history-style file entries", function()
    it("filters files matching ignore patterns", function()
      local files = {
        { path = "src/main.lua", status = "M" },
        { path = ".git/objects/abc123", status = "A" },
        { path = ".jj/store/commit", status = "A" },
        { path = "README.md", status = "M" },
      }

      local result = filter.apply(files, { ".git/**", ".jj/**" })

      assert.equals(2, #result)
      assert.equals("src/main.lua", result[1].path)
      assert.equals("README.md", result[2].path)
    end)

    it("preserves all fields including old_path", function()
      local files = {
        { path = "new_name.lua", status = "R", old_path = "old_name.lua" },
        { path = "dist/bundle.js", status = "A" },
      }

      local result = filter.apply(files, { "dist/**" })

      assert.equals(1, #result)
      assert.equals("new_name.lua", result[1].path)
      assert.equals("R", result[1].status)
      assert.equals("old_name.lua", result[1].old_path)
    end)

    it("returns all files when no ignore patterns", function()
      local files = {
        { path = "a.lua", status = "M" },
        { path = "b.lua", status = "A" },
      }

      assert.equals(2, #filter.apply(files, {}))
      assert.equals(2, #filter.apply(files, nil))
    end)

    it("returns empty list when all files are filtered", function()
      local files = {
        { path = "dist/a.js", status = "A" },
        { path = "dist/b.js", status = "A" },
      }

      local result = filter.apply(files, { "dist/**" })

      assert.equals(0, #result)
    end)
  end)
end)
