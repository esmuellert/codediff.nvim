-- Lazy.nvim configuration compatibility tests
-- Tests real-world lazy.nvim plugin specs for both codediff and vscode-diff

describe("lazy.nvim compatibility", function()
  local original_loaded = {}

  -- Helper to simulate fresh module loading
  local function reset_module_cache()
    for name, _ in pairs(package.loaded) do
      if name:match("^codediff") or name:match("^vscode%-diff") then
        original_loaded[name] = package.loaded[name]
        package.loaded[name] = nil
      end
    end
  end

  local function restore_module_cache()
    for name, mod in pairs(original_loaded) do
      package.loaded[name] = mod
    end
    original_loaded = {}
  end

  after_each(function()
    restore_module_cache()
  end)

  describe("module loading", function()
    -- Simulates: { "esmuellert/codediff.nvim", cmd = "CodeDiff" }

    it("should load codediff module", function()
      reset_module_cache()
      local ok, mod = pcall(require, "codediff")
      assert.is_true(ok, "Failed to require codediff")
      assert.is_not_nil(mod)
      assert.is_function(mod.setup)
    end)

    it("should load vscode-diff module (backward compat)", function()
      reset_module_cache()
      local ok, mod = pcall(require, "vscode-diff")
      assert.is_true(ok, "Failed to require vscode-diff")
      assert.is_not_nil(mod)
      assert.is_function(mod.setup)
    end)

    it("should have same setup function behavior", function()
      local codediff = require("codediff")
      local vscode_diff = require("vscode-diff")
      -- Both should have setup function
      assert.is_function(codediff.setup)
      assert.is_function(vscode_diff.setup)
    end)
  end)

  describe("setup with opts", function()
    -- Simulates: { "esmuellert/codediff.nvim", opts = {} }

    it("should work with codediff.setup({})", function()
      reset_module_cache()
      local mod = require("codediff")
      assert.has_no.errors(function()
        mod.setup({})
      end)
    end)

    it("should work with vscode-diff.setup({}) (backward compat)", function()
      reset_module_cache()
      local mod = require("vscode-diff")
      assert.has_no.errors(function()
        mod.setup({})
      end)
    end)

    it("should accept explorer config", function()
      reset_module_cache()
      local mod = require("codediff")
      assert.has_no.errors(function()
        mod.setup({
          explorer = {
            position = "left",
            width = 40,
          },
        })
      end)
    end)

    it("should accept diff config", function()
      reset_module_cache()
      local mod = require("codediff")
      assert.has_no.errors(function()
        mod.setup({
          diff = {
            algorithm = "patience",
          },
        })
      end)
    end)
  end)

  describe("setup with config function", function()
    -- Simulates: config = function() require("codediff").setup({}) end

    it("should work with config function calling codediff", function()
      reset_module_cache()
      local config_fn = function()
        require("codediff").setup({
          explorer = { position = "right" },
        })
      end
      assert.has_no.errors(config_fn)
    end)

    it("should work with config function calling vscode-diff (backward compat)", function()
      reset_module_cache()
      local config_fn = function()
        require("vscode-diff").setup({
          explorer = { position = "right" },
        })
      end
      assert.has_no.errors(config_fn)
    end)
  end)

  describe("submodule access", function()
    -- New codediff paths
    it("should load codediff.ui", function()
      reset_module_cache()
      local ok, mod = pcall(require, "codediff.ui")
      assert.is_true(ok, "Failed to require codediff.ui")
      assert.is_not_nil(mod)
    end)

    it("should load codediff.core.git", function()
      reset_module_cache()
      local ok, mod = pcall(require, "codediff.core.git")
      assert.is_true(ok, "Failed to require codediff.core.git")
      assert.is_not_nil(mod)
    end)

    it("should load codediff.core.diff", function()
      reset_module_cache()
      local ok, mod = pcall(require, "codediff.core.diff")
      assert.is_true(ok, "Failed to require codediff.core.diff")
      assert.is_not_nil(mod)
    end)

    -- Backward compatibility paths
    it("should load vscode-diff.ui (backward compat)", function()
      reset_module_cache()
      local ok, mod = pcall(require, "vscode-diff.ui")
      assert.is_true(ok, "Failed to require vscode-diff.ui")
      assert.is_not_nil(mod)
    end)

    it("should load vscode-diff.git (backward compat)", function()
      reset_module_cache()
      local ok, mod = pcall(require, "vscode-diff.git")
      assert.is_true(ok, "Failed to require vscode-diff.git")
      assert.is_not_nil(mod)
    end)

    it("should load vscode-diff.render (backward compat)", function()
      reset_module_cache()
      local ok, mod = pcall(require, "vscode-diff.render")
      assert.is_true(ok, "Failed to require vscode-diff.render")
      assert.is_not_nil(mod)
    end)

    it("should load vscode-diff.diff (backward compat)", function()
      reset_module_cache()
      local ok, mod = pcall(require, "vscode-diff.diff")
      assert.is_true(ok, "Failed to require vscode-diff.diff")
      assert.is_not_nil(mod)
    end)
  end)
end)
