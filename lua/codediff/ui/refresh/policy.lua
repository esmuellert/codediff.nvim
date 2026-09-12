-- Refresh events select data to inspect; they never request a view reset.
local M = {}
local fields = { "worktree", "index", "head", "refs", "buffer", "full", "render" }

function M.normalize(event)
  if type(event) ~= "table" then
    return { full = true }
  end
  local result, known = {}, event.type == "refresh"
  for _, field in ipairs(fields) do
    if event[field] ~= nil then
      known = true
      if event[field] then
        result[field] = true
      end
    end
  end
  return known and result or { full = true }
end

function M.merge(first, second)
  local result = {}
  for _, event in ipairs({ first or {}, second or {} }) do
    for _, field in ipairs(fields) do
      if event[field] then
        result[field] = true
      end
    end
  end
  return result
end

function M.is_working(revision)
  return revision == nil or revision == "WORKING"
end

M.is_fixed = require("codediff.core.git.revision").is_fixed

function M.needs_read(revision, event)
  if event.full then
    return true
  end
  if M.is_working(revision) then
    return event.worktree == true or event.buffer == true
  end
  if type(revision) == "string" and revision:match("^:[0-3]:?$") then
    return event.index == true
  end
  if M.is_fixed(revision) then
    return false
  end
  return event.head == true or event.refs == true
end

function M.panel_needed(panel, event)
  if not panel then
    return false
  end
  if event.full then
    return true
  end
  if panel.name == "history" then
    return event.head == true or event.refs == true
  end
  local view = panel.view or {}
  if not view.git_root and view.dir1 then
    return event.worktree == true
  end
  if view.base_revision then
    local refs = view.source_revisions or {}
    return M.needs_read(refs.original or view.base_revision, event) or M.needs_read(refs.modified or view.target_revision or "WORKING", event)
  end
  return event.worktree == true or event.index == true or event.head == true or event.refs == true
end

return M
