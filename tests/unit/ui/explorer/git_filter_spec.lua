-- Test for .git directory filtering in directory comparison mode
local filter = require("codediff.ui.explorer.filter")

describe("Explorer File Filter - .git filtering", function()
  it("filters .git/config file", function()
    local patterns = { ".git/**" }
    assert.is_true(filter.matches_any_pattern(".git/config", patterns))
  end)

  it("filters .git/HEAD file", function()
    local patterns = { ".git/**" }
    assert.is_true(filter.matches_any_pattern(".git/HEAD", patterns))
  end)

  it("filters nested .git files", function()
    local patterns = { ".git/**" }
    assert.is_true(filter.matches_any_pattern(".git/objects/abc123", patterns))
  end)

  it("does not filter regular files", function()
    local patterns = { ".git/**" }
    assert.is_false(filter.matches_any_pattern("src/main.lua", patterns))
  end)

  it("does not filter files with .git in name but not in directory", function()
    local patterns = { ".git/**" }
    assert.is_false(filter.matches_any_pattern("src/.gitignore", patterns))
  end)

  it("does not filter files in nested .git directories (only root .git)", function()
    -- Pattern .git/** only matches .git at the start of path
    -- Nested .git directories like subproject/.git/config are intentionally not filtered
    local patterns = { ".git/**" }
    assert.is_false(filter.matches_any_pattern("subproject/.git/config", patterns))
  end)

  it("apply function filters out .git files", function()
    local files = {
      { path = "src/main.lua", status = "M" },
      { path = ".git/config", status = "M" },
      { path = ".git/HEAD", status = "M" },
      { path = ".git/objects/abc", status = "M" },
      { path = "README.md", status = "A" },
    }
    local patterns = { ".git/**" }
    local filtered = filter.apply(files, patterns)
    
    assert.equals(2, #filtered)
    assert.equals("src/main.lua", filtered[1].path)
    assert.equals("README.md", filtered[2].path)
  end)
end)
