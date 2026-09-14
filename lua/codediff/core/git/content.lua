-- Git revision file content and its in-memory cache.
local M = {}

local run_git_async = require("codediff.core.git.runner").run_async

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

-- Get file content from a specific git revision (async, atomic)
-- revision: e.g., "HEAD", "HEAD~1", commit hash, branch name, tag
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root (with forward slashes)
-- callback: function(err, lines) where lines is a table of strings
function M.get_file_content(revision, git_root, rel_path, callback)
  -- Branches, HEAD and index stages can change without changing the path.
  local is_mutable = not require("codediff.core.git.revision").is_fixed(revision)

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
      if err:match("does not exist") or err:match("exists on disk, but not in") or err:match("is in the index, but not at stage") then
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

return M
