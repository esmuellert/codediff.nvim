-- Test init file for plenary tests
-- This loads the plugin and plenary.nvim

-- Disable auto-installation in tests (library is already built by CI)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"

-- Disable ShaDa (fixes Windows permission issues in CI)
vim.opt.shadafile = "NONE"

-- Add current directory to runtimepath
local cwd = vim.fn.getcwd()
vim.opt.rtp:prepend(cwd)

-- Ensure lua/ directory is in package.path for direct requires
package.path = package.path .. ";" .. cwd .. "/lua/?.lua;" .. cwd .. "/lua/?/init.lua"

vim.opt.swapfile = false

-- Setup plenary.nvim in Neovim's data directory (proper location)
local plenary_dir = vim.fn.stdpath("data") .. "/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  -- Clone plenary if not found
  print("Installing plenary.nvim for tests...")
  vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_dir,
  })
end
vim.opt.rtp:prepend(plenary_dir)

-- Setup nui.nvim (required for explorer mode)
local nui_dir = vim.fn.stdpath("data") .. "/nui.nvim"
if vim.fn.isdirectory(nui_dir) == 0 then
  print("Installing nui.nvim for tests...")
  vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/MunifTanjim/nui.nvim",
    nui_dir,
  })
end
vim.opt.rtp:prepend(nui_dir)
-- Also add to package.path for direct requires
nui_dir = nui_dir:gsub("\\", "/")
package.path = package.path .. ";" .. nui_dir .. "/lua/?.lua;" .. nui_dir .. "/lua/?/init.lua"

-- Load plugin files (for integration tests that need commands)
vim.cmd('runtime! plugin/*.lua plugin/*.vim')

-- Setup plugin
require("codediff").setup()

-- Pre-load ALL modules to ensure they're in package.loaded before tests change cwd.
-- Tests change to temp directories, and lazy-loaded modules inside async callbacks
-- (vim.schedule) would fail to load via package.path after cwd changes.
local modules_to_preload = {
  "codediff.config",
  "codediff.core.diff",
  "codediff.core.dir",
  "codediff.core.git",
  "codediff.core.path",
  "codediff.core.virtual_file",
  "codediff.ui",
  "codediff.ui.auto_refresh",
  "codediff.ui.conflict",
  "codediff.ui.core",
  "codediff.ui.explorer",
  "codediff.ui.highlights",
  "codediff.ui.history",
  "codediff.ui.lifecycle",
  "codediff.ui.merge_alignment",
  "codediff.ui.semantic_tokens",
  "codediff.ui.view",
  "codediff.version",
}

for _, mod in ipairs(modules_to_preload) do
  pcall(require, mod)
end
