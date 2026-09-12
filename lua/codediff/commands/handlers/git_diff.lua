-- :CodeDiff [rev] [rev2] -- the current file against one or two revisions.
local M = {}

local git = require("codediff.core.git")
local view = require("codediff.ui.view")
local path = require("codediff.core.path")
local parse = require("codediff.commands.parse")

--- Handles diffing the current buffer against a given git revision.
-- @param revision string: The git revision (e.g., "HEAD", commit hash, branch name) to compare the current file against.
-- @param revision2 string?: Optional second revision. If provided, compares revision vs revision2.
-- @param global_opts table?: Global options (e.g., { layout = "inline" })
-- This function chains async git operations to get git root, resolve revision to hash, and get file content.
function M.run(revision, revision2, global_opts)
  local current_buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_buf)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = current_buf })

  -- Diffing the current buffer against a revision requires a real on-disk file.
  -- Reject scratch/quickfix/terminal/dashboard buffers (buftype ~= "") and
  -- codediff:// virtual diff buffers (re-diffing one is not meaningful).
  if current_file == "" or buftype ~= "" then
    vim.notify("Current buffer is not a file", vim.log.levels.ERROR)
    return
  end
  if current_file:match("^codediff://") then
    vim.notify("Cannot diff a codediff:// virtual buffer", vim.log.levels.ERROR)
    return
  end

  -- Determine filetype from current buffer (sync operation, no git involved)
  local filetype = vim.bo[0].filetype
  if not filetype or filetype == "" then
    filetype = vim.filetype.match({ filename = current_file }) or ""
  end

  -- Async chain: get_git_root -> resolve_revision -> get_file_content -> render_diff
  git.get_git_root(current_file, function(err_root, git_root)
    if parse.failed(err_root) then
      return
    end

    local relative_path = git.get_relative_path(current_file, git_root)

    git.resolve_revision(revision, git_root, function(err_resolve, commit_hash)
      if parse.failed(err_resolve) then
        return
      end

      -- Resolve the file's path at the original revision (handles renames/copies)
      git.resolve_path_at_revision(commit_hash, git_root, relative_path, function(_, original_path)
        if revision2 then
          -- Compare two revisions
          git.resolve_revision(revision2, git_root, function(err_resolve2, commit_hash2)
            if parse.failed(err_resolve2) then
              return
            end

            -- Resolve path at modified revision too
            git.resolve_path_at_revision(commit_hash2, git_root, relative_path, function(_, modified_path)
              vim.schedule(function()
                ---@type SessionConfig
                local session_config = {
                  panel = nil,
                  git_root = git_root,
                  original = path.make_ref(original_path, git_root),
                  modified = path.make_ref(modified_path, git_root),
                  original_revision = commit_hash,
                  modified_revision = commit_hash2,
                  source_revisions = { original = revision, modified = revision2 },
                  layout = global_opts.layout,
                  exit_on_close = global_opts.exit_on_close,
                }
                view.create(session_config, filetype)
              end)
            end)
          end)
        else
          -- Compare revision vs working tree
          vim.schedule(function()
            ---@type SessionConfig
            local session_config = {
              panel = nil,
              git_root = git_root,
              original = path.make_ref(original_path, git_root),
              modified = path.make_ref(relative_path, git_root),
              original_revision = commit_hash,
              modified_revision = "WORKING",
              source_revisions = { original = revision, modified = "WORKING" },
              layout = global_opts.layout,
              exit_on_close = global_opts.exit_on_close,
            }
            view.create(session_config, filetype)
          end)
        end
      end)
    end)
  end)
end

-- Wrapper for merge-base single-file diff: computes merge-base first, then opens diff
function M.run_merge_base(base_rev, target_rev, global_opts)
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file == "" then
    vim.notify("Current buffer is not a file", vim.log.levels.ERROR)
    return
  end

  git.get_git_root(current_file, function(err_root, git_root)
    if parse.failed(err_root) then
      return
    end

    local actual_target = target_rev or "HEAD"
    git.get_merge_base(base_rev, actual_target, git_root, function(err_mb, merge_base_hash)
      if parse.failed(err_mb) then
        return
      end

      -- Schedule the diff call to run in main context (handle_git_diff uses nvim_buf_get_name)
      vim.schedule(function()
        M.run(merge_base_hash, target_rev, global_opts)
      end)
    end)
  end)
end

return M
