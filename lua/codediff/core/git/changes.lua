-- Git file-change discovery for worktrees, the index, and revisions.
local M = {}

local config = require("codediff.config")
local run_git_async = require("codediff.core.git.runner").run_async

-- Unquote git C-quoted paths (e.g., "my file.md" -> my file.md)
local function unquote_path(path)
  if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
    local unquoted = path:sub(2, -2)
    unquoted = unquoted:gsub("\\(.)", function(char)
      local escapes = { a = "\a", b = "\b", t = "\t", n = "\n", v = "\v", f = "\f", r = "\r", ["\\"] = "\\", ['"'] = '"' }
      return escapes[char] or char
    end)
    return unquoted
  end
  return path
end

-- Read `explorer.untracked` from config, validated. Owned by the domain
-- functions that need it (get_status, get_diff_revision) — see #389 for the
-- semantics of each mode; run_git_async stays a dumb transport.
local UNTRACKED_MODES = { all = true, normal = true, no = true }
local function untracked_mode()
  local mode = config.options.explorer and config.options.explorer.untracked
  return UNTRACKED_MODES[mode] and mode or "all"
end

-- Check if a git status code indicates a merge conflict
-- Git uses these status codes for conflicts:
-- U = unmerged (both modified, added by us/them, deleted by us/them)
-- A on both sides = both added
-- D on both sides = both deleted
local function is_conflict_status(index_status, worktree_status)
  -- UU = both modified (most common)
  -- AA = both added
  -- DD = both deleted
  -- AU/UA = added by us/them
  -- DU/UD = deleted by us/them
  if index_status == "U" or worktree_status == "U" then
    return true
  end
  if index_status == "A" and worktree_status == "A" then
    return true
  end
  if index_status == "D" and worktree_status == "D" then
    return true
  end
  return false
end

