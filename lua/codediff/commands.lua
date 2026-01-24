-- Command implementations for vscode-diff
local M = {}

-- Subcommands available for :CodeDiff
M.SUBCOMMANDS = { "merge", "file", "dir", "history", "install" }

local git = require("codediff.core.git")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

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
            local view = require("codediff.ui.view")
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
          local view = require("codediff.ui.view")
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
  local view = require("codediff.ui.view")
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

local function handle_dir_diff(dir1, dir2)
  local dir_mod = require("codediff.core.dir")

  -- Expand ~ and environment variables in paths
  dir1 = vim.fn.expand(dir1)
  dir2 = vim.fn.expand(dir2)

  if vim.fn.isdirectory(dir1) == 0 then
    vim.notify("Not a directory: " .. dir1, vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(dir2) == 0 then
    vim.notify("Not a directory: " .. dir2, vim.log.levels.ERROR)
    return
  end

  local diff = dir_mod.diff_directories(dir1, dir2)
  local status_result = diff.status_result

  if #status_result.unstaged == 0 and #status_result.staged == 0 then
    vim.notify("No differences between directories", vim.log.levels.INFO)
    return
  end

  local view = require("codediff.ui.view")

  ---@type SessionConfig
  local session_config = {
    mode = "explorer",
    git_root = nil, -- nil signals non-git (directory) mode
    original_path = diff.root1,
    modified_path = diff.root2,
    original_revision = nil,
    modified_revision = nil,
    explorer_data = {
      status_result = status_result,
    },
  }

  view.create(session_config, "")
end

-- Handle file history command
-- range: git range (e.g., "origin/main..HEAD", "HEAD~10")
-- file_path: optional file path to filter history
local function handle_history(range, file_path)
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local cwd = vim.fn.getcwd()

  -- Expand file_path before async context (vim.fn.expand can't be called in fast event)
  local expanded_file_path = nil
  if file_path then
    expanded_file_path = vim.fn.expand(file_path)
    if vim.fn.filereadable(expanded_file_path) ~= 1 then
      expanded_file_path = file_path
    end
  end

  local function open_history(git_root)
    -- Build options for commit list
    local history_opts = {
      no_merges = true,
    }

    -- Only apply default limit when no range specified
    if not range or range == "" then
      history_opts.limit = 100
    end

    -- If file_path specified, filter by that file
    if expanded_file_path then
      history_opts.path = git.get_relative_path(expanded_file_path, git_root)
    end

    git.get_commit_list(range or "", git_root, history_opts, function(err, commits)
      if err then
        vim.schedule(function()
          vim.notify("Failed to get commit history: " .. err, vim.log.levels.ERROR)
        end)
        return
      end

      if #commits == 0 then
        vim.schedule(function()
          vim.notify("No commits found in range", vim.log.levels.INFO)
        end)
        return
      end

      vim.schedule(function()
        local view = require("codediff.ui.view")

        ---@type SessionConfig
        local session_config = {
          mode = "history",
          git_root = git_root,
          original_path = "",
          modified_path = "",
          original_revision = nil,
          modified_revision = nil,
          history_data = {
            commits = commits,
            range = range,
            file_path = history_opts.path,
          },
        }

        view.create(session_config, "")
      end)
    end)
  end

  -- Try buffer path first if available
  if current_file ~= "" then
    git.get_git_root(current_file, function(err_file, git_root_file)
      if not err_file then
        open_history(git_root_file)
        return
      end

      git.get_git_root(cwd, function(err_cwd, git_root_cwd)
        if not err_cwd then
          open_history(git_root_cwd)
          return
        end
        vim.schedule(function()
          vim.notify("Not in a git repository", vim.log.levels.ERROR)
        end)
      end)
    end)
  else
    git.get_git_root(cwd, function(err_cwd, git_root)
      if err_cwd then
        vim.schedule(function()
          vim.notify(err_cwd, vim.log.levels.ERROR)
        end)
        return
      end
      open_history(git_root)
    end)
  end
end

local function handle_explorer(revision, revision2)
  -- Try buffer path first (consistent with original behavior), fallback to cwd
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local cwd = vim.fn.getcwd()

  local function open_explorer(git_root)
    -- Compute focus_file (relative path to current buffer) for focusing in explorer
    local focus_file = nil
    if current_file ~= "" then
      focus_file = git.get_relative_path(current_file, git_root)
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
        local view = require("codediff.ui.view")

        ---@type SessionConfig
        local session_config = {
          mode = "explorer",
          git_root = git_root,
          original_path = "", -- Empty indicates explorer mode placeholder
          modified_path = "",
          original_revision = original_rev,
          modified_revision = modified_rev,
          explorer_data = {
            status_result = status_result,
            focus_file = focus_file, -- Focus on current file if changed
          },
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
  end

  -- Try buffer path first if available
  if current_file ~= "" then
    git.get_git_root(current_file, function(err_file, git_root_file)
      if not err_file then
        open_explorer(git_root_file)
        return
      end

      -- Buffer path failed, try cwd as fallback
      git.get_git_root(cwd, function(err_cwd, git_root_cwd)
        if not err_cwd then
          open_explorer(git_root_cwd)
          return
        end
        -- Both failed
        vim.schedule(function()
          vim.notify("Not in a git repository", vim.log.levels.ERROR)
        end)
      end)
    end)
  else
    -- No buffer, try cwd directly
    git.get_git_root(cwd, function(err_cwd, git_root)
      if err_cwd then
        vim.schedule(function()
          vim.notify(err_cwd, vim.log.levels.ERROR)
        end)
        return
      end
      open_explorer(git_root)
    end)
  end
end

function M.vscode_merge(opts)
  local args = opts.fargs
  if #args == 0 then
    vim.notify("Usage: :CodeDiff merge <filename>", vim.log.levels.ERROR)
    return
  end

  local filename = args[1]
  -- Strip surrounding quotes if present (from shell escaping in git mergetool)
  filename = filename:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")

  -- Resolve to absolute path
  local full_path = vim.fn.fnamemodify(filename, ":p")

  if vim.fn.filereadable(full_path) == 0 then
    vim.notify("File not found: " .. filename, vim.log.levels.ERROR)
    return
  end

  -- Ensure all required modules are loaded before we start vim.wait
  -- This prevents issues with lazy-loading during the wait loop
  local view = require("codediff.ui.view")

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

      -- Determine conflict buffer positions based on config
      -- conflict_ours_position controls where :2 (OURS) appears on screen
      local ours_position = config.options.diff.conflict_ours_position or "right"

      -- After conflict_window.lua's win_splitmove(rightbelow=false):
      -- - original_win is on LEFT
      -- - modified_win is on RIGHT
      local original_rev, modified_rev
      if ours_position == "right" then
        original_rev = ":3" -- THEIRS in original_win (LEFT)
        modified_rev = ":2" -- OURS in modified_win (RIGHT)
      else
        original_rev = ":2" -- OURS in original_win (LEFT)
        modified_rev = ":3" -- THEIRS in modified_win (RIGHT)
      end

      ---@type SessionConfig
      local session_config = {
        mode = "standalone",
        git_root = git_root,
        original_path = relative_path,
        modified_path = relative_path,
        original_revision = original_rev,
        modified_revision = modified_rev,
        conflict = true,
      }

      view.create(session_config, filetype, function()
        view_ready = true
      end)
    end)
  end)

  -- Block until view is ready - this allows event loop to process callbacks
  vim.wait(10000, function()
    return view_ready
  end, 10)

  -- Force screen redraw after vim.wait to ensure all windows are visible
  vim.cmd("redraw!")

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
      return -- User cancelled
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

  -- Auto-detect two directory arguments: :CodeDiff dir1 dir2
  if #args == 2 then
    local expanded1 = vim.fn.expand(args[1])
    local expanded2 = vim.fn.expand(args[2])
    if vim.fn.isdirectory(expanded1) == 1 and vim.fn.isdirectory(expanded2) == 1 then
      handle_dir_diff(expanded1, expanded2)
      return
    end
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
  elseif subcommand == "dir" then
    -- :CodeDiff dir dir1 dir2
    if #args ~= 3 then
      vim.notify("Usage: :CodeDiff dir <dir1> <dir2>", vim.log.levels.ERROR)
      return
    end
    handle_dir_diff(args[2], args[3])
  elseif subcommand == "history" then
    -- :CodeDiff history [range] [file]
    -- Examples:
    --   :CodeDiff history                    - last 100 commits
    --   :CodeDiff history HEAD~10            - last 10 commits
    --   :CodeDiff history origin/main..HEAD  - commits in range
    --   :CodeDiff history HEAD~10 %          - last 10 commits for current file
    --   :CodeDiff history %                  - history for current file
    --   :CodeDiff history path/to/file.lua   - history for specific file
    local arg1 = args[2]
    local arg2 = args[3]
    local range = nil
    local file_path = nil

    -- Helper to expand path (handles % and normal paths)
    local function expand_path(p)
      if p == "%" then
        return vim.api.nvim_buf_get_name(0)
      else
        return vim.fn.expand(p)
      end
    end

    if arg1 and arg2 then
      -- Two params: first is range, second is file_path
      range = arg1
      file_path = expand_path(arg2)
    elseif arg1 then
      -- One param: try as file_path first, otherwise treat as range
      local expanded = expand_path(arg1)
      if vim.fn.filereadable(expanded) == 1 then
        file_path = expanded
      else
        range = arg1
      end
    end

    handle_history(range, file_path)
  elseif subcommand == "install" or subcommand == "install!" then
    -- :CodeDiff install or :CodeDiff install!
    -- Handle both :CodeDiff! install and :CodeDiff install!
    local force = opts.bang or subcommand == "install!"
    local installer = require("codediff.core.installer")

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
