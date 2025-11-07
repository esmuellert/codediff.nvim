-- Simple Gdiff vs CodeDiff comparison
-- Usage: nvim --headless --noplugin -u NONE -c "lua dofile('scripts/compare_perf.lua')" -- <file> <revision>
-- Example: nvim --headless --noplugin -u NONE -c "lua dofile('scripts/compare_perf.lua')" -- lua/vscode-diff/diff.lua HEAD~5

local args = vim.fn.argv()
if #args < 2 then
  print("Usage: nvim --headless --noplugin -u NONE -c \"lua dofile('scripts/compare_perf.lua')\" -- <file> <revision>")
  print("Example: nvim --headless --noplugin -u NONE -c \"lua dofile('scripts/compare_perf.lua')\" -- lua/vscode-diff/diff.lua HEAD~5")
  vim.cmd('cquit 1')
end

-- Args are 0-indexed
local file = args[1]
local revision = args[2]

print(string.format("\nComparing: %s @ %s\n", file, revision))

-- Setup minimal runtime path - only load the two plugins we're testing
local home = vim.fn.has('win32') == 1 and vim.fn.expand('~/AppData/Local') or vim.fn.expand('~/.local/share')
vim.opt.runtimepath:prepend(home .. '/nvim/lazy/vim-fugitive')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Helper: wait for rendering to complete
-- Note: In headless mode, extmarks may not be applied (async rendering limitation),
-- but windows are created synchronously. We wait a fixed time to ensure fair comparison.
local function wait_for_render()
  -- Wait for windows to be created
  local max_wait = 500
  local interval = 10

  for i = 1, max_wait / interval do
    if vim.fn.winnr('$') > 1 then
      -- Windows created, wait a fixed additional time for rendering
      -- This ensures consistent measurement across both plugins
      vim.wait(200)
      return true
    end
    vim.wait(interval)
  end

  return false
end

-- Test Gdiff
local gdiff_time = nil
print("Testing Gdiff (with inline:char for precise character-level diffs)...")

-- Check if vim-fugitive is available
local has_fugitive = pcall(function()
  vim.cmd('runtime plugin/fugitive.vim')
end)

if not has_fugitive or vim.fn.exists(':Gdiff') == 0 then
  print("  ⚠️  vim-fugitive not available, skipping Gdiff")
else
  -- Enable precise character-level diffs (same as vscode-diff)
  -- Set (not append) to ensure inline:char is active
  vim.opt.diffopt = 'internal,filler,algorithm:histogram,inline:char'

  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  local start = vim.loop.hrtime()
  local success = pcall(vim.cmd, { cmd = 'Gdiff', args = { revision } })
  if success then
    wait_for_render()
    gdiff_time = (vim.loop.hrtime() - start) / 1000000
    print(string.format("  Gdiff:    %.2f ms", gdiff_time))
  else
    print("  ❌ Gdiff failed")
  end
  pcall(vim.cmd, { cmd = 'tabclose' })
  pcall(vim.cmd, { cmd = 'bwipeout', bang = true })
end

-- Test CodeDiff
local codediff_time = nil
print("\nTesting CodeDiff...")

-- Load vscode-diff plugin manually
pcall(dofile, vim.fn.getcwd() .. '/plugin/vscode-diff.lua')

local has_codediff = vim.fn.exists(':CodeDiff') ~= 0

if not has_codediff then
  print("  ⚠️  vscode-diff.nvim not available, skipping CodeDiff")
else
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  local start = vim.loop.hrtime()
  local success = pcall(vim.cmd, { cmd = 'CodeDiff', args = { revision } })
  if success then
    wait_for_render()
    codediff_time = (vim.loop.hrtime() - start) / 1000000
    print(string.format("  CodeDiff: %.2f ms", codediff_time))
  else
    print("  ❌ CodeDiff failed")
  end
  pcall(vim.cmd, { cmd = 'tabclose' })
  pcall(vim.cmd, { cmd = 'bwipeout', bang = true })
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
