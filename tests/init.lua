-- Test init file for plenary tests
-- This loads the plugin and plenary.nvim

-- Add current directory to runtimepath
vim.opt.rtp:prepend(".")
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

-- Load plugin files (for integration tests that need commands)
vim.cmd('runtime! plugin/*.lua plugin/*.vim')

-- Setup plugin
require("vscode-diff").setup()
