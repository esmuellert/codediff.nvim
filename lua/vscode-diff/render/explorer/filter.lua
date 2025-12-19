local M = {}

-- Convert glob pattern to Lua pattern
function M.glob_to_pattern(glob)
  -- Use unique placeholders that won't appear in file paths
  local DOUBLE_STAR_SLASH = "\001DOUBLESTARSLASH\001"
  local DOUBLE_STAR = "\001DOUBLESTAR\001"
  local SINGLE_STAR = "\001SINGLESTAR\001"

  local pattern = glob
  -- Escape Lua magic characters (except * and ?)
  pattern = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  -- Convert glob wildcards to placeholders first (order matters!)
  -- Handle **/ specially - it matches zero or more directories
  pattern = pattern:gsub("%*%*/", DOUBLE_STAR_SLASH)
  pattern = pattern:gsub("%*%*", DOUBLE_STAR)
  pattern = pattern:gsub("%*", SINGLE_STAR)
  pattern = pattern:gsub("%?", ".") -- ? matches single character
  -- Now convert placeholders to Lua patterns
  pattern = pattern:gsub(DOUBLE_STAR_SLASH, ".-") -- **/ matches zero or more dirs (including trailing /)
  pattern = pattern:gsub(DOUBLE_STAR, ".*") -- ** matches anything including /
  pattern = pattern:gsub(SINGLE_STAR, "[^/]*") -- * matches anything except /
  return "^" .. pattern .. "$"
end

-- Check if a file path matches any of the given glob patterns
-- Follows gitignore-style matching:
--   *.pb.go      → match basename anywhere
--   /*.pb.go     → match only in root (leading / anchors)
--   foo/*.pb.go  → match in foo/ directory
--   **/*.pb.go   → match anywhere (explicit)
function M.matches_any_pattern(path, patterns)
  if not patterns or #patterns == 0 then
    return false
  end
  local basename = path:match("([^/]+)$") or path
  for _, glob in ipairs(patterns) do
    local match_target
    local match_pattern

    if glob:sub(1, 1) == "/" then
      -- Leading / anchors to root - match full path against pattern without /
      match_target = path
      match_pattern = M.glob_to_pattern(glob:sub(2))
    elseif glob:find("/") then
      -- Contains / but no leading / - match full path
      match_target = path
      match_pattern = M.glob_to_pattern(glob)
    else
      -- No / at all - match basename only (matches anywhere)
      match_target = basename
      match_pattern = M.glob_to_pattern(glob)
    end

    if match_target:match(match_pattern) then
      return true
    end
  end
  return false
end

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
function M.apply(files, ignore_patterns)
  if not ignore_patterns or #ignore_patterns == 0 then
    return files
  end

  local filtered = {}
  for _, file in ipairs(files) do
    if not M.matches_any_pattern(file.path, ignore_patterns) then
      filtered[#filtered + 1] = file
    end
  end

  return filtered
end

return M
