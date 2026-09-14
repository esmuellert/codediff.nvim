-- Regression test for https://github.com/esmuellert/codediff.nvim/issues/390
-- Selecting a deleted file in `:CodeDiff HEAD~N` mode must load its content
-- from HEAD~N, not from `:0`/`HEAD` (where the file is already gone).

local h = require('tests.support')

describe('Issue #390 regression — deleted file shows content in revision mode', function()
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    if repo then repo.cleanup() end
    while vim.fn.tabpagenr('$') > 1 do
      vim.cmd('tabclose')
    end
  end)

  it('selecting a deleted file in `:CodeDiff HEAD~N` mode loads its content from HEAD~N', function()
    repo.write_file('to_delete.txt', {
      "first line",
      "second line",
      "third line",
    })
    repo.write_file('keep.txt', { "v1" })
    repo.git("add .")
    repo.git("commit -m c0")        -- HEAD~5

    repo.write_file('keep.txt', { "v1", "v2" })
    repo.git("commit -am c1")

    repo.write_file('keep.txt', { "v1", "v2", "v3" })
    repo.git("commit -am c2")

    repo.git("rm to_delete.txt")
    repo.git("commit -m c3-delete")

    repo.write_file('keep.txt', { "v1", "v2", "v3", "v4" })
    repo.git("commit -am c4")

    repo.write_file('keep.txt', { "v1", "v2", "v3", "v4", "v5" })
    repo.git("commit -am c5")

    local diff_out = repo.git("diff HEAD~5 -- to_delete.txt")
    assert.is_true(
      diff_out:find("deleted file mode", 1, true) ~= nil,
      "git diff HEAD~5 should report to_delete.txt as deleted"
    )

    vim.cmd("edit " .. repo.dir .. "/keep.txt")
    local commands = require("codediff.commands")
    commands.vscode_diff({ fargs = { "HEAD~5" } })

    local lifecycle = require("codediff.ui.lifecycle")

    -- Wait for the explorer to populate.
    local ok = vim.wait(8000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local sess = lifecycle.get_session(tp)
        if sess and (sess.panel or {}).view and (sess.panel or {}).view.tree and (sess.panel or {}).view.tree._nodes then
          return true
        end
      end
      return false
    end, 50)
    assert.is_true(ok, "explorer did not become ready within timeout")

    -- Locate the explorer and walk its tree to find to_delete.txt.
    local explorer
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and (s.panel or {}).view then
        explorer = (s.panel or {}).view
        break
      end
    end
    assert.is_not_nil(explorer, "no explorer session created")
    assert.is_function(explorer.on_file_select, "explorer.on_file_select missing")

    local file_data
    local function walk(node, depth)
      if type(node) ~= "table" or depth > 8 then return end
      if node.data and type(node.data) == "table" then
        local p = node.data.path or ""
        if p:find("to_delete.txt", 1, true) and node.data.status == "D" then
          file_data = node.data
          return
        end
      end
      for k, v in pairs(node) do
        if file_data then return end
        if type(v) == "table" and k ~= "parent" then walk(v, depth + 1) end
      end
    end
    walk(explorer.tree, 0)

    assert.is_not_nil(file_data,
      "explorer did not list to_delete.txt with status 'D' in revision mode")
    assert.equal("D", file_data.status)

    -- Trigger the same code path that the user's <CR> keymap hits.
    explorer.on_file_select(file_data, { force = true })

    -- Give the virtual-file load callback time to land.
    local diff_ready = vim.wait(5000, function()
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        local s = lifecycle.get_session(tp)
        if s and s.original_bufnr and vim.api.nvim_buf_is_valid(s.original_bufnr) then
          local lines = vim.api.nvim_buf_get_lines(s.original_bufnr, 0, -1, false)
          if #lines >= 3 then return true end
        end
      end
      return false
    end, 50)

    -- Verify the original-side buffer now contains the deleted file's
    -- pre-deletion content. Pre-fix this was empty.
    local sess
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.original_bufnr then sess = s; break end
    end
    assert.is_not_nil(sess, "no diff session after selecting deleted file")

    local orig_lines = vim.api.nvim_buf_get_lines(sess.original_bufnr, 0, -1, false)
    local orig_text = table.concat(orig_lines, "\n")

    assert.is_true(diff_ready,
      "ORIGINAL buffer never received deleted file's content. Pre-fix bug: it stayed empty.\nGot lines: "
        .. vim.inspect(orig_lines))

    for _, expected in ipairs({ "first line", "second line", "third line" }) do
      assert.is_true(
        orig_text:find(expected, 1, true) ~= nil,
        "ORIGINAL buffer must contain '" .. expected .. "' from HEAD~5:to_delete.txt. Got:\n" .. orig_text
      )
    end

    -- And the revision the buffer is loaded from must NOT be the index
    -- (where the file is gone). Pre-fix this was ":0".
    assert.is_not.equal(":0", sess.original_revision,
      "ORIGINAL revision must not be ':0' for revision mode — that's the bug")
    assert.is_not.equal("HEAD", sess.original_revision,
      "ORIGINAL revision must not be 'HEAD' for revision mode — that's the bug")
  end)
end)
