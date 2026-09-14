-- Test: Timeout Mechanism
-- Validates that timeout works correctly from Lua through to C Myers algorithm

local diff = require('codediff.core.diff')
local config = require("codediff.config")

describe("Timeout Mechanism", function()
  -- Test files for consistent testing
  local test_files = {
    small = { "line1", "line2", "line3" },
    small_modified = { "line1", "modified", "line3" },
  }
  
  -- Helper to read large test files if they exist
  local function get_large_test_files()
    local has_files = vim.fn.filereadable("example/EnterpriseDataAccess_HEAD~30.cs") == 1
                   and vim.fn.filereadable("example/EnterpriseDataAccess.cs") == 1
    
    if has_files then
      return {
        orig = vim.fn.readfile("example/EnterpriseDataAccess_HEAD~30.cs"),
        modified = vim.fn.readfile("example/EnterpriseDataAccess.cs")
      }
    end
    return nil
  end

  describe("Basic timeout functionality", function()
    it("accepts timeout parameter in options", function()
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        { max_computation_time_ms = 5000 }
      )
      assert.is_not_nil(result, "Result should not be nil")
      assert.equal("boolean", type(result.hit_timeout), "Should have hit_timeout flag")
    end)

    it("completes quickly with generous timeout", function()
      local start_time = vim.loop.hrtime()
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        { max_computation_time_ms = 5000 }
      )
      local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
      
      assert.is_false(result.hit_timeout, "Should not hit timeout on small files")
      assert.is_true(elapsed_ms < 1000, "Should complete in less than 1 second")
    end)

    it("uses default timeout when not specified", function()
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified
      )
      -- Should use default 5000ms from diff.lua
      assert.is_not_nil(result, "Result should not be nil")
      assert.is_false(result.hit_timeout, "Should not timeout on small files with default")
    end)
  end)

  describe("Timeout behavior on large files", function()
    local large_files = get_large_test_files()
    
    if large_files then
      it("completes with normal timeout (5000ms)", function()
        local start_time = vim.loop.hrtime()
        local result = diff.compute_diff(
          large_files.orig,
          large_files.modified,
          { max_computation_time_ms = 5000 }
        )
        local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
        
        -- Should complete within 5 seconds (typically ~1.2s)
        assert.is_not_nil(result, "Result should not be nil")
        assert.is_true(elapsed_ms < 5000, "Should complete within timeout")
        -- May or may not timeout depending on machine speed
      end)

      it("hits timeout with very short timeout (50ms)", function()
        local start_time = vim.loop.hrtime()
        local result = diff.compute_diff(
          large_files.orig,
          large_files.modified,
          { max_computation_time_ms = 50 }
        )
        local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_not_nil(result, "Result should not be nil even on timeout")
        assert.is_true(result.hit_timeout, "Should hit timeout with 50ms limit")
        assert.is_true(elapsed_ms < 500, "Should abort quickly after timeout")
        assert.is_true(#result.changes > 0, "Should still return partial results")
      end)

      it("returns trivial diff with extremely short timeout (10ms)", function()
        local start_time = vim.loop.hrtime()
        local result = diff.compute_diff(
          large_files.orig,
          large_files.modified,
          { max_computation_time_ms = 10 }
        )
        local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
        
        assert.is_not_nil(result, "Result should not be nil")
        assert.is_true(result.hit_timeout, "Should hit timeout with 10ms limit")
        assert.is_true(elapsed_ms < 100, "Should abort very quickly")
        
        -- With such a short timeout, should get minimal detail
        assert.is_true(#result.changes > 0, "Should have at least one change")
        if #result.changes == 1 and result.changes[1].inner_changes then
          local inner_count = #result.changes[1].inner_changes
          -- Very short timeout may result in trivial diff (1 inner change)
          assert.is_true(inner_count <= 100, "Should have minimal inner detail on timeout")
        end
      end)
    else
      pending("skipping large file tests (test files not found)")
    end
  end)

  describe("Config integration", function()
    it("respects config timeout setting", function()
      -- Save original config
      local original_timeout = config.options.diff.max_computation_time_ms
      
      -- Set very short timeout via config
      config.setup({
        diff = {
          max_computation_time_ms = 100,
        }
      })
      
      assert.equal(100, config.options.diff.max_computation_time_ms,
        "Config should update timeout")
      
      -- Use config value in diff options
      local diff_options = {
        max_computation_time_ms = config.options.diff.max_computation_time_ms,
      }
      
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        diff_options
      )
      
      assert.is_not_nil(result, "Result should not be nil")
      
      -- Restore original config
      config.setup({
        diff = {
          max_computation_time_ms = original_timeout,
        }
      })
    end)

    it("has default timeout of 5000ms", function()
      -- Reset to defaults
      config.options = vim.deepcopy(config.defaults)
      
      assert.equal(5000, config.options.diff.max_computation_time_ms,
        "Default timeout should be 5000ms (VSCode default)")
    end)
  end)

  describe("VSCode parity", function()
    it("timeout applies to both line-level and char-level Myers", function()
      -- This is a behavior test - we can't directly verify the internal
      -- implementation, but we can verify that timeout affects the output
      local large_files = get_large_test_files()
      
      if large_files then
        -- With normal timeout, should get full detail
        local result_normal = diff.compute_diff(
          large_files.orig,
          large_files.modified,
          { max_computation_time_ms = 5000 }
        )
        
        -- With short timeout, should get less detail
        local result_short = diff.compute_diff(
          large_files.orig,
          large_files.modified,
          { max_computation_time_ms = 50 }
        )
        
        -- Timeout should affect inner changes detail
        if result_short.hit_timeout and #result_normal.changes > 0 then
          local normal_inner_total = 0
          for _, change in ipairs(result_normal.changes) do
            if change.inner_changes then
              normal_inner_total = normal_inner_total + #change.inner_changes
            end
          end
          
          local short_inner_total = 0
          for _, change in ipairs(result_short.changes) do
            if change.inner_changes then
              short_inner_total = short_inner_total + #change.inner_changes
            end
          end
          
          -- Short timeout should produce less detailed results
          assert.is_true(short_inner_total <= normal_inner_total,
            "Timeout should reduce inner change detail")
        end
      else
        pending("skipping (large test files not found)")
      end
    end)

    it("returns same data structure on timeout as non-timeout", function()
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        { max_computation_time_ms = 1 }  -- Very short to possibly trigger timeout
      )
      
      -- Should still return valid structure
      assert.equal("table", type(result), "Result should be a table")
      assert.equal("table", type(result.changes), "Should have changes array")
      assert.equal("table", type(result.moves), "Should have moves array")
      assert.equal("boolean", type(result.hit_timeout), "Should have hit_timeout flag")
      
      -- Changes should be valid even if timeout hit
      if #result.changes > 0 then
        local change = result.changes[1]
        assert.is_not_nil(change.original, "Should have original range")
        assert.is_not_nil(change.modified, "Should have modified range")
        assert.equal("table", type(change.inner_changes), "Should have inner_changes")
      end
    end)
  end)

  describe("Edge cases", function()
    it("handles zero timeout (infinite)", function()
      -- 0 means infinite timeout in C
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        { max_computation_time_ms = 0 }
      )
      
      assert.is_not_nil(result, "Result should not be nil")
      assert.is_false(result.hit_timeout, "Should not timeout with infinite timeout")
    end)

    it("handles negative timeout gracefully", function()
      -- Should treat as 0 (infinite) or handle gracefully
      local result = diff.compute_diff(
        test_files.small,
        test_files.small_modified,
        { max_computation_time_ms = -1 }
      )
      
      assert.is_not_nil(result, "Result should not be nil with negative timeout")
    end)

    it("works with empty files and timeout", function()
      local result = diff.compute_diff(
        {},
        {},
        { max_computation_time_ms = 100 }
      )
      
      assert.is_not_nil(result, "Result should not be nil for empty files")
      assert.is_false(result.hit_timeout, "Should not timeout on empty files")
      assert.equal(0, #result.changes, "Empty files should have no changes")
    end)
  end)
end)
