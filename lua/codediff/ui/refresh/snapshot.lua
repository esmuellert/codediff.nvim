local M = {}
local api = vim.api
local policy = require("codediff.ui.refresh.policy")

local function lines(buf)
  return buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_lines(buf, 0, -1, false) or { "" }
end

local function normalized(value)
  return value and #value > 0 and value or { "" }
end

local function source(path, revision, resolved)
  return { path = path, revision = revision, resolved = resolved }
end

-- Preserve the requested ref, not just the SHA that happened to resolve at open.
function M.describe(session)
  local requested = session.source_revisions or {}
  local original = requested.original or session.original_revision
  local modified = requested.modified or session.modified_revision
  local panel = session.panel and session.panel.view
  if session.panel and session.panel.name == "explorer" and panel and panel.git_root and panel.current_file_path then
    if session.merge and session.result_bufnr then
      original, modified = session.original_revision, session.modified_revision
    elseif panel.base_revision then
      local refs = panel.source_revisions or {}
      original, modified = refs.original or panel.base_revision, refs.modified or panel.target_revision or "WORKING"
      if session.single_side == "original" then
        modified = nil
      end
    elseif panel.current_file_group == "staged" then
      original, modified = "HEAD", ":0"
    elseif session.single_side == "original" then
      original, modified = ":0", nil
    else
      original, modified = "HEAD", "WORKING"
      for _, file in ipairs((panel.status_result or {}).staged or {}) do
        if file.path == panel.current_file_path then
          original = ":0"
          break
        end
      end
    end
  end
  local description = {
    original = source(session.original, original, session.original_revision),
    modified = source(session.modified, modified, session.modified_revision),
  }
  if session.merge and session.result_bufnr then
    description.base = source(session.original, ":1", ":1")
  end
  return description
end

function M.capture(session)
  local data = { sources = M.describe(session), original = lines(session.original_bufnr), modified = lines(session.modified_bufnr) }
  if session.result_bufnr then
    data.base = vim.deepcopy(session.merge_base_lines or {})
    data.result = lines(session.result_bufnr)
  end
  return data
end

local function same_source(first, second)
  return first and second and first.revision == second.revision and vim.deep_equal(first.path, second.path)
end

function M.same_inputs(first, second)
  if not first or not second then
    return false
  end
  for _, side in ipairs({ "original", "modified", "base" }) do
    if not vim.deep_equal(first[side], second[side]) then
      return false
    end
    if first.sources[side] or second.sources[side] then
      if not same_source(first.sources[side], second.sources[side]) then
        return false
      end
    end
  end
  return true
end

local function real_buffer(path)
  local buf = vim.fn.bufadd(path)
  if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
    return buf
  end
end

local function read_working(session, side, input, event)
  local path = input.path.absolute
  local buf = real_buffer(path)
  if buf then
    -- Never replace unsaved text. checktime follows Neovim's reload safeguards.
    if (event.full or event.worktree) and not vim.bo[buf].modified then
      pcall(vim.cmd, "silent! checktime " .. buf)
    end
    return lines(buf), buf
  end
  if vim.fn.filereadable(path) == 0 then
    return { "" }
  end
  local value = vim.fn.readfile(path)
  for i, text in ipairs(value) do
    value[i] = text:gsub("\r$", "")
  end
  if value[1] then
    value[1] = value[1]:gsub("^\239\187\191", "")
  end
  return normalized(value)
end

-- Read all candidates before touching any displayed input buffer.
function M.read(session, event, previous, done)
  local data = { sources = M.describe(session), ticks = {} }
  local git = require("codediff.core.git")
  local remaining, completed, first_error = 1, false, nil
  local function finish(err)
    first_error = first_error or err
    remaining = remaining - 1
    if remaining == 0 and not completed then
      completed = true
      done(first_error, data)
    end
  end

  for _, side in ipairs({ "original", "modified", "base" }) do
    local input = data.sources[side]
    if input then
      remaining = remaining + 1
      local old = previous and previous.sources[side]
      if not input.path or input.path.absolute == "" then
        data[side] = side == "base" and {} or { "" }
        finish()
      elseif policy.is_working(input.revision) then
        local value, buf = read_working(session, side, input, event)
        data[side] = value
        if buf then
          data.ticks[buf] = api.nvim_buf_get_changedtick(buf)
        end
        finish()
      elseif same_source(input, old) and not policy.needs_read(input.revision, event) then
        -- Buffer events may originate from a programmatic edit of a diff pane.
        data[side] = event.buffer and side ~= "base" and lines(session[side .. "_bufnr"]) or vim.deepcopy(previous[side])
        input.resolved = old.resolved
        finish()
      else
        local function load(resolved)
          input.resolved = resolved
          git.get_file_content(resolved, session.git_root, input.path.relative, function(err, value)
            vim.schedule(function()
              if err and not err:find("not found in revision", 1, true) then
                finish(err)
                return
              end
              data[side] = side == "base" and (value or {}) or normalized(value)
              finish()
            end)
          end)
        end
        if input.revision:match("^:[0-3]:?$") then
          load(input.revision:gsub(":$", ""))
        else
          git.resolve_revision(input.revision, session.git_root, function(err, resolved)
            vim.schedule(function()
              if err then
                finish(err)
              else
                load(resolved)
              end
            end)
          end)
        end
      end
    end
  end
  if session.result_bufnr then
    data.result = lines(session.result_bufnr)
  end
  finish()
end

function M.valid(data)
  for buf, tick in pairs(data.ticks or {}) do
    if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_changedtick(buf) ~= tick then
      return false
    end
  end
  return true
end

M.lines = lines
return M
