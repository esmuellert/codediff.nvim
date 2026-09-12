-- :CodeDiff --staged -- the explorer, showing the index against a revision.
local M = {}

local git = require("codediff.core.git")
local view = require("codediff.ui.view")
local path = require("codediff.core.path")
local parse = require("codediff.commands.parse")

-- Handle explorer for staged-only view (--staged / --cached flag).
-- Matches diffview.nvim's `--staged`: compare the index against the given
-- revision (defaulting to HEAD). Only files whose index differs from that
-- revision are shown; opening a file diffs `<revision>` vs `:0` (the index).
--
-- revision: git revision to compare the index against (nil defaults to "HEAD")
-- global_opts: layout / exit_on_close / repo overrides
-- pathspec: optional trailing pathspec (#74)
function M.run(revision, global_opts, pathspec)
  local current_file = vim.api.nvim_buf_get_name(0)
  local rev = revision or "HEAD"

  local function open_explorer(git_root, is_override)
    local focus_file = nil
    if current_file ~= "" and not is_override then
      focus_file = git.get_relative_path(current_file, git_root)
    end

    git.resolve_revision(rev, git_root, function(err_resolve, commit_hash)
      if parse.failed(err_resolve) then
        return
      end

      git.get_diff_staged(commit_hash, git_root, function(err_status, status_result)
        vim.schedule(function()
          if err_status then
            vim.notify(err_status, vim.log.levels.ERROR)
            return
          end

          if #status_result.staged == 0 then
            vim.notify("No staged changes to show", vim.log.levels.INFO)
            return
          end

          ---@type SessionConfig
          local session_config = {
            panel = {
              name = "explorer",
              data = {
                status_result = status_result,
                focus_file = focus_file,
                pathspec = pathspec,
                source_revisions = { original = rev, modified = ":0" },
              },
            },
            git_root = git_root,
            original = path.empty(),
            modified = path.empty(),
            original_revision = commit_hash,
            modified_revision = ":0", -- Index; tree.lua/refresh.lua key off this to render as staged-only mode
            layout = global_opts.layout,
            exit_on_close = global_opts.exit_on_close,
          }

          view.create(session_config, "")
        end)
      end, pathspec)
    end)
  end

  parse.resolve_working_root(global_opts, open_explorer)
end

-- Wrapper for merge-base explorer mode: computes merge-base first, then opens explorer

return M
