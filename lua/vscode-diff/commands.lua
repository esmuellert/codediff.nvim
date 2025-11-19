-- Command implementations for vscode-diff
local M = {}

local git = require("vscode-diff.git")

--- Handles diffing the current buffer against a given git revision.
-- @param revision string: The git revision (e.g., "HEAD", commit hash, branch name) to compare the current file against.
-- This function chains async git operations to get git root, resolve revision to hash, and get file content.
local function handle_git_diff(revision)
  local current_file = vim.api.nvim_buf_get_name(0)

  if current_file == "" then
    vim.notify("Current buffer is not a file", vim.log.levels.ERROR)
    return
  end

  -- Determine filetype from current buffer (sync operation, no git involved)
  local filetype = vim.bo[0].filetype
  if not filetype or filetype == "" then
    filetype = vim.filetype.match({ filename = current_file }) or ""
  end

  -- Async chain: get_git_root -> resolve_revision -> get_file_content -> render_diff
  git.get_git_root(current_file, function(err_root, git_root)
    if err_root then
      vim.schedule(function()
        vim.notify(err_root, vim.log.levels.ERROR)
      end)
      return
    end

    local relative_path = git.get_relative_path(current_file, git_root)

    git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      -- Create diff view (no pre-fetching needed, buffers will load content)
      vim.schedule(function()
        local view = require('vscode-diff.render.view')
        ---@type SessionConfig
        local session_config = {
          mode = "standalone",
          git_root = git_root,
          original_path = relative_path,
          modified_path = relative_path,
          original_revision = commit_hash,
          modified_revision = "WORKING",
        }
        view.create(session_config, filetype)
      end)
    end)
  end)
end

local function handle_file_diff(file_a, file_b)
  -- Determine filetype from first file
  local filetype = vim.filetype.match({ filename = file_a }) or ""

  -- Create diff view (no pre-reading needed, :edit will load content)
  local view = require('vscode-diff.render.view')
  ---@type SessionConfig
  local session_config = {
    mode = "standalone",
    git_root = nil,
    original_path = file_a,
    modified_path = file_b,
    original_revision = nil,
    modified_revision = nil,
  }
  view.create(session_config, filetype)
end

local function handle_explorer()
  -- Use current buffer's directory if available, otherwise use cwd
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local check_path = current_file ~= "" and current_file or vim.fn.getcwd()

  -- Check if in git repository
  git.get_git_root(check_path, function(err_root, git_root)
    if err_root then
      vim.schedule(function()
        vim.notify(err_root, vim.log.levels.ERROR)
      end)
      return
    end

    -- Get git status
    git.get_status(git_root, function(err_status, status_result)
      vim.schedule(function()
        if err_status then
          vim.notify(err_status, vim.log.levels.ERROR)
          return
        end

        -- Check if there are any changes
        if #status_result.unstaged == 0 and #status_result.staged == 0 then
          vim.notify("No changes to show", vim.log.levels.INFO)
          return
        end

        -- Create explorer view with empty diff panes initially
        local view = require('vscode-diff.render.view')
        
        ---@type SessionConfig
        local session_config = {
          mode = "explorer",
          git_root = git_root,
          original_path = "",  -- Empty indicates explorer mode placeholder
          modified_path = "",
          original_revision = nil,
          modified_revision = nil,
          explorer_data = {
            status_result = status_result,
          }
        }
        
        -- view.create handles everything: tab, windows, explorer, and lifecycle
        -- Empty lines and paths - explorer will populate via first file selection
        view.create(session_config, "")
      end)
    end)
  end)
end

function M.vscode_diff(opts)
  local args = opts.fargs

  if #args == 0 then
    -- :CodeDiff without arguments opens explorer mode
    handle_explorer()
    return
  end

  local subcommand = args[1]

  if subcommand == "file" then
    if #args == 2 then
      -- :CodeDiff file HEAD
      handle_git_diff(args[2])
    elseif #args == 3 then
      -- :CodeDiff file file_a.txt file_b.txt
      handle_file_diff(args[2], args[3])
    else
      vim.notify("Usage: :CodeDiff file <revision> OR :CodeDiff file <file_a> <file_b>", vim.log.levels.ERROR)
    end
  elseif subcommand == "install" or subcommand == "install!" then
    -- :CodeDiff install or :CodeDiff install!
    -- Handle both :CodeDiff! install and :CodeDiff install!
    local force = opts.bang or subcommand == "install!"
    local installer = require("vscode-diff.installer")
    
    if force then
      vim.notify("Reinstalling libvscode-diff...", vim.log.levels.INFO)
    end
    
    local success, err = installer.install({ force = force, silent = false })
    
    if success then
      vim.notify("libvscode-diff installation successful!", vim.log.levels.INFO)
    else
      vim.notify("Installation failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
  else
    vim.notify("Unknown command: " .. subcommand, vim.log.levels.ERROR)
  end
end

return M
