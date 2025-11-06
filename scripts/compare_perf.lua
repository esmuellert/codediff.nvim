-- Simple Gdiff vs CodeDiff comparison
-- Usage: nvim --headless -c "lua dofile('scripts/compare_perf.lua')" -- <file> <revision>
-- Example: nvim --headless -c "lua dofile('scripts/compare_perf.lua')" -- lua/vscode-diff/diff.lua HEAD~5

local args = vim.fn.argv()
if #args < 2 then
  print("Usage: nvim --headless -c \"lua dofile('scripts/compare_perf.lua')\" -- <file> <revision>")
  print("Example: nvim --headless -c \"lua dofile('scripts/compare_perf.lua')\" -- lua/vscode-diff/diff.lua HEAD~5")
  vim.cmd('cquit 1')
end

-- Args are 0-indexed
local file = args[1]
local revision = args[2]

print(string.format("\nComparing: %s @ %s\n", file, revision))

-- Setup paths (Windows compatible)
local home = vim.fn.has('win32') == 1 and vim.fn.expand('~/AppData/Local') or vim.fn.expand('~/.local/share')
vim.opt.runtimepath:prepend(home .. '/nvim/lazy/vim-fugitive')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Helper: wait for rendering to complete
local function wait_for_render()
  vim.cmd('redraw')
  -- Wait for extmarks/highlights to be applied
  vim.wait(200, function()
    -- Check if diff highlighting is applied (windows exist)
    return vim.fn.winnr('$') > 1
  end)
end

-- Test Gdiff
local gdiff_time = nil
print("Testing Gdiff...")

-- Check if vim-fugitive is available
local has_fugitive = pcall(function()
  vim.cmd('runtime plugin/fugitive.vim')
end)

if not has_fugitive or vim.fn.exists(':Gdiff') == 0 then
  print("  ⚠️  vim-fugitive not available, skipping Gdiff")
else
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  local start = vim.loop.hrtime()
  local success = pcall(vim.cmd, 'Gdiff ' .. revision)
  if success then
    wait_for_render()
    gdiff_time = (vim.loop.hrtime() - start) / 1000000
    print(string.format("  Gdiff:    %.2f ms", gdiff_time))
  else
    print("  ❌ Gdiff failed")
  end
  pcall(vim.cmd, 'tabclose')
  pcall(vim.cmd, 'bwipeout!')
end

-- Test CodeDiff
local codediff_time = nil
print("\nTesting CodeDiff...")

-- Check if vscode-diff is available
local has_codediff = pcall(require, 'vscode-diff')

if not has_codediff or vim.fn.exists(':CodeDiff') == 0 then
  print("  ⚠️  vscode-diff.nvim not available, skipping CodeDiff")
else
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  local start = vim.loop.hrtime()
  local success = pcall(vim.cmd, 'CodeDiff ' .. revision)
  if success then
    wait_for_render()
    codediff_time = (vim.loop.hrtime() - start) / 1000000
    print(string.format("  CodeDiff: %.2f ms", codediff_time))
  else
    print("  ❌ CodeDiff failed")
  end
  pcall(vim.cmd, 'tabclose')
  pcall(vim.cmd, 'bwipeout!')
end

-- Results
print("\n" .. string.rep("=", 50))
if gdiff_time and codediff_time then
  print(string.format("Ratio: %.2fx", codediff_time / gdiff_time))
  if codediff_time < gdiff_time then
    print(string.format("✅ Winner: CodeDiff (%.1fx faster)", gdiff_time / codediff_time))
  else
    print(string.format("⚠️  Winner: Gdiff (%.1fx faster)", codediff_time / gdiff_time))
  end
elseif gdiff_time then
  print("Only Gdiff available")
elseif codediff_time then
  print("Only CodeDiff available")
else
  print("❌ Neither plugin available")
end

vim.cmd('quitall!')
