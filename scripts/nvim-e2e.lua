-- Neovim headless E2E runner for codediff plugin
-- Runs scenario scripts that simulate full user workflows
--
-- Usage:
--   nvim --headless -u tests/init.lua -c "lua dofile('scripts/nvim-e2e.lua').run('path/to/scenario.lua')" -c "qa!"
--
-- Or with inline scenario:
--   SCENARIO_FILE=/tmp/scenario.lua nvim --headless -u tests/init.lua -c "luafile scripts/nvim-e2e.lua" -c "qa!"

local M = {}

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

local function print_separator(title)
  print(string.rep("=", 60))
  print(title)
  print(string.rep("=", 60))
end

local function print_result(success, msg)
  if success then
    print("✓ PASS: " .. msg)
  else
    print("✗ FAIL: " .. msg)
  end
end

-------------------------------------------------------------------------------
-- Git Repository Helpers
-------------------------------------------------------------------------------

function M.create_temp_git_repo()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  local function git(args)
    local cmd = string.format('git -C "%s" %s', temp_dir, args)
    local output = vim.fn.system(cmd)
    return output, vim.v.shell_error
  end

  git("init")
  git("config user.email 'test@test.com'")
  git("config user.name 'Test'")
  git("branch -m main")

  -- Get canonical path from git
  local output = git("rev-parse --show-toplevel")
  if output then
    local canonical = vim.trim(output)
    if canonical and canonical ~= '' then
      temp_dir = canonical
    end
  end

  return {
    dir = temp_dir,
    git = git,
    write_file = function(rel_path, lines)
      local full_path = temp_dir .. "/" .. rel_path
      local parent = vim.fn.fnamemodify(full_path, ":h")
      vim.fn.mkdir(parent, "p")
      vim.fn.writefile(lines, full_path)
      return full_path
    end,
    read_file = function(rel_path)
      local full_path = temp_dir .. "/" .. rel_path
      if vim.fn.filereadable(full_path) == 1 then
        return vim.fn.readfile(full_path)
      end
      return nil
    end,
    path = function(rel_path)
      return temp_dir .. "/" .. rel_path
    end,
    cleanup = function()
      vim.fn.delete(temp_dir, "rf")
    end
  }
end

-------------------------------------------------------------------------------
-- Waiting Helpers
-------------------------------------------------------------------------------

function M.wait(timeout_ms, condition_fn, interval_ms)
  timeout_ms = timeout_ms or 5000
  interval_ms = interval_ms or 50
  if condition_fn then
    return vim.wait(timeout_ms, condition_fn, interval_ms)
  else
    vim.wait(timeout_ms)
    return true
  end
end

function M.wait_for_new_tab(timeout_ms)
  timeout_ms = timeout_ms or 5000
  local initial_tabs = vim.fn.tabpagenr('$')
  return vim.wait(timeout_ms, function()
    return vim.fn.tabpagenr('$') > initial_tabs
  end, 50)
end

function M.wait_for_explorer(timeout_ms)
  timeout_ms = timeout_ms or 5000
  return vim.wait(timeout_ms, function()
    return M.find_window_by_filetype("codediff-explorer") ~= nil
  end, 50)
end

function M.wait_for_diff_ready(timeout_ms)
  timeout_ms = timeout_ms or 10000
  local lifecycle = require('codediff.ui.lifecycle')
  local tabpage = vim.api.nvim_get_current_tabpage()

  return vim.wait(timeout_ms, function()
    local session = lifecycle.get_session(tabpage)
    if not session then return false end
    if not session.stored_diff_result then return false end

    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    if not orig_buf or not mod_buf then return false end

    return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
  end, 100)
end

function M.wait_for_buffer_content(bufnr, expected_text, timeout_ms)
  timeout_ms = timeout_ms or 5000
  return vim.wait(timeout_ms, function()
    local content = M.get_buffer_content(bufnr)
    return content and content:find(expected_text, 1, true) ~= nil
  end, 50)
end

-------------------------------------------------------------------------------
-- Window and Buffer Helpers
-------------------------------------------------------------------------------

