-- Git operations module for vscode-diff
-- All operations are async and atomic
local M = {}

-- LRU Cache for git file content
-- Stores recently fetched file content to avoid redundant git calls
local ContentCache = {}
ContentCache.__index = ContentCache

function ContentCache.new(max_size)
  local self = setmetatable({}, ContentCache)
  self.max_size = max_size or 50 -- Default: cache 50 files
  self.cache = {} -- {key -> lines}
  self.access_order = {} -- List of keys in LRU order (most recent last)
  return self
end

function ContentCache:_make_key(revision, git_root, rel_path)
  return git_root .. ":::" .. revision .. ":::" .. rel_path
end

-- Helper to update access order (move key to end = most recently used)
function ContentCache:_update_access_order(key)
  for i, k in ipairs(self.access_order) do
    if k == key then
      table.remove(self.access_order, i)
      break
    end
  end
  table.insert(self.access_order, key)
end

function ContentCache:get(revision, git_root, rel_path)
  local key = self:_make_key(revision, git_root, rel_path)
  local entry = self.cache[key]

  if entry then
    self:_update_access_order(key)
    -- Return a copy to prevent cache corruption
    return vim.list_extend({}, entry)
  end

  return nil
end

function ContentCache:put(revision, git_root, rel_path, lines)
  local key = self:_make_key(revision, git_root, rel_path)

  -- If already exists, update access order
  if self.cache[key] then
    self:_update_access_order(key)
  else
    -- Check if cache is full
    if #self.access_order >= self.max_size then
      -- Evict least recently used (first item)
      local lru_key = table.remove(self.access_order, 1)
      self.cache[lru_key] = nil
    end
    table.insert(self.access_order, key)
  end

  -- Store a copy to prevent cache corruption
  self.cache[key] = vim.list_extend({}, lines)
end

function ContentCache:clear()
  self.cache = {}
  self.access_order = {}
end

-- Global cache instance
local file_content_cache = ContentCache.new(50)

-- Public API to clear cache if needed
function M.clear_cache()
  file_content_cache:clear()
end

-- Run a git command asynchronously
-- Uses vim.system if available (Neovim 0.10+), falls back to vim.loop.spawn
local function run_git_async(args, opts, callback)
  opts = opts or {}

  -- Use vim.system if available (Neovim 0.10+)
  if vim.system then
    -- On Windows, vim.system requires that cwd exists before running the command
    -- Validate the directory exists to provide a better error message
    if opts.cwd and vim.fn.isdirectory(opts.cwd) == 0 then
      callback("Directory does not exist: " .. opts.cwd, nil)
      return
    end

    vim.system(vim.list_extend({ "git" }, args), {
      cwd = opts.cwd,
      text = true,
    }, function(result)
      if result.code == 0 then
        callback(nil, result.stdout or "")
      else
        callback(result.stderr or "Git command failed", nil)
      end
    end)
  else
    -- Fallback to vim.loop.spawn for older Neovim versions
    -- Validate the directory exists to provide a better error message
    if opts.cwd and vim.fn.isdirectory(opts.cwd) == 0 then
      callback("Directory does not exist: " .. opts.cwd, nil)
      return
    end

    local stdout_data = {}
    local stderr_data = {}

    local handle
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)

    ---@diagnostic disable-next-line: missing-fields
    handle = vim.loop.spawn("git", {
      args = args,
      cwd = opts.cwd,
      stdio = { nil, stdout, stderr },
    }, function(code)
      if stdout then
        stdout:close()
      end
      if stderr then
        stderr:close()
      end
      if handle then
        handle:close()
      end

      vim.schedule(function()
        if code == 0 then
          callback(nil, table.concat(stdout_data))
        else
          callback(table.concat(stderr_data) or "Git command failed", nil)
        end
      end)
    end)

    if not handle then
      callback("Failed to spawn git process", nil)
      return
    end

    if stdout then
      stdout:read_start(function(err, data)
        if err then
          callback(err, nil)
        elseif data then
          table.insert(stdout_data, data)
        end
      end)
    end

    if stderr then
      stderr:read_start(function(err, data)
        if err then
          callback(err, nil)
        elseif data then
          table.insert(stderr_data, data)
        end
      end)
    end
  end
end

-- ATOMIC ASYNC OPERATIONS
-- All functions below are simple, atomic git operations

