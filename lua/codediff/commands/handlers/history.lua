-- :CodeDiff history -- the commit list, for the repo or one file.
local M = {}

local git = require("codediff.core.git")
local view = require("codediff.ui.view")
local path = require("codediff.core.path")
local parse = require("codediff.commands.parse")

-- Handle file history command
-- range: git range (e.g., "origin/main..HEAD", "HEAD~10")
-- file_path: optional file path to filter history
-- line_range: optional {start, end} for line-range history (git log -L)
function M.run(range, file_path, flags, line_range, global_opts)
  flags = flags or {} -- Default to empty table for backward compat

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

    -- Apply reverse flag if present
    if flags.reverse then
      history_opts.reverse = true
    end

    -- Only apply default limit when no range specified
    if not range or range == "" then
      history_opts.limit = 100
    end

    -- If file_path specified, filter by that file
    if expanded_file_path then
      history_opts.path = git.get_relative_path(expanded_file_path, git_root)
    end

    -- If line range specified, set up for git log -L
    if line_range and history_opts.path then
      history_opts.line_range = line_range
    end

    git.get_commit_list(range or "", git_root, history_opts, function(err, commits)
      if parse.failed(err, function(e)
        return "Failed to get commit history: " .. e
      end) then
        return
      end

      if #commits == 0 then
        vim.schedule(function()
          vim.notify("No commits found in range", vim.log.levels.INFO)
        end)
        return
      end

      vim.schedule(function()
        ---@type SessionConfig
        local session_config = {
          panel = {
            name = "history",
            data = {
              commits = commits,
              range = range,
              file_path = history_opts.path,
              base_revision = flags.base,
              line_range = line_range,
              reverse = flags.reverse,
            },
          },
          git_root = git_root,
          original = path.empty(),
          modified = path.empty(),
          original_revision = nil,
          modified_revision = nil,
          layout = global_opts.layout,
          exit_on_close = global_opts.exit_on_close,
        }

        view.create(session_config, "")
      end)
    end)
  end

  -- Resolve the working repo (honors --repo/-C) and open the history view.
  parse.resolve_working_root(global_opts, open_history)
end

return M