function M.find_window_by_filetype(filetype)
  for i = 1, vim.fn.winnr('$') do
    local winid = vim.fn.win_getid(i)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].filetype == filetype then
      return winid, bufnr
    end
  end
  return nil, nil
end

function M.get_all_windows()
  local windows = {}
  for i = 1, vim.fn.winnr('$') do
    local winid = vim.fn.win_getid(i)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    table.insert(windows, {
      winid = winid,
      bufnr = bufnr,
      filetype = vim.bo[bufnr].filetype,
      bufname = vim.api.nvim_buf_get_name(bufnr),
    })
  end
  return windows
end

function M.focus_window(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
    return true
  end
  return false
end

function M.focus_explorer()
  local winid = M.find_window_by_filetype("codediff-explorer")
  return M.focus_window(winid)
end

function M.get_buffer_content(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

function M.get_buffer_lines(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.get_cursor_position()
  local pos = vim.api.nvim_win_get_cursor(0)
  return { line = pos[1], col = pos[2] }
end

function M.set_cursor_position(line, col)
  vim.api.nvim_win_set_cursor(0, {line, col or 0})
end

-------------------------------------------------------------------------------
-- Diff Session Helpers
-------------------------------------------------------------------------------

function M.get_diff_buffers()
  local lifecycle = require('codediff.ui.lifecycle')
  local tabpage = vim.api.nvim_get_current_tabpage()
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  return orig_buf, mod_buf
end

function M.get_diff_session()
  local lifecycle = require('codediff.ui.lifecycle')
  local tabpage = vim.api.nvim_get_current_tabpage()
  return lifecycle.get_session(tabpage)
end

function M.get_original_content()
  local orig_buf, _ = M.get_diff_buffers()
  return M.get_buffer_content(orig_buf)
end

function M.get_modified_content()
  local _, mod_buf = M.get_diff_buffers()
  return M.get_buffer_content(mod_buf)
end

-------------------------------------------------------------------------------
-- Explorer Helpers
-------------------------------------------------------------------------------

function M.get_explorer_files()
  local winid, bufnr = M.find_window_by_filetype("codediff-explorer")
  if not bufnr then return nil end
  return M.get_buffer_lines(bufnr)
end

function M.select_explorer_item(line_number)
  local winid = M.find_window_by_filetype("codediff-explorer")
  if not winid then return false end

  M.focus_window(winid)
  M.set_cursor_position(line_number)
  M.feedkeys("<CR>")
  return true
end

-------------------------------------------------------------------------------
-- Command and Keymap Helpers
-------------------------------------------------------------------------------

function M.exec(cmd)
  local ok, err = pcall(vim.cmd, cmd)
  return ok, err
end

function M.feedkeys(keys, mode)
  mode = mode or "n"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), mode, false)
  vim.wait(100)
end

-- Execute keymap with wait for result
function M.press(keys, wait_ms)
  M.feedkeys(keys)
  if wait_ms then
    M.wait(wait_ms)
  end
end

-- Navigation keymaps (using plugin defaults)
function M.next_hunk() M.feedkeys("]c") end
function M.prev_hunk() M.feedkeys("[c") end
function M.next_file() M.feedkeys("]f") end
function M.prev_file() M.feedkeys("[f") end
function M.toggle_stage() M.feedkeys("-") end
function M.toggle_explorer() M.feedkeys("<leader>b") end
function M.quit_diff() M.feedkeys("q") end

-- Conflict keymaps
function M.accept_incoming() M.feedkeys("<leader>ct") end
function M.accept_current() M.feedkeys("<leader>co") end
function M.accept_both() M.feedkeys("<leader>cb") end
function M.next_conflict() M.feedkeys("]x") end
function M.prev_conflict() M.feedkeys("[x") end

-- Diff get/put
function M.diff_get() M.feedkeys("do") end
function M.diff_put() M.feedkeys("dp") end

-------------------------------------------------------------------------------
-- Git Status Helpers
-------------------------------------------------------------------------------

function M.get_git_status(repo_dir)
  local git = require('codediff.core.git')
  local result = nil
  local done = false

  git.get_status(repo_dir, function(err, status)
    if not err then
      result = status
    end
    done = true
  end)

  M.wait(3000, function() return done end)
  return result
end

function M.is_file_staged(repo_dir, filename)
  local status = M.get_git_status(repo_dir)
  if not status or not status.staged then return false end

  for _, file in ipairs(status.staged) do
    if file.path == filename or file.path:match(filename .. "$") then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- View API Helpers
-------------------------------------------------------------------------------

function M.create_diff_view(config)
  local view = require('codediff.ui.view')
  return view.create(config)
end

function M.update_diff_view(config)
  local view = require('codediff.ui.view')
  local tabpage = vim.api.nvim_get_current_tabpage()
  view.update(tabpage, config, false)
  return M.wait_for_diff_ready(5000)
end

-------------------------------------------------------------------------------
-- Assertion Helpers
-------------------------------------------------------------------------------

function M.assert_contains(str, substr, msg)
  local found = str and str:find(substr, 1, true) ~= nil
  if not found then
    print("ASSERT FAILED: " .. (msg or "Expected content not found"))
    print("  Looking for: " .. substr)
    print("  In: " .. (str and str:sub(1, 200) or "nil"))
  end
  return found
end

function M.assert_equals(expected, actual, msg)
  if expected ~= actual then
    print("ASSERT FAILED: " .. (msg or "Values not equal"))
    print("  Expected: " .. vim.inspect(expected))
    print("  Actual: " .. vim.inspect(actual))
    return false
  end
  return true
end

function M.assert_true(value, msg)
  if not value then
    print("ASSERT FAILED: " .. (msg or "Expected true"))
    return false
  end
  return true
end

-------------------------------------------------------------------------------
-- Setup and Cleanup
-------------------------------------------------------------------------------

function M.setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function() return { "file", "install" } end,
  })
