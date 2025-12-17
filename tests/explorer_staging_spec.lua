-- Test explorer staging/unstaging workflow with highlights
-- This tests buffer management during file switching in explorer mode

describe("Explorer Buffer Management", function()
  local test_dir
  local test_file
  local test_file_rel = "test.txt"
  local original_content = "line 1\nline 2\nline 3\n"
  
  before_each(function()
    -- Create a temp git repo
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    
    -- Initialize git repo
    vim.fn.system("cd " .. test_dir .. " && git init")
    vim.fn.system("cd " .. test_dir .. " && git config user.email 'test@test.com'")
    vim.fn.system("cd " .. test_dir .. " && git config user.name 'Test'")
    
    -- Create initial file and commit
    test_file = test_dir .. "/" .. test_file_rel
    vim.fn.writefile(vim.split(original_content, "\n", { plain = true }), test_file)
    vim.fn.system("cd " .. test_dir .. " && git add test.txt && git commit -m 'initial'")
  end)
  
  after_each(function()
    -- Cleanup
    if test_dir then
      vim.fn.delete(test_dir, "rf")
    end
  end)
  
  -- Helper to get buffer content
  local function get_buffer_content(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return table.concat(lines, "\n")
  end
  
  -- Helper to wait for virtual file to load
  local function wait_for_diff_ready(tabpage, timeout)
    timeout = timeout or 5000
    local lifecycle = require('vscode-diff.render.lifecycle')
    local ready = vim.wait(timeout, function()
      local session = lifecycle.get_session(tabpage)
      if not session then return false end
      -- Check that diff_result exists (set after render_everything completes)
      if not session.diff_result then return false end
      -- Also verify buffers are valid
      local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
      if not orig_buf or not mod_buf then return false end
      return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
    end, 100)
    return ready
  end
  
  it("should parse virtual file URLs correctly", function()
    local virtual_file = require('vscode-diff.virtual_file')
    
    -- Test HEAD revision
    local url1 = virtual_file.create_url("/tmp/test", "HEAD", "file.txt")
    local g1, c1, f1 = virtual_file.parse_url(url1)
    assert.equals("/tmp/test", g1)
    assert.equals("HEAD", c1)
    assert.equals("file.txt", f1)
    
    -- Test :0 (staged) revision
    local url2 = virtual_file.create_url("/tmp/test", ":0", "file.txt")
    local g2, c2, f2 = virtual_file.parse_url(url2)
    assert.equals("/tmp/test", g2)
    assert.equals(":0", c2)
    assert.equals("file.txt", f2)
    
    -- Test SHA hash
    local url3 = virtual_file.create_url("/tmp/test", "abc123def456", "file.txt")
    local g3, c3, f3 = virtual_file.parse_url(url3)
    assert.equals("/tmp/test", g3)
    assert.equals("abc123def456", c3)
    assert.equals("file.txt", f3)
  end)
  
  it("should refresh staged content when index changes", function()
    -- This tests the full staging workflow:
    -- 1. Make change A -> validate in Changes
    -- 2. Stage change A -> validate in Staged Changes  
    -- 3. Make change B -> validate Changes has B, Staged has A
    -- 4. Stage change B -> validate Staged has A+B, no Changes
    -- 5. Unstage file -> validate Changes has A+B
    
    local view = require('vscode-diff.render.view')
    local lifecycle = require('vscode-diff.render.lifecycle')
    
    -- Step 1: Make change A
    vim.fn.writefile({"line 1", "line 2", "line 3", "change A"}, test_file)
    
    -- Create diff view for unstaged changes (index vs working)
    local config_changes = {
      mode = "standalone",
      git_root = test_dir,
      original_path = test_file_rel,
      modified_path = test_file,
      original_revision = ":0",
      modified_revision = "WORKING",
    }
    
    local result = view.create(config_changes, "text")
    assert.is_not_nil(result, "Should create diff view")
    local tabpage = vim.api.nvim_get_current_tabpage()
    
    wait_for_diff_ready(tabpage)
    
    -- Validate: Changes should show "change A" in modified buffer
    local _, modified_buf = lifecycle.get_buffers(tabpage)
    local content = get_buffer_content(modified_buf)
    assert.is_true(content:find("change A") ~= nil, "Changes should show change A")
    
    -- Step 2: Stage change A
    vim.fn.system("cd " .. test_dir .. " && git add test.txt")
    
    -- Switch to staged view (HEAD vs index)
    local config_staged = {
      mode = "standalone",
      git_root = test_dir,
      original_path = test_file_rel,
      modified_path = test_file_rel,
      original_revision = "HEAD",
      modified_revision = ":0",
    }
    
    view.update(tabpage, config_staged, false)
    wait_for_diff_ready(tabpage)
    
    -- Validate: Staged should show "change A"
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = get_buffer_content(modified_buf)
    assert.is_true(content:find("change A") ~= nil, "Staged should show change A after staging")
    
    -- Step 3: Make change B (while A is staged)
    vim.fn.writefile({"line 1", "line 2", "line 3", "change A", "change B"}, test_file)
    
    -- Switch back to Changes view (index vs working)
    view.update(tabpage, config_changes, false)
    wait_for_diff_ready(tabpage)
    
    -- Validate: Changes should show "change B" (the new unstaged change)
    local orig_buf
    orig_buf, modified_buf = lifecycle.get_buffers(tabpage)
    content = get_buffer_content(modified_buf)
    assert.is_not_nil(content, "Step 3 content should not be nil")
    assert.is_true(content:find("change B") ~= nil, "Changes should show change B")
    
    -- Switch to Staged view - should still show only "change A"
    view.update(tabpage, config_staged, false)
    wait_for_diff_ready(tabpage)
    
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = get_buffer_content(modified_buf)
    assert.is_true(content:find("change A") ~= nil, "Staged should still show change A")
    -- Note: content might also contain change B if we're viewing working file by mistake
    
    -- Step 4: Stage change B
    vim.fn.system("cd " .. test_dir .. " && git add test.txt")
    
    -- Refresh staged view
    view.update(tabpage, config_staged, false)
    wait_for_diff_ready(tabpage)
    
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = get_buffer_content(modified_buf)
    assert.is_true(content:find("change A") ~= nil, "Staged should show change A after staging B")
    assert.is_true(content:find("change B") ~= nil, "Staged should show change B after staging B")
    
    -- Step 5: Unstage file
    vim.fn.system("cd " .. test_dir .. " && git reset HEAD test.txt")
    
    -- Switch to Changes view - should now show both A and B
    view.update(tabpage, config_changes, false)
    wait_for_diff_ready(tabpage)
    
    _, modified_buf = lifecycle.get_buffers(tabpage)
    content = get_buffer_content(modified_buf)
    assert.is_true(content:find("change A") ~= nil, "Changes should show change A after unstage")
    assert.is_true(content:find("change B") ~= nil, "Changes should show change B after unstage")
  end)
end)
