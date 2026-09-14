local snapshot = require("codediff.ui.refresh.inputs")

describe("refresh input snapshots", function()
  local git, original_get_content, session, buffers, callbacks

  before_each(function()
    git = require("codediff.core.git")
    original_get_content = git.get_file_content
    callbacks, buffers = {}, {}
    for i = 1, 2 do
      buffers[i] = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buffers[i], 0, -1, false, { "old " .. i })
    end
    session = {
      git_root = "/repo",
      original_bufnr = buffers[1],
      modified_bufnr = buffers[2],
      original_revision = ":2",
      modified_revision = ":3",
      original = { absolute = "/repo/file.txt", relative = "file.txt" },
      modified = { absolute = "/repo/file.txt", relative = "file.txt" },
    }
    git.get_file_content = function(revision, _, _, done)
      callbacks[revision] = done
    end
  end)

  after_each(function()
    git.get_file_content = original_get_content
    for _, buf in ipairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("reads source definitions from the session without inspecting a panel", function()
    session.source_revisions = { original = "review/topic", modified = ":0" }
    session.panel = setmetatable({}, {
      __index = function()
        error("input reading must not inspect panel state")
      end,
    })
    local sources = snapshot.describe(session)
    assert.equals("review/topic", sources.original.revision)
    assert.equals(":0", sources.modified.revision)
    assert.equals(":2", sources.original.resolved)
    assert.same(session.original, sources.original.path)
  end)

  it("settles all candidates before returning and does not mutate displayed buffers", function()
    local result
    snapshot.read(session, { index = true }, snapshot.capture(session), function(err, data)
      assert.is_nil(err)
      result = data
    end)
    callbacks[":2"](nil, { "new original" })
    vim.wait(20)
    assert.is_nil(result)
    assert.same({ "old 1" }, vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false))
    callbacks[":3"](nil, { "new modified" })
    assert.is_true(vim.wait(1000, function()
      return result ~= nil
    end, 10))
    assert.same({ "new original" }, result.original)
    assert.same({ "new modified" }, result.modified)
    assert.same({ "old 2" }, vim.api.nvim_buf_get_lines(buffers[2], 0, -1, false))
  end)

  it("does not read index sources for a worktree-only event", function()
    local result
    snapshot.read(session, { worktree = true }, snapshot.capture(session), function(err, data)
      assert.is_nil(err)
      result = data
    end)
    assert.same({}, callbacks)
    assert.same({ "old 1" }, result.original)
  end)

  it("reports read failures without applying a partial snapshot", function()
    local failure
    snapshot.read(session, { index = true }, snapshot.capture(session), function(err)
      failure = err
    end)
    callbacks[":2"]("git failed")
    callbacks[":3"](nil, { "new modified" })
    assert.is_true(vim.wait(1000, function()
      return failure ~= nil
    end, 10))
    assert.equals("git failed", failure)
    assert.same({ "old 2" }, vim.api.nvim_buf_get_lines(buffers[2], 0, -1, false))
  end)

  it("represents a missing side as empty content rather than a transport failure", function()
    local result
    snapshot.read(session, { index = true }, snapshot.capture(session), function(err, data)
      assert.is_nil(err)
      result = data
    end)
    callbacks[":2"]("File 'file.txt' not found in revision ':2'")
    callbacks[":3"](nil, { "new modified" })
    assert.is_true(vim.wait(1000, function()
      return result ~= nil
    end, 10))
    assert.same({ "" }, result.original)
  end)
end)
