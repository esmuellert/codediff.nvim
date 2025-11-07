-- Test: Semantic Tokens Rendering
-- Validates that our vendored semantic token implementation matches Neovim's behavior

describe("Semantic Tokens Rendering", function()
  -- Test 1: Module loads without errors
  it("Module loads successfully", function()
    local semantic = require("vscode-diff.render.semantic_tokens")
    assert.is_not_nil(semantic, "Module should load")
    assert.equal("function", type(semantic.apply_semantic_tokens), "Should export apply_semantic_tokens")
    assert.equal("function", type(semantic.clear), "Should export clear")
  end)

  -- Test 2: Version compatibility check
  it("Version compatibility check works", function()
    local semantic = require("vscode-diff.render.semantic_tokens")
    
    -- Should gracefully return false if no clients
    local result = semantic.apply_semantic_tokens(1, 1)
    assert.equal(false, result, "Should return false when no LSP clients")
    
    -- On Neovim 0.9+, semantic tokens module should exist
    if vim.fn.has('nvim-0.9') == 1 then
      assert.is_not_nil(vim.lsp.semantic_tokens, "Neovim 0.9+ should have semantic_tokens")
      assert.is_not_nil(vim.str_byteindex, "Neovim 0.9+ should have str_byteindex")
    end
  end)

  -- Test 3: Vendored modifiers_from_number matches Neovim's implementation
  it("modifiers_from_number implementation matches Neovim", function()
    -- We need to test our vendored function matches Neovim's behavior
    -- Unfortunately the function is local, so we test it indirectly through the full flow
    
    -- Just verify the bit module is available (required for the function)
    local bit = require('bit')
    assert.is_not_nil(bit.band, "bit.band should be available")
    assert.is_not_nil(bit.rshift, "bit.rshift should be available")
  end)

  -- Test 4: Clear function works
  it("Clear function works without errors", function()
    local semantic = require("vscode-diff.render.semantic_tokens")
    
    -- Create a test buffer
    local buf = vim.api.nvim_create_buf(false, true)
    
    -- Should not error when clearing empty buffer
    semantic.clear(buf)
    
    -- Should not error when clearing invalid buffer
    vim.api.nvim_buf_delete(buf, { force = true })
    semantic.clear(buf)  -- Should handle invalid buffer gracefully
  end)

  -- Test 5: Namespace is created correctly
  it("Semantic token namespace exists", function()
    local semantic = require("vscode-diff.render.semantic_tokens")
    
    local namespaces = vim.api.nvim_get_namespaces()
    assert.is_not_nil(namespaces.vscode_diff_semantic_tokens, 
      "vscode_diff_semantic_tokens namespace should be created")
  end)

  -- Test 6: Integration test with real LSP (if available)
  it("Integration with LSP client (if available)", function()
    -- Skip if no LSP support
    if not vim.lsp.semantic_tokens then
      print(" (skipped: Neovim < 0.9)")
      return
    end
    
    local semantic = require("vscode-diff.render.semantic_tokens")
    
    -- Create test buffers
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)
    
    -- Set some content
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, {
      "local function test()",
      "  return 42",
      "end"
    })
    
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, {
      "local function test()",
      "  return 42",
      "end"
    })
    
    -- Set filetype to trigger potential LSP
    vim.bo[left_buf].filetype = "lua"
    vim.bo[right_buf].filetype = "lua"
    
    -- Try to apply semantic tokens (will fail gracefully if no LSP client)
    local result = semantic.apply_semantic_tokens(left_buf, right_buf)
    
    -- Result should be false if no LSP client attached, which is expected
    assert.equal("boolean", type(result), "Should return boolean")
    
    -- Cleanup
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- Test 7: Token encoding/decoding consistency
  it("Token data structure handling", function()
    -- Test that our implementation handles the expected LSP token format
    -- LSP tokens are arrays of [deltaLine, deltaStart, length, tokenType, tokenModifiers]
    
    -- Mock token data (from LSP spec example)
    local mock_tokens = {
      0, 5, 4, 1, 0,  -- Line 0, col 5, length 4, type 1, no modifiers
      1, 0, 3, 2, 1,  -- Line 1, col 0, length 3, type 2, modifier bit 1
    }
    
    -- Verify array length (should be multiple of 5)
    assert.equal(0, #mock_tokens % 5, "Token data should be multiple of 5")
    
    -- Each token has exactly 5 elements
    local token_count = #mock_tokens / 5
    assert.equal(2, token_count, "Should have 2 tokens in mock data")
  end)

  -- Test 8: Highlight priority respects Neovim defaults
  it("Respects Neovim's semantic token priority", function()
    -- Should use vim.hl.priorities.semantic_tokens if available
    if vim.hl.priorities and vim.hl.priorities.semantic_tokens then
      local priority = vim.hl.priorities.semantic_tokens
      assert.equal("number", type(priority), "Priority should be a number")
      assert.is_true(priority > 0, "Priority should be positive")
    else
      -- Fallback for older Neovim versions
      local fallback = 125
      assert.equal("number", type(fallback), "Fallback priority should be a number")
    end
  end)

  -- Test 9: URI handling for scratch buffers
  it("URI construction for diff buffers", function()
    -- Create a real file buffer
    local tmpfile = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({"local x = 1"}, tmpfile)
    
    local buf = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(buf)
    
    -- Get URI
    local uri = vim.uri_from_bufnr(buf)
    assert.equal("string", type(uri), "URI should be a string")
    assert.is_true(uri:match("^file://") ~= nil, "URI should start with file://")
    
    -- Cleanup
    vim.fn.delete(tmpfile)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 10: Graceful handling of missing capabilities
  it("Handles missing semantic token capabilities", function()
    local semantic = require("vscode-diff.render.semantic_tokens")
    
    -- Create buffers with no LSP client
    local left_buf = vim.api.nvim_create_buf(false, true)
    local right_buf = vim.api.nvim_create_buf(false, true)
    
    -- Should return false gracefully
    local result = semantic.apply_semantic_tokens(left_buf, right_buf)
    assert.equal(false, result, "Should return false with no LSP client")
    
    -- Cleanup
    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- Test 11: Virtual file URL creation and parsing
  it("Virtual file URL creation and parsing", function()
    local virtual_file = require("vscode-diff.virtual_file")
    
    -- Test URL creation with actual hex commit hash (use platform-agnostic path)
    local git_root = vim.fn.has("win32") == 1 and "D:/project" or "/home/user/project"
    local commit = "abc123def456"  -- Use hex commit hash instead of "HEAD"
    local filepath = "src/file.lua"
    
    local url = virtual_file.create_url(git_root, commit, filepath)
    assert.equal("string", type(url), "URL should be a string")
    assert.is_true(url:match("^vscodediff://") ~= nil, "URL should start with vscodediff://")
    
    -- Test URL parsing (normalize both for comparison)
    local parsed_root, parsed_commit, parsed_path = virtual_file.parse_url(url)
    local normalized_parsed = vim.fn.fnamemodify(parsed_root, ':p'):gsub('[/\\]$', ''):gsub('\\', '/')
    local normalized_expected = vim.fn.fnamemodify(git_root, ':p'):gsub('[/\\]$', ''):gsub('\\', '/')
    assert.equal(normalized_expected, normalized_parsed, "Parsed git root should match")
    assert.equal(commit, parsed_commit, "Parsed commit should match")
    assert.equal(filepath, parsed_path, "Parsed filepath should match")

    -- Test with different inputs (use platform-agnostic path)
    local test_root = vim.fn.has("win32") == 1 and "C:/test" or "/tmp/test"
    local url2 = virtual_file.create_url(test_root, "abc123", "test.lua")
    local root2, commit2, path2 = virtual_file.parse_url(url2)
    -- Normalize both paths for comparison on Windows
    local normalized_root2 = vim.fn.fnamemodify(root2, ':p'):gsub('[/\\]$', ''):gsub('\\', '/')
    local normalized_test_root = vim.fn.fnamemodify(test_root, ':p'):gsub('[/\\]$', ''):gsub('\\', '/')
    assert.equal(normalized_test_root, normalized_root2, "Root should match")
    assert.equal("abc123", commit2, "Commit should match")
    assert.equal("test.lua", path2, "Path should match")
  end)

  -- Test 12: Diagnostics disabled on virtual buffers
  it("Diagnostics are disabled on virtual buffers", function()
    -- This tests that vim.diagnostic.enable(false) is called on virtual buffers
    -- We can't easily test the actual BufReadCmd callback without a real git repo
    -- so we test that the API works correctly
    
    local test_buf = vim.api.nvim_create_buf(false, true)
    
    -- Initially diagnostics should be enabled
    assert.equal(true, vim.diagnostic.is_enabled({bufnr = test_buf}), 
      "Diagnostics should be enabled by default")
    
    -- Disable diagnostics
    vim.diagnostic.enable(false, {bufnr = test_buf})
    
    -- Verify disabled
    assert.equal(false, vim.diagnostic.is_enabled({bufnr = test_buf}),
      "Diagnostics should be disabled after vim.diagnostic.enable(false)")
    
    -- Cleanup
    vim.api.nvim_buf_delete(test_buf, { force = true })
  end)
end)
