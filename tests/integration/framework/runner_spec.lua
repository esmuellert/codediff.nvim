local repositories = require("tests.support.repository")

describe("runner fixture cleanup", function()
  local repo

  before_each(function()
    repo = repositories.new()
  end)

  after_each(function()
    if repo then
      repo.cleanup()
    end
  end)

  for _, cleanup_error in ipairs({ false, true }) do
    it(cleanup_error and "reports cleanup failures even when fixture setup skips a case" or "skips unavailable fixture backends and still runs cleanup", function()
      local script = repo.write_file("pending_fixture.lua", {
        "local repo",
        "describe('unavailable backend', function()",
        "  before_each(function()",
        "    repo = require('tests.support.repository').new({ unborn = true })",
        "    pending('backend unavailable')",
        "  end)",
        "  after_each(function()",
        "    repo.cleanup()",
        cleanup_error and "    error('expected cleanup failure')" or "    assert(vim.fn.isdirectory(repo.root) == 0)",
        "  end)",
        "  it('does not run the body', function() error('body must not run') end)",
        "end)",
      })
      local result = vim
        .system({
          vim.v.progpath,
          "--headless",
          "--noplugin",
          "-u",
          "tests/init.lua",
          "-c",
          "lua require('tests.framework').run_and_exit(" .. string.format("%q", script) .. ")",
        }, { text = true, timeout = 30000 })
        :wait()
      assert.equals(cleanup_error and 1 or 0, result.code, (result.stdout or "") .. (result.stderr or ""))
    end)
  end
end)
