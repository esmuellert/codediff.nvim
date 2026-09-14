-- :CodeDiff -- the changed-file explorer.
local M = {}

local git = require("codediff.core.git")
local view = require("codediff.ui.view")
local path = require("codediff.core.path")
local parse = require("codediff.commands.parse")

function M.run(revision, revision2, global_opts, pathspec)
  local current_file = vim.api.nvim_buf_get_name(0)

  local function open_explorer(git_root, is_override)
    -- Compute focus_file (relative path to current buffer) for focusing in explorer.
    -- Skip when --repo/-C targets a different repo: the current buffer isn't in it.
    local focus_file = nil
    if current_file ~= "" and not is_override then
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

        ---@type SessionConfig
        local session_config = {
          panel = {
            name = "explorer",
            data = {
              status_result = status_result,
              focus_file = focus_file, -- Focus on current file if changed
              pathspec = pathspec, -- Scope (#74): preserved so refresh re-applies it
              source_revisions = revision and { original = revision, modified = revision2 or "WORKING" } or nil,
            },
          },
          git_root = git_root,
          original = path.empty(), -- Empty indicates explorer mode placeholder
          modified = path.empty(),
          original_revision = original_rev,
          modified_revision = modified_rev,
          layout = global_opts.layout,
          exit_on_close = global_opts.exit_on_close,
        }

        -- view.create handles everything: tab, windows, explorer, and lifecycle
        -- Empty lines and paths - explorer will populate via first file selection
        view.create(session_config, "")
      end)
    end

    if revision and revision2 then
      -- Compare two revisions
      git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
        if parse.failed(err_resolve) then
          return
        end

        git.resolve_revision(revision2, git_root, function(err_resolve2, commit_hash2)
          if parse.failed(err_resolve2) then
            return
          end

          git.get_diff_revisions_with_line_stats(commit_hash, commit_hash2, git_root, function(err_status, status_result)
            process_status(err_status, status_result, commit_hash, commit_hash2)
          end, pathspec)
        end)
      end)
    elseif revision then
      -- Resolve revision first, then get diff
      git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
        if parse.failed(err_resolve) then
          return
        end

        -- Get diff between revision and working tree
        git.get_diff_revision_with_line_stats(commit_hash, git_root, function(err_status, status_result)
          process_status(err_status, status_result, commit_hash, "WORKING")
        end, pathspec)
      end)
    else
      -- Get git status (current changes)
      git.get_status_with_line_stats(git_root, function(err_status, status_result)
        -- Pass nil for revisions to enable "Status Mode" in explorer (separate Staged/Unstaged groups)
        process_status(err_status, status_result, nil, nil)
      end, pathspec)
    end
  end

  -- Resolve the working repo (honors --repo/-C) and open the explorer.
  parse.resolve_working_root(global_opts, open_explorer)
end

-- Handle explorer for staged-only view (--staged / --cached flag).
-- Matches diffview.nvim's `--staged`: compare the index against the given
-- revision (defaulting to HEAD). Only files whose index differs from that
-- revision are shown; opening a file diffs `<revision>` vs `:0` (the index).
--
-- revision: git revision to compare the index against (nil defaults to "HEAD")
-- global_opts: layout / exit_on_close / repo overrides
-- pathspec: optional trailing pathspec (#74)

-- Wrapper for merge-base explorer mode: computes merge-base first, then opens explorer
function M.run_merge_base(base_rev, target_rev, global_opts, pathspec)
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local cwd = vim.fn.getcwd()
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = current_buf })
  -- A file usually has a buftype of "" so filter out `nofile` or dashboards etc.
  -- --repo/-C overrides the seed so the merge base is computed in that repo.
  local path_for_root = (global_opts and global_opts.repo) or (buftype == "" and current_file ~= "" and current_file or cwd)

  git.get_git_root(path_for_root, function(err_root, git_root)
    if parse.failed(err_root) then
      return
    end

    local actual_target = target_rev or "HEAD"
    git.get_merge_base(base_rev, actual_target, git_root, function(err_mb, merge_base_hash)
      if parse.failed(err_mb) then
        return
      end

      -- Schedule the explorer call to run in main context (handle_explorer uses nvim_get_current_buf)
      vim.schedule(function()
        if target_rev then
          M.run(merge_base_hash, target_rev, global_opts, pathspec)
        else
          M.run(merge_base_hash, nil, global_opts, pathspec)
        end
      end)
    end)
  end)
end

-- Wrapper for merge-base single-file diff: computes merge-base first, then opens diff

return M