-- Get git root directory for the given file (async)
-- callback: function(err, git_root)
function M.get_git_root(file_path, callback)
  -- Handle both file paths and directory paths
  local dir
  if vim.fn.isdirectory(file_path) == 1 then
    dir = file_path
  else
    dir = vim.fn.fnamemodify(file_path, ":h")
  end

  -- Normalize path separators for consistency
  dir = dir:gsub("\\", "/")

  run_git_async({ "rev-parse", "--show-toplevel" }, { cwd = dir }, function(err, output)
    if err then
      callback("Not in a git repository", nil)
    else
      local git_root = vim.trim(output)
      -- Resolve full path to handle short paths/symlinks and normalize
      git_root = vim.fn.fnamemodify(git_root, ":p")
      -- Ensure git_root uses forward slashes for consistency
      git_root = git_root:gsub("\\", "/")
      -- Remove trailing slash if present (fnamemodify :p adds it on some systems)
      if git_root:sub(-1) == "/" then
        git_root = git_root:sub(1, -2)
      end
      callback(nil, git_root)
    end
  end)
end

-- Get git directory path (handles worktrees correctly)
-- git_root: absolute path to git repository root
-- callback: function(err, git_dir)
function M.get_git_dir(git_root, callback)
  run_git_async({ "rev-parse", "--git-dir" }, { cwd = git_root }, function(err, output)
    if err then
      callback("Failed to get git directory: " .. err, nil)
    else
      local git_dir = vim.trim(output)
      -- Make absolute path if relative
      if not git_dir:match("^/") and not git_dir:match("^%a:") then
        git_dir = git_root .. "/" .. git_dir
      end
      callback(nil, git_dir)
    end
  end)
end

