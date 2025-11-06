-- Simple Gdiff vs CodeDiff comparison
-- Usage: nvim --headless -c "lua dofile('scripts/compare_perf.lua')" -- <file> <revision>
-- Example: nvim --headless -c "lua dofile('scripts/compare_perf.lua')" -- lua/vscode-diff/diff.lua HEAD~5

local args = vim.fn.argv()
if #args < 2 then
  print("Usage: nvim --headless -c \"lua dofile('scripts/compare_perf.lua')\" -- <file> <revision>")
  print("Example: nvim --headless -c \"lua dofile('scripts/compare_perf.lua')\" -- lua/vscode-diff/diff.lua HEAD~5")
  vim.cmd('cquit 1')
end

local file = args[0]
local revision = args[1]

print(string.format("\nComparing: %s @ %s\n", file, revision))

-- Setup
vim.opt.runtimepath:prepend(vim.fn.expand('~/.local/share/nvim/lazy/vim-fugitive'))
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Test Gdiff
print("Testing Gdiff...")
vim.cmd('edit ' .. vim.fn.fnameescape(file))
local start = vim.loop.hrtime()
pcall(vim.cmd, 'Gdiff ' .. revision)
vim.cmd('redraw')
local gdiff_time = (vim.loop.hrtime() - start) / 1000000
print(string.format("  Gdiff:    %.2f ms", gdiff_time))
pcall(vim.cmd, 'tabclose')

-- Test CodeDiff
print("Testing CodeDiff...")
vim.cmd('edit ' .. vim.fn.fnameescape(file))
start = vim.loop.hrtime()
pcall(vim.cmd, 'CodeDiff ' .. revision)
vim.cmd('redraw')
local codediff_time = (vim.loop.hrtime() - start) / 1000000
print(string.format("  CodeDiff: %.2f ms", codediff_time))

-- Results
print(string.format("\nRatio: %.2fx", codediff_time / gdiff_time))
if codediff_time < gdiff_time then
  print("Winner: CodeDiff")
else
  print("Winner: Gdiff")
end

vim.cmd('quitall!')
