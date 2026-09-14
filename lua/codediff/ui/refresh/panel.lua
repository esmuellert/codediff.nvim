-- Session-owned panel data and comparison definitions. No windows or tree nodes.
local M = {}
local git = require("codediff.core.git")
local path = require("codediff.core.path")
local policy = require("codediff.ui.refresh.policy")

function M.new(session_config)
  local panel = session_config.panel
  local data = vim.deepcopy(panel.data or {})
  data.git_root = session_config.git_root
  if panel.name == "explorer" then
    data.base_revision = session_config.original_revision
    data.target_revision = session_config.modified_revision
    data.status_result = data.status_result or { unstaged = {}, staged = {}, conflicts = {} }
    if not data.git_root then
      data.dir1, data.dir2 = session_config.original.absolute, session_config.modified.absolute
    end
  else
    data.opts = { range = data.range, file_path = data.file_path, base_revision = data.base_revision, line_range = data.line_range }
    data.commits, data.files = data.commits or {}, {}
  end
  return data
end

-- Resolve requested refs without replacing their symbolic dependency identities.
function M.resolve(config, done)
  local remaining, failure = 1, nil
  local function settled(err)
    failure = failure or err
    remaining = remaining - 1
    if remaining == 0 then
      done(failure, config)
    end
  end
  for _, side in ipairs({ "original", "modified" }) do
    local revision = config[side .. "_revision"]
    if revision and not policy.is_working(revision) and not revision:match("^:[0-3]:?$") then
      remaining = remaining + 1
      git.resolve_revision(revision, config.git_root, function(err, hash)
        vim.schedule(function()
          config[side .. "_revision"] = hash
          settled(err)
        end)
      end)
    end
  end
  settled()
end

function M.read(session, done)
  local panel, data = session.panel, session.panel.data
  local next_data = vim.tbl_extend("force", {}, data)
  local function status_result(err, status)
    vim.schedule(function()
      next_data.status_result = status
      done(err, next_data)
    end)
  end
  if panel.name == "history" then
    local opts = { no_merges = true, path = data.opts.file_path }
    local range = data.opts.range or ""
    if range == "" then
      opts.limit = 100
    end
    git.get_commit_list(range, data.git_root, opts, function(err, commits)
      vim.schedule(function()
        next_data.commits = commits
        done(err, next_data)
      end)
    end)
    return
  end

  local function fetch_status()
    if not data.git_root then
      status_result(nil, require("codediff.core.dir").diff_directories(data.dir1, data.dir2).status_result)
    elseif next_data.target_revision == ":0" then
      git.get_diff_staged(next_data.base_revision, data.git_root, status_result, data.pathspec)
    elseif next_data.base_revision and next_data.target_revision and next_data.target_revision ~= "WORKING" then
      git.get_diff_revisions_with_line_stats(next_data.base_revision, next_data.target_revision, data.git_root, status_result, data.pathspec)
    elseif next_data.base_revision then
      git.get_diff_revision_with_line_stats(next_data.base_revision, data.git_root, status_result, data.pathspec)
    else
      git.get_status_with_line_stats(data.git_root, status_result, data.pathspec)
    end
  end
  if not data.source_revisions then
    fetch_status()
    return
  end
  M.resolve({
    git_root = data.git_root,
    original_revision = data.source_revisions.original,
    modified_revision = data.source_revisions.modified,
  }, function(err, resolved)
    if err then
      done(err)
      return
    end
    next_data.base_revision, next_data.target_revision = resolved.original_revision, resolved.modified_revision
    fetch_status()
  end)
end

-- Keep the old group's slot when staging removes its selected entry (#347).
function M.reselect(previous, status)
  local selected = previous.current_selection
  if not selected then
    return
  end
  local function find(group)
    for _, file in ipairs(status[group] or {}) do
      if file.path == selected.path then
        return vim.tbl_extend("force", file, { group = group, git_root = previous.git_root })
      end
    end
  end
  local group = selected.group
  if group then
    local same = find(group)
    if same then
      return same
    end
    for i, file in ipairs((previous.status_result or {})[group] or {}) do
      if file.path == selected.path and #(status[group] or {}) > 0 then
        return vim.tbl_extend("force", status[group][math.min(i, #status[group])], { group = group, git_root = previous.git_root })
      end
    end
  end
  for _, candidate in ipairs({ "conflicts", "unstaged", "staged" }) do
    local file = find(candidate)
    if file then
      return file
    end
  end
end

function M.same_selection(first, second)
  if not first or not second then
    return first == second
  end
  for _, key in ipairs({ "path", "group", "status", "old_path", "commit_hash" }) do
    if first[key] ~= second[key] then
      return false
    end
  end
  return true
end

function M.set_selection(panel, file)
  local data = panel.data
  data.current_selection = file and vim.deepcopy(file) or nil
  if panel.name == "explorer" then
    data.current_file_path, data.current_file_group = file and file.path, file and file.group
  else
    data.current_file, data.current_commit = file and file.path, file and file.commit_hash
  end
end

-- A selection defines its sources here; input refresh never infers them from UI state.
function M.comparison(panel, file)
  local data = panel.data
  file = file or data.current_selection
  if not file or not file.path or file.path == "" then
    return
  end
  local original, modified = file.old_path or file.path, file.path
  local original_revision, modified_revision, conflict, line_range
  if panel.name == "history" then
    if not file.commit_hash or file.commit_hash == "" then
      return
    end
    original_revision = data.opts.base_revision or (file.commit_hash .. "^")
    modified_revision = file.commit_hash
    original = data.opts.base_revision and file.path or original
    line_range = data.opts.line_range
  elseif data.git_root then
    local refs = data.source_revisions or {}
    if file.group == "conflicts" then
      local ours_right = require("codediff.config").options.diff.conflict_ours_position ~= "left"
      original_revision, modified_revision = ours_right and ":3" or ":2", ours_right and ":2" or ":3"
      conflict = true
    elseif data.base_revision then
      original_revision = refs.original or data.base_revision
      modified_revision = refs.modified or data.target_revision or "WORKING"
    elseif file.group == "staged" then
      original_revision, modified_revision = "HEAD", ":0"
    else
      original_revision, modified_revision = "HEAD", "WORKING"
      for _, staged in ipairs(data.status_result.staged or {}) do
        if staged.path == file.path then
          original_revision = ":0"
          break
        end
      end
      if file.status == "D" then
        original_revision = ":0"
      end
    end
  end
  local single_side
  if data.git_root then
    if file.status == "??" or file.status == "A" then
      single_side, original_revision = "modified", nil
    elseif file.status == "D" then
      single_side, modified_revision = "original", nil
    end
  end
  return {
    git_root = data.git_root,
    original = single_side == "modified" and path.empty() or path.make_ref(original, data.git_root or data.dir1),
    modified = single_side == "original" and path.empty() or path.make_ref(modified, data.git_root or data.dir2),
    original_revision = original_revision ~= "WORKING" and original_revision or nil,
    modified_revision = modified_revision ~= "WORKING" and modified_revision or nil,
    source_revisions = { original = original_revision, modified = modified_revision },
    conflict = conflict,
    single_side = single_side,
    line_range = line_range,
  }
end

function M.load_files(data, hash, done)
  if data.files[hash] then
    done(nil, data.files[hash])
    return
  end
  git.get_commit_files(hash, data.git_root, function(err, files)
    vim.schedule(function()
      if err then
        done(err)
        return
      end
      local filter = require("codediff.ui.explorer.filter")
      local options = require("codediff.config").options.explorer.file_filter or {}
      done(nil, filter.apply(files, options.ignore or {}))
    end)
  end)
end

return M