end

function M.cleanup_tabs()
  vim.cmd("tabnew")
  vim.cmd("tabonly")
  vim.wait(200)
end

-------------------------------------------------------------------------------
-- Scenario Runner
-------------------------------------------------------------------------------

function M.run(scenario_path)
  print_separator("E2E Runner: " .. scenario_path)

  M.setup_command()

  local ok, scenario = pcall(dofile, scenario_path)
  if not ok then
    print("ERROR: Failed to load scenario: " .. tostring(scenario))
    return false
  end

  if type(scenario) ~= "table" then
    print("ERROR: Scenario must return a table with setup/run/validate functions")
    return false
  end

  local ctx = {}
  local success = true

  -- Phase 1: Setup
  if scenario.setup then
    print_separator("Phase: Setup")
    local setup_ok, setup_err = pcall(scenario.setup, ctx, M)
    if not setup_ok then
      print_result(false, "Setup failed: " .. tostring(setup_err))
      success = false
    else
      print_result(true, "Setup complete")
    end
  end

  -- Phase 2: Run
  if success and scenario.run then
    print_separator("Phase: Run")
    local run_ok, run_err = pcall(scenario.run, ctx, M)
    if not run_ok then
      print_result(false, "Run failed: " .. tostring(run_err))
      success = false
    else
      print_result(true, "Run complete")
    end
  end

  -- Phase 3: Validate
  if success and scenario.validate then
    print_separator("Phase: Validate")
    local validate_ok, validate_result = pcall(scenario.validate, ctx, M)
    if not validate_ok then
      print_result(false, "Validate error: " .. tostring(validate_result))
      success = false
    elseif validate_result == false then
      print_result(false, "Validation failed")
      success = false
    else
      print_result(true, "Validation passed")
    end
  end

  -- Phase 4: Cleanup
  if scenario.cleanup then
    print_separator("Phase: Cleanup")
    pcall(scenario.cleanup, ctx, M)
  end
  M.cleanup_tabs()

  print_separator("Result: " .. (success and "SUCCESS" or "FAILURE"))
  return success
end

-- Auto-run if SCENARIO_FILE env var is set
local scenario_file = vim.env.SCENARIO_FILE
if scenario_file and scenario_file ~= "" then
  local success = M.run(scenario_file)
  if not success then
    vim.cmd("cquit 1")
  end
end

return M