-- Get relative path of file within git repository (sync, pure computation)
function M.get_relative_path(file_path, git_root)
  local abs_path = vim.fn.fnamemodify(file_path, ":p")
  abs_path = abs_path:gsub("\\", "/")
  git_root = git_root:gsub("\\", "/")
  local rel_path = abs_path:sub(#git_root + 2)
  return rel_path
end

-- Resolve a git revision to its commit hash (async, atomic)
-- revision: branch name, tag, or commit reference
-- git_root: absolute path to git repository root
-- callback: function(err, commit_hash)
function M.resolve_revision(revision, git_root, callback)
  run_git_async({ "rev-parse", "--verify", revision }, { cwd = git_root }, function(err, output)
    if err then
      callback(string.format("Invalid revision '%s': %s", revision, err), nil)
    else
      local commit_hash = vim.trim(output)
      callback(nil, commit_hash)
    end
  end)
end

-- Get file content from a specific git revision (async, atomic)
-- revision: e.g., "HEAD", "HEAD~1", commit hash, branch name, tag
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root (with forward slashes)
-- callback: function(err, lines) where lines is a table of strings
function M.get_file_content(revision, git_root, rel_path, callback)
  -- Don't cache mutable revisions (staged index can change with git add/reset)
  local is_mutable = revision:match("^:[0-3]$")

  -- Check cache first (only for immutable revisions)
  if not is_mutable then
    local cached_lines = file_content_cache:get(revision, git_root, rel_path)
    if cached_lines then
      callback(nil, cached_lines)
      return
    end
  end

  -- Cache miss or mutable revision - fetch from git
  local git_object = revision .. ":" .. rel_path

  run_git_async({ "show", git_object }, { cwd = git_root }, function(err, output)
    if err then
      if err:match("does not exist") or err:match("exists on disk, but not in") then
        callback(string.format("File '%s' not found in revision '%s'", rel_path, revision), nil)
      else
        callback(err, nil)
      end
      return
    end

    local lines = vim.split(output, "\n")
    if lines[#lines] == "" then
      table.remove(lines, #lines)
    end

    -- Store in cache (only for immutable revisions)
    if not is_mutable then
      file_content_cache:put(revision, git_root, rel_path, lines)
    end

    callback(nil, lines)
  end)
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
function M.get_status(git_root, callback)
  run_git_async(
    { "status", "--porcelain", "-uall", "-M" }, -- -M to detect renames
    { cwd = git_root },
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

      for line in output:gmatch("[^\r\n]+") do
        if #line >= 3 then
          local index_status = line:sub(1, 1)
          local worktree_status = line:sub(2, 2)
          local path_part = line:sub(4)

          -- Handle renames: "old_path -> new_path"
          local old_path, new_path = path_part:match("^(.+) %-> (.+)$")
          local path = old_path and new_path or path_part -- Use new_path for display if rename
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
      end

      callback(nil, result)
    end
  )
end

-- Get diff between a revision and working tree (async)
-- revision: git revision (e.g., "HEAD", "HEAD~1", commit hash, branch name)
-- git_root: absolute path to git repository root
-- callback: function(err, status_result) where status_result has same format as get_status
function M.get_diff_revision(revision, git_root, callback)
  run_git_async({ "diff", "--name-status", "-M", revision }, { cwd = git_root }, function(err, output)
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
          local path = parts[2]
          local old_path = nil

          -- Handle renames (R100 or similar)
          if status == "R" and #parts >= 3 then
            old_path = parts[2]
            path = parts[3]
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

-- Get diff between two revisions (async)
-- rev1: original revision (e.g., commit hash)
-- rev2: modified revision (e.g., commit hash)
-- git_root: absolute path to git repository root
-- callback: function(err, status_result)
function M.get_diff_revisions(rev1, rev2, git_root, callback)
  run_git_async({ "diff", "--name-status", "-M", rev1, rev2 }, { cwd = git_root }, function(err, output)
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
          local path = parts[2]
          local old_path = nil

          -- Handle renames (R100 or similar)
          if status == "R" and #parts >= 3 then
            old_path = parts[2]
            path = parts[3]
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

-- Run a git command synchronously
-- Returns output string or nil on error
local function run_git_sync(args, opts)
  opts = opts or {}
  local cmd = vim.list_extend({ "git" }, args)

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  return result
end

-- Get git root directory synchronously (for completion)
-- Returns git_root or nil if not in a git repo
function M.get_git_root_sync(file_path)
  local dir
  if vim.fn.isdirectory(file_path) == 1 then
    dir = file_path
  else
    dir = vim.fn.fnamemodify(file_path, ":h")
  end

  local cmd = { "git", "-C", dir, "rev-parse", "--show-toplevel" }
  local result = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end

  local git_root = vim.trim(result[1])
  git_root = git_root:gsub("\\", "/")
  return git_root
end

-- Stage a file (git add)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- callback: function(err)
function M.stage_file(git_root, rel_path, callback)
  run_git_async({ "add", "--", rel_path }, { cwd = git_root }, function(err, _)
    if err then
      callback("Failed to stage file: " .. err)
    else
      callback(nil)
    end
  end)
end

-- Unstage a file (git reset HEAD)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- callback: function(err)
function M.unstage_file(git_root, rel_path, callback)
  run_git_async({ "reset", "HEAD", "--", rel_path }, { cwd = git_root }, function(err, _)
    if err then
      callback("Failed to unstage file: " .. err)
    else
      callback(nil)
    end
  end)
end

-- Stage all files (git add -A)
-- git_root: absolute path to git repository root
-- callback: function(err)
function M.stage_all(git_root, callback)
  run_git_async({ "add", "-A" }, { cwd = git_root }, function(err, _)
    if err then
      callback("Failed to stage all files: " .. err)
    else
      callback(nil)
    end
  end)
end

-- Unstage all files (git reset HEAD)
-- git_root: absolute path to git repository root
-- callback: function(err)
function M.unstage_all(git_root, callback)
  run_git_async({ "reset", "HEAD" }, { cwd = git_root }, function(err, _)
    if err then
      callback("Failed to unstage all files: " .. err)
    else
      callback(nil)
    end
  end)
end

-- Restore/discard changes to a file (git checkout -- or git restore)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- callback: function(err)
function M.restore_file(git_root, rel_path, callback)
  -- git restore is preferred (Git 2.23+), fallback to checkout
  run_git_async({ "restore", "--", rel_path }, { cwd = git_root }, function(err, _)
    if err then
      -- Fallback to git checkout for older git versions
      run_git_async({ "checkout", "--", rel_path }, { cwd = git_root }, function(err2, _)
        if err2 then
          callback("Failed to restore file: " .. err2)
        else
          callback(nil)
        end
      end)
    else
      callback(nil)
    end
  end)
end

-- Delete untracked file (git clean -f)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- callback: function(err)
function M.delete_untracked(git_root, rel_path, callback)
  run_git_async({ "clean", "-f", "--", rel_path }, { cwd = git_root }, function(err, _)
    if err then
      callback("Failed to delete untracked file: " .. err)
    else
      callback(nil)
    end
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
