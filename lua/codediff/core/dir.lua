-- Directory comparison logic (no git required)
-- Compares two directories and returns a git-like status result
-- WARNING: Synchronous recursive scan - large directory trees may block Neovim
local M = {}

local uv = vim.loop

local function normalize_dir(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  abs = abs:gsub("\\", "/")
  if abs:sub(-1) == "/" then
    abs = abs:sub(1, -2)
  end
  return abs
end

local function scan_dir(root)
  local files = {}

  local function recurse(current, rel_prefix)
    local handle = uv.fs_scandir(current)
    if not handle then
      return
    end

    while true do
      local name, t = uv.fs_scandir_next(handle)
      if not name then
        break
      end

      local abs = current .. "/" .. name
      local rel = rel_prefix ~= "" and (rel_prefix .. "/" .. name) or name

      if t == "directory" then
        recurse(abs, rel)
      elseif t == "file" then
        local stat = uv.fs_stat(abs) or {}
        files[rel] = {
          path = rel,
          size = stat.size,
          mtime = stat.mtime and stat.mtime.sec or nil,
        }
      end
    end
  end

  recurse(root, "")
  return files
end

local function is_modified(a, b)
  if not a or not b then
    return false
  end
  if a.size ~= b.size then
    return true
  end
  if a.mtime ~= b.mtime then
    return true
  end
  return false
end

-- Compare two directories and return a git-like status_result.
-- dir1 = "original", dir2 = "modified"
-- NOTE: Modification detection is metadata-based (size and mtime only),
--       not a content hash; this is a fast, best-effort diff.
function M.diff_directories(dir1, dir2)
  local root1 = normalize_dir(dir1)
  local root2 = normalize_dir(dir2)

  local files1 = scan_dir(root1)
  local files2 = scan_dir(root2)

  local result = {
    unstaged = {},
    staged = {},
    conflicts = {}, -- Empty for dir mode, but consistent with git status shape
  }

  local seen = {}

  for path, meta1 in pairs(files1) do
    local meta2 = files2[path]
    if not meta2 then
      table.insert(result.unstaged, {
        path = path,
        status = "D",
      })
    else
      seen[path] = true
      if is_modified(meta1, meta2) then
        table.insert(result.unstaged, {
          path = path,
          status = "M",
        })
      end
    end
  end

  for path, _ in pairs(files2) do
    if not seen[path] then
      table.insert(result.unstaged, {
        path = path,
        status = "A",
      })
    end
  end

  table.sort(result.unstaged, function(a, b)
    return a.path < b.path
  end)

  return {
    status_result = result,
    root1 = root1,
    root2 = root2,
  }
end

return M
