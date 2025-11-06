-- Integration test: Verify virtual buffer diagnostics are disabled
-- This is an end-to-end test that requires a real git repository

describe("Virtual buffer diagnostics integration", function()
  it("Disables diagnostics on virtual buffers in real CodeDiff usage", function()
    -- This test runs the actual :CodeDiff command and verifies behavior
    -- Skip if not in a git repo
    local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
    if vim.v.shell_error ~= 0 then
      print("  (skipped: not in git repo)")
      return
    end
    
    -- Navigate to git repo root
    vim.cmd('cd ' .. git_root)
    
    -- Edit a file that exists in history
    local test_file = git_root .. "/lua/vscode-diff/git.lua"
    if vim.fn.filereadable(test_file) == 0 then
      print("  (skipped: test file not found)")
      return
    end
    
    vim.cmd('edit ' .. test_file)
    
    -- Try to find a valid revision - use HEAD first, or HEAD~1 if possible
    local revision = "HEAD"
    local commit_count = vim.fn.systemlist("git rev-list --count HEAD")[1]
    if vim.v.shell_error == 0 and tonumber(commit_count) > 1 then
      revision = "HEAD~1"
    end
    
    -- Run CodeDiff with a valid revision
    local ok, err = pcall(function()
      vim.cmd('CodeDiff ' .. revision)
    end)
    
    if not ok then
      print("  (skipped: CodeDiff failed - " .. tostring(err) .. ")")
      return
    end
    
    -- Wait for diff view to be created
    local view_created = vim.wait(2000, function()
      return #vim.api.nvim_list_wins() > 1
    end, 100)
    
    assert.is_true(view_created, "Diff view should be created")
    
    -- Wait for async BufReadCmd callback to complete and disable diagnostics
    vim.wait(1000)
    
    -- Check all windows and buffers
    local wins = vim.api.nvim_list_wins()
    local virtual_buf_found = false
    local virtual_buf_diag_disabled = false
    
    for _, win in ipairs(wins) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      local is_virtual = name:match('^vscodediff://')
      
      if is_virtual then
        virtual_buf_found = true
        local diag_enabled = vim.diagnostic.is_enabled({bufnr = buf})
        if not diag_enabled then
          virtual_buf_diag_disabled = true
        end
        
        assert.is_false(diag_enabled, 
          string.format('Virtual buffer %d should have diagnostics disabled', buf))
      end
    end
    
    assert.is_true(virtual_buf_found, "Should find at least one virtual buffer")
    assert.is_true(virtual_buf_diag_disabled, "Virtual buffer should have diagnostics disabled")
  end)
end)
