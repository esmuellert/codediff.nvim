-- Git revision resolution and ancestry queries.
local M = {}

local runner = require("codediff.core.git.runner")
local run_git_async = runner.run_async
local run_git_sync = runner.run_sync

-- The universal SHA-1 for an empty git tree object. Every git repository
-- recognizes this hash — see `git hash-object -t tree /dev/null`. Diffing
-- against it yields the entire other side as newly added, which is the
-- correct semantic for "no HEAD yet" (a fresh repo before the first commit,
-- see #498).
local GIT_EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- Only full object IDs and their ancestry expressions are immutable cache keys.
function M.is_fixed(revision)
  if type(revision) ~= "string" then
    return false
  end
  local hash, suffix = revision:match("^(%x+)(.*)$")
  return hash ~= nil and (#hash == 40 or #hash == 64) and (suffix == "" or suffix:match("^[~^%d]+$") ~= nil)
end

-- Resolve a git revision to its commit hash (async, atomic)
-- revision: branch name, tag, or commit reference
-- git_root: absolute path to git repository root
-- callback: function(err, commit_hash)
function M.resolve_revision(revision, git_root, callback)
  run_git_async({ "rev-parse", "--verify", revision }, { cwd = git_root }, function(err, output)
    if err then
      -- Special case: on an unborn branch (fresh `git init` with no commits
      -- yet), `rev-parse --verify HEAD` fails with "Needed a single
      -- revision". Callers ask for HEAD to get a diff base; the empty-tree
      -- hash IS a valid diff base and produces the correct visual (every
      -- staged/worktree file appears as newly added), so translate the
      -- failure into a hash the caller can use unchanged (#498).
      if revision == "HEAD" then
        -- Double-check we're actually on an unborn branch (not, say, a
        -- corrupt repo). `symbolic-ref HEAD` succeeds even when the target
        -- branch has no commits yet, so this positively identifies unborn.
        run_git_async({ "symbolic-ref", "--quiet", "HEAD" }, { cwd = git_root }, function(sym_err)
          if sym_err then
            -- HEAD is not a symbolic ref (detached HEAD without any commit,
            -- or a genuinely broken repo). Surface the original failure.
            callback(string.format("Invalid revision '%s': %s", revision, err), nil)
          else
            callback(nil, GIT_EMPTY_TREE_SHA)
          end
        end)
        return
      end
      callback(string.format("Invalid revision '%s': %s", revision, err), nil)
    else
      local commit_hash = vim.trim(output)
      callback(nil, commit_hash)
    end
  end)
end

--- Read the parent commit hashes of a revision.
--- @param revision string
--- @param git_root string
--- @param callback fun(err: string|nil, parents: string[]|nil)
function M.get_revision_parents(revision, git_root, callback)
  run_git_async({ "rev-list", "--parents", "-n", "1", revision }, { cwd = git_root }, function(err, output)
    if err then
      callback(err, nil)
      return
    end
    local commits = vim.split(vim.trim(output), "%s+", { trimempty = true })
    table.remove(commits, 1)
    callback(nil, commits)
  end)
end

-- Get merge-base between two revisions (async)
-- rev1: first revision (e.g., "main", "origin/main")
-- rev2: second revision (e.g., "HEAD", branch name)
-- git_root: absolute path to git repository root
-- callback: function(err, merge_base_hash)
function M.get_merge_base(rev1, rev2, git_root, callback)
  run_git_async({ "merge-base", rev1, rev2 }, { cwd = git_root }, function(err, output)
    if err then
      callback(string.format("Failed to find merge-base between '%s' and '%s': %s", rev1, rev2, err), nil)
    else
      local merge_base = vim.trim(output)
      callback(nil, merge_base)
    end
  end)
end

-- Resolve a file's path at a given revision, following renames/copies.
-- If the file was renamed or copied between `revision` and HEAD, returns the old path.
-- Otherwise, returns the current path unchanged.
-- revision: the target commit hash
-- git_root: absolute path to git repository root
-- rel_path: current relative path of the file
-- callback: function(err, resolved_path)
function M.resolve_path_at_revision(revision, git_root, rel_path, callback)
  run_git_async({ "log", "--follow", "--diff-filter=RC", "--format=", "--name-status", revision .. "..HEAD", "--", rel_path }, { cwd = git_root }, function(err, output)
    if err or not output or output == "" then
      callback(nil, rel_path)
      return
    end

    -- Parse name-status output (last rename/copy entry gives the original name)
    -- Format: "R100\told_path\tnew_path" or "C096\told_path\tnew_path"
    local lines = vim.split(vim.trim(output), "\n")
    for i = #lines, 1, -1 do
      local old_path = lines[i]:match("^[RC]%d*\t(.-)\t")
      if old_path then
        callback(nil, old_path)
        return
      end
    end

    callback(nil, rel_path)
  end)
end

-- Get revision candidates for command completion (sync)
-- Returns list of branches, tags, remotes, and special refs
function M.get_rev_candidates(git_root)
  if not git_root then
    return {}
  end

  local candidates = {}

  -- Special HEAD refs
  local head_refs = { "HEAD", "HEAD~1", "HEAD~2", "HEAD~3" }
  vim.list_extend(candidates, head_refs)

  -- Get branches, tags, and remotes
  local refs = run_git_sync({
    "-C",
    git_root,
    "rev-parse",
    "--symbolic",
    "--branches",
    "--tags",
    "--remotes",
  })
  if refs then
    vim.list_extend(candidates, refs)
  end

  -- Get stashes
  local stashes = run_git_sync({
    "-C",
    git_root,
    "stash",
    "list",
    "--pretty=format:%gd",
  })
  if stashes then
    vim.list_extend(candidates, stashes)
  end

  return candidates
end

return M
