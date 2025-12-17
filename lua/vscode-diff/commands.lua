-- Command implementations for vscode-diff
local M = {}

-- Subcommands available for :CodeDiff
M.SUBCOMMANDS = { "merge", "file", "install" }

local git = require("vscode-diff.git")
local lifecycle = require("vscode-diff.render.lifecycle")

--- Handles diffing the current buffer against a given git revision.
-- @param revision string: The git revision (e.g., "HEAD", commit hash, branch name) to compare the current file against.
-- @param revision2 string?: Optional second revision. If provided, compares revision vs revision2.
-- This function chains async git operations to get git root, resolve revision to hash, and get file content.
local function handle_git_diff(revision, revision2)
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

      if revision2 then
        -- Compare two revisions
        git.resolve_revision(revision2, git_root, function(err_resolve2, commit_hash2)
          if err_resolve2 then
            vim.schedule(function()
              vim.notify(err_resolve2, vim.log.levels.ERROR)
            end)
            return
          end

          vim.schedule(function()
            local view = require('vscode-diff.render.view')
            ---@type SessionConfig
            local session_config = {
              mode = "standalone",
              git_root = git_root,
              original_path = relative_path,
              modified_path = relative_path,
              original_revision = commit_hash,
              modified_revision = commit_hash2,
            }
            view.create(session_config, filetype)
          end)
        end)
      else
        -- Compare revision vs working tree
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
      end
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

local function handle_explorer(revision, revision2)
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

    local function process_status(err_status, status_result, original_rev, modified_rev)
      vim.schedule(function()
        if err_status then
          vim.notify(err_status, vim.log.levels.ERROR)
          return
        end

        -- Check if there are any changes (including conflicts)
        local has_conflicts = status_result.conflicts and #status_result.conflicts > 0
        if #status_result.unstaged == 0 and #status_result.staged == 0 and not has_conflicts then
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
          original_revision = original_rev,
          modified_revision = modified_rev,
          explorer_data = {
            status_result = status_result,
          }
        }

        -- view.create handles everything: tab, windows, explorer, and lifecycle
        -- Empty lines and paths - explorer will populate via first file selection
        view.create(session_config, "")
      end)
    end

    if revision and revision2 then
      -- Compare two revisions
      git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
        if err_resolve then
          vim.schedule(function()
            vim.notify(err_resolve, vim.log.levels.ERROR)
          end)
          return
        end

        git.resolve_revision(revision2, git_root, function(err_resolve2, commit_hash2)
          if err_resolve2 then
            vim.schedule(function()
              vim.notify(err_resolve2, vim.log.levels.ERROR)
            end)
            return
          end

          git.get_diff_revisions(commit_hash, commit_hash2, git_root, function(err_status, status_result)
            process_status(err_status, status_result, commit_hash, commit_hash2)
          end)
        end)
      end)
    elseif revision then
      -- Resolve revision first, then get diff
      git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
        if err_resolve then
          vim.schedule(function()
            vim.notify(err_resolve, vim.log.levels.ERROR)
          end)
          return
        end

        -- Get diff between revision and working tree
        git.get_diff_revision(commit_hash, git_root, function(err_status, status_result)
          process_status(err_status, status_result, commit_hash, "WORKING")
        end)
      end)
    else
      -- Get git status (current changes)
      git.get_status(git_root, function(err_status, status_result)
        -- Pass nil for revisions to enable "Status Mode" in explorer (separate Staged/Unstaged groups)
        process_status(err_status, status_result, nil, nil)
      end)
    end
  end)
end

function M.vscode_merge(opts)
  local args = opts.fargs
  if #args == 0 then
    vim.notify("Usage: :CodeDiff merge <filename>", vim.log.levels.ERROR)
    return
  end

  local filename = args[1]
  -- Strip surrounding quotes if present (from shell escaping in git mergetool)
  filename = filename:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
  
  -- Resolve to absolute path
  local full_path = vim.fn.fnamemodify(filename, ":p")
  
  if vim.fn.filereadable(full_path) == 0 then
    vim.notify("File not found: " .. filename, vim.log.levels.ERROR)
    return
  end

  -- Ensure all required modules are loaded before we start vim.wait
  -- This prevents issues with lazy-loading during the wait loop
  local view = require('vscode-diff.render.view')
  
  -- For synchronous execution (required by git mergetool), we need to block
  -- until the view is ready. Use vim.wait which processes the event loop.
  local view_ready = false
  local error_msg = nil

  git.get_git_root(full_path, function(err_root, git_root)
    if err_root then
      error_msg = "Not a git repository: " .. err_root
      view_ready = true
      return
    end

    local relative_path = git.get_relative_path(full_path, git_root)
    
    -- Schedule everything that needs main thread (vim.filetype.match, view.create)
    vim.schedule(function()
      local filetype = vim.filetype.match({ filename = full_path }) or ""

      ---@type SessionConfig
      local session_config = {
        mode = "standalone",
        git_root = git_root,
        original_path = relative_path,
        modified_path = relative_path,
        original_revision = ":3",
        modified_revision = ":2",
        conflict = true,
      }
      
      view.create(session_config, filetype, function()
        view_ready = true
      end)
    end)
  end)

  -- Block until view is ready - this allows event loop to process callbacks
  vim.wait(10000, function() return view_ready end, 10)
  
  -- Force screen redraw after vim.wait to ensure all windows are visible
  vim.cmd('redraw!')
  
  if error_msg then
    vim.notify(error_msg, vim.log.levels.ERROR)
  end
end

function M.vscode_diff(opts)
  -- Check if current tab is a diff view and toggle (close) it if so
  local current_tab = vim.api.nvim_get_current_tabpage()
  if lifecycle.get_session(current_tab) then
    -- Check for unsaved conflict files before closing
    if not lifecycle.confirm_close_with_unsaved(current_tab) then
      return  -- User cancelled
    end
    vim.cmd("tabclose")
    return
  end

  local args = opts.fargs

  if #args == 0 then
    -- :CodeDiff without arguments opens explorer mode
    handle_explorer()
    return
  end

  local subcommand = args[1]

  if subcommand == "merge" then
    -- :CodeDiff merge <filename> - Merge Tool Mode
    if #args ~= 2 then
      vim.notify("Usage: :CodeDiff merge <filename>", vim.log.levels.ERROR)
      return
    end
    M.vscode_merge({ fargs = { args[2] } })
  elseif subcommand == "file" then
    if #args == 2 then
      -- :CodeDiff file HEAD
      handle_git_diff(args[2])
    elseif #args == 3 then
      -- Check if arguments are files or revisions
      local arg1 = args[2]
      local arg2 = args[3]
      
      -- If both are readable files, treat as file diff
      if vim.fn.filereadable(arg1) == 1 and vim.fn.filereadable(arg2) == 1 then
        -- :CodeDiff file file_a.txt file_b.txt
        handle_file_diff(arg1, arg2)
      else
        -- Assume revisions: :CodeDiff file main HEAD
        handle_git_diff(arg1, arg2)
      end
    else
      vim.notify("Usage: :CodeDiff file <revision> [revision2] OR :CodeDiff file <file_a> <file_b>", vim.log.levels.ERROR)
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
    -- :CodeDiff <revision> [revision2] - opens explorer mode
    if #args == 2 then
       handle_explorer(args[1], args[2])
    else
       handle_explorer(subcommand)
    end
  end
end

return M
