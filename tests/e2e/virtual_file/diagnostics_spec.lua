-- Public command coverage of diagnostic isolation, independent of source history.
local h = require("tests.support.e2e")

describe("Virtual buffer diagnostics integration", function()
  local repo, screen

  before_each(function()
    repo = h.repo()
    repo.write_file("sample.lua", { "local value = 'working'", "return value" })
    screen = h.screen("polling", "side-by-side")
  end)

  after_each(function()
    h.close(screen, repo)
    screen, repo = nil, nil
  end)

  it("Disables diagnostics on virtual buffers in real CodeDiff usage", function()
    h.open(screen, repo, "CodeDiff file HEAD", "sample.lua", "sample.lua")
    h.expect_text(screen, "original", "local value = 'base'")
    h.expect_text(screen, "modified", "local value = 'working'")
    local state = screen:exec([[
      local session = refresh_session()
      return {
        virtual = vim.api.nvim_buf_get_name(session.original_bufnr):match('^codediff://') ~= nil,
        original = vim.diagnostic.is_enabled({ bufnr = session.original_bufnr }),
        modified = vim.diagnostic.is_enabled({ bufnr = session.modified_bufnr }),
      }
    ]])
    assert.is_true(state.virtual, "original pane must be a real revision buffer")
    assert.is_false(state.original, "revision buffers must suppress diagnostics")
    assert.is_true(state.modified, "the working buffer must retain diagnostics")
  end)
end)
