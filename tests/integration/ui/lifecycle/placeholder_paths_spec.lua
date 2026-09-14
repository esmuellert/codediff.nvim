-- A placeholder session stored its paths as the empty string while every other
-- session stored Path tables. Readers reach for .absolute, and Lua lets you
-- index a string, so those reads answered nil instead of failing. Both are
-- path.empty() now; this pins that.

local h = require("tests.support")

describe("placeholder session paths", function()
  local repo, captured, restore

  before_each(function()
    h.ensure_plugin_loaded()

    -- Catch the session as it is built; the explorer selects a file straight
    -- away and replaces the placeholder, so it cannot be read afterwards.
    local lifecycle = require("codediff.ui.lifecycle")
    local original = lifecycle.create_session
    captured = {}
    lifecycle.create_session = function(tabpage, session_config, panes)
      captured[#captured + 1] = { original = session_config.original, modified = session_config.modified }
      return original(tabpage, session_config, panes)
    end
    restore = function()
      lifecycle.create_session = original
    end

    repo = h.create_temp_git_repo()
    repo.write_file("a.txt", { "a1" })
    repo.git("add -A")
    repo.git("commit -qm init")
    repo.write_file("a.txt", { "A1 CHANGED" })
  end)

  after_each(function()
    if restore then
      restore()
    end
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  local function assert_is_path(value, label)
    assert.equals("table", type(value), label .. " must be a Path, not a " .. type(value))
    assert.equals("string", type(value.absolute), label .. ".absolute must be a string")
    assert.equals("string", type(value.relative), label .. ".relative must be a string")
  end

  it("carries empty Paths, not empty strings", function()
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("CodeDiff")
    assert.is_true(
      vim.wait(15000, function()
        return h.find_window_by_filetype("codediff-explorer") ~= nil
      end, 50),
      "explorer never opened"
    )
    vim.wait(1000)

    assert.is_true(#captured > 0, "no session was created")

    local placeholder = captured[1]
    assert_is_path(placeholder.original, "placeholder original")
    assert_is_path(placeholder.modified, "placeholder modified")

    local path = require("codediff.core.path")
    assert.is_true(path.is_empty(placeholder.original), "placeholder original should be an empty Path")
    assert.is_true(path.is_empty(placeholder.modified), "placeholder modified should be an empty Path")
  end)
end)