-- Get git status for current repository (async)
-- git_root: absolute path to git repository root
-- callback: function(err, status_result) where status_result is:
-- {
--   unstaged = { { path = "file.txt", status = "M"|"A"|"D"|"??" } },
--   staged = { { path = "file.txt", status = "M"|"A"|"D" } },
--   conflicts = { { path = "file.txt", status = "!" } }
-- }
function M.get_status(git_root, callback, pathspec)
  -- Trailing `-- <paths>` scopes the status to a pathspec (nil/empty = all files).
  -- `-u<mode>` (untracked-files scan; #389) is read from explorer.untracked config.
  run_git_async(
    vim.list_extend({ "status", "--porcelain", "-z", "-u" .. untracked_mode(), "-M", "--" }, pathspec or {}), -- -M to detect renames
    { cwd = git_root, no_optional_locks = true },
    function(err, output)
      if err then
        callback(err, nil)
        return
      end

      local result = {
        unstaged = {},
        staged = {},
        conflicts = {},
      }

      local entries = vim.split(output, "\0", { plain = true, trimempty = true })
      local i = 1
      while i <= #entries do
        local line = entries[i]
        if #line >= 3 then
          local index_status = line:sub(1, 1)
          local worktree_status = line:sub(2, 2)
          local path, old_path = line:sub(4), nil

          -- Porcelain -z provides raw paths; renamed entries put the old name
          -- in the following record, without quoting or an ambiguous arrow.
          if index_status == "R" or index_status == "C" or worktree_status == "R" or worktree_status == "C" then
            i = i + 1
            old_path = entries[i]
          end
          local is_rename = old_path ~= nil

          -- Check for merge conflicts first (takes priority)
          if is_conflict_status(index_status, worktree_status) then
            table.insert(result.conflicts, {
              path = path,
              status = "!", -- Use ! symbol for conflicts
              conflict_type = index_status .. worktree_status, -- Store original status (e.g., "UU", "AA")
            })
          else
            -- Staged changes (index has changes)
            if index_status ~= " " and index_status ~= "?" then
              table.insert(result.staged, {
                path = path,
                status = index_status,
                old_path = is_rename and old_path or nil, -- Store old path if rename
              })
            end

            -- Unstaged changes (worktree has changes)
            if worktree_status ~= " " then
              table.insert(result.unstaged, {
                path = path,
                status = worktree_status == "?" and "??" or worktree_status,
                old_path = is_rename and old_path or nil,
              })
            end
          end
        end
        i = i + 1
      end

      callback(nil, result)
    end
  )
end

-- Get diff between a revision and working tree (async)
-- revision: git revision (e.g., commit hash)
-- git_root: absolute path to git repository root
-- callback: function(err, status_result) where status_result has same format as get_status
function M.get_diff_revision(revision, git_root, callback, pathspec)
  -- First get tracked file changes (trailing `-- <paths>` scopes to a pathspec)
  run_git_async(vim.list_extend({ "diff", "--name-status", "-M", revision, "--" }, pathspec or {}), { cwd = git_root, no_optional_locks = true }, function(err, output)
    if err then
      callback(err, nil)
      return
    end

    local result = {
      unstaged = {},
      staged = {},
    }

    for line in output:gmatch("[^\r\n]+") do
      if #line > 0 then
        local parts = vim.split(line, "\t")
        if #parts >= 2 then
          local status = parts[1]:sub(1, 1)
          local path = unquote_path(parts[2])
          local old_path = nil

          -- Handle renames (R100 or similar)
          if status == "R" and #parts >= 3 then
            old_path = unquote_path(parts[2])
            path = unquote_path(parts[3])
          end

          table.insert(result.unstaged, {
            path = path,
            status = status,
            old_path = old_path,
          })
        end
      end
    end

    -- Untracked files (#389): they don't exist in the revision, so they're "new".
    -- `no`   -> skip the recursive ls-files scan entirely (the hang fix for huge
    --          work trees like GIT_WORK_TREE=$HOME).
    -- `normal` -> collapse untracked directories to one entry via --directory.
    -- `all`  -> list every untracked file individually (current default).
    local mode = untracked_mode()
    if mode == "no" then
      callback(nil, result)
      return
    end
    local ls_args = { "ls-files", "--others", "--exclude-standard" }
    if mode == "normal" then
      table.insert(ls_args, "--directory")
    end
    table.insert(ls_args, "--")
    run_git_async(vim.list_extend(ls_args, pathspec or {}), { cwd = git_root, no_optional_locks = true }, function(err_untracked, output_untracked)
      if err_untracked then
        -- If getting untracked files fails, just return what we have
        callback(nil, result)
        return
      end

      -- Add untracked files as new files with "??" status
      for line in output_untracked:gmatch("[^\r\n]+") do
        if #line > 0 then
          table.insert(result.unstaged, {
            path = line,
            status = "??",
            old_path = nil,
          })
        end
      end

      callback(nil, result)
    end)
  end)
end

-- Get diff between two revisions (async)
-- rev1: original revision (e.g., commit hash)
-- rev2: modified revision (e.g., commit hash)
-- git_root: absolute path to git repository root
-- callback: function(err, status_result)
function M.get_diff_revisions(rev1, rev2, git_root, callback, pathspec)
  run_git_async(vim.list_extend({ "diff", "--name-status", "-M", rev1, rev2, "--" }, pathspec or {}), { cwd = git_root, no_optional_locks = true }, function(err, output)
    if err then
      callback(err, nil)
      return
    end

    local result = {
      unstaged = {},
      staged = {},
    }

    -- For revision comparison, we treat everything as "unstaged" for explorer compatibility
    -- But to keep explorer compatible, we'll put them in 'staged' as they are committed changes
    -- relative to each other.

    for line in output:gmatch("[^\r\n]+") do
      if #line > 0 then
        local parts = vim.split(line, "\t")
        if #parts >= 2 then
          local status = parts[1]:sub(1, 1)
          local path = unquote_path(parts[2])
          local old_path = nil

          -- Handle renames (R100 or similar)
          if status == "R" and #parts >= 3 then
            old_path = unquote_path(parts[2])
            path = unquote_path(parts[3])
          end

          table.insert(result.unstaged, {
            path = path,
            status = status,
            old_path = old_path,
          })
        end
      end
    end

    callback(nil, result)
  end)
end

-- Get staged changes vs a revision (async) — the equivalent of diffview's
-- `--staged`/`--cached` filter: `git diff --cached --name-status -M <revision>`.
-- Only files whose index copy differs from `revision` are returned. Entries
-- go into `result.staged` so the `-` toggle key unstages them and the tree
-- renders them under the "Staged Changes" header.
--
-- revision: git revision (e.g., "HEAD"), the base to compare the index against
-- git_root: absolute path to git repository root
-- callback: function(err, status_result)
function M.get_diff_staged(revision, git_root, callback, pathspec)
  run_git_async(vim.list_extend({ "diff", "--cached", "--name-status", "-M", revision, "--" }, pathspec or {}), { cwd = git_root }, function(err, output)
    if err then
      callback(err, nil)
      return
    end

    local result = {
      unstaged = {},
      staged = {},
      conflicts = {},
    }

    for line in output:gmatch("[^\r\n]+") do
      if #line > 0 then
        local parts = vim.split(line, "\t")
        if #parts >= 2 then
          local status = parts[1]:sub(1, 1)
          local path = unquote_path(parts[2])
          local old_path = nil

          if status == "R" and #parts >= 3 then
            old_path = unquote_path(parts[2])
            path = unquote_path(parts[3])
          end

          table.insert(result.staged, {
            path = path,
            status = status,
            old_path = old_path,
          })
        end
      end
    end

    callback(nil, result)
  end)
end

-- Get files changed in a specific commit (async)
-- commit_hash: full or short commit hash
-- git_root: absolute path to git repository root
-- callback: function(err, files) where files is array of:
--   { path, status, old_path }
function M.get_commit_files(commit_hash, git_root, callback)
  run_git_async({ "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-M", commit_hash }, { cwd = git_root }, function(err, output)
    if err then
      callback(err, nil)
      return
    end

    local files = {}
    for line in output:gmatch("[^\n]+") do
      local parts = vim.split(line, "\t")
      if #parts >= 2 then
        local status = parts[1]:sub(1, 1)
        local path = unquote_path(parts[2])
        local old_path = nil

        -- Handle renames (R100 or similar)
        if status == "R" and #parts >= 3 then
          old_path = unquote_path(parts[2])
          path = unquote_path(parts[3])
        end

        table.insert(files, {
          path = path,
          status = status,
          old_path = old_path,
        })
      end
    end

    callback(nil, files)
  end)
end

return M
