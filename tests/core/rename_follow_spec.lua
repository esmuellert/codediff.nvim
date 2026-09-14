-- Test: resolve_path_at_revision follows renames and copies
-- Validates that git.resolve_path_at_revision correctly detects old file paths

local git = require("codediff.core.git")

local function create_rename_repo()
  local repo = require("tests.framework.repository").new({ unborn = true })
  local function run(...)
    return repo.command({ ... })
  end
  return repo.dir, run, repo.cleanup
end

describe("resolve_path_at_revision", function()
  it("Returns old path for a renamed file", function()
    local dir, run, cleanup = create_rename_repo()

    vim.fn.writefile({ "content" }, dir .. "/old.lua")
    run("add", ".")
    run("commit", "-m", "initial")
    local initial = vim.trim(run("rev-parse", "HEAD"))

    run("mv", "old.lua", "new.lua")
    run("commit", "-m", "rename")

    local done = false
    local resolved = nil

    git.resolve_path_at_revision(initial, dir, "new.lua", function(err, path)
      assert.is_nil(err)
      resolved = path
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done, "Callback should complete")
    assert.equal("old.lua", resolved, "Should resolve to old path before rename")

    cleanup()
  end)

  it("Returns same path for a file without renames", function()
    local dir, run, cleanup = create_rename_repo()

    vim.fn.writefile({ "content" }, dir .. "/stable.lua")
    run("add", ".")
    run("commit", "-m", "initial")
    local initial = vim.trim(run("rev-parse", "HEAD"))

    vim.fn.writefile({ "modified" }, dir .. "/stable.lua")
    run("add", ".")
    run("commit", "-m", "modify")

    local done = false
    local resolved = nil

    git.resolve_path_at_revision(initial, dir, "stable.lua", function(err, path)
      assert.is_nil(err)
      resolved = path
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done, "Callback should complete")
    assert.equal("stable.lua", resolved, "Should return same path when no rename")

    cleanup()
  end)

end)
