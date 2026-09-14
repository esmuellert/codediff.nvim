-- Read comparison inputs from the session, without consulting a panel or view.
local M = {}
local api = vim.api
local policy = require("codediff.ui.refresh.policy")

function M.lines(buf)
  return buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_lines(buf, 0, -1, false) or { "" }
end

local function normalized(value)
  return value and #value > 0 and value or { "" }
end

function M.describe(session)
  local requested = session.source_revisions or {}
  local sources = {}
  for _, side in ipairs({ "original", "modified" }) do
    sources[side] = {
      path = session[side],
      revision = requested[side] or session[side .. "_revision"],
      resolved = session[side .. "_revision"],
    }
  end
  if session.merge and session.result_bufnr then
    sources.base = { path = session.original, revision = ":1", resolved = ":1" }
  end
  return sources
end

function M.capture(session)
  local data = { sources = M.describe(session), original = M.lines(session.original_bufnr), modified = M.lines(session.modified_bufnr) }
  if session.result_bufnr then
    data.base = vim.deepcopy(session.merge_base_lines or {})
    data.result = M.lines(session.result_bufnr)
  end
  return data
end

local function same_source(first, second)
  return first and second and first.revision == second.revision and vim.deep_equal(first.path, second.path)
end

function M.same(first, second)
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

local function read_working(input, event)
  local path = input.path.absolute
  local buf = vim.fn.bufadd(path)
  if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
    -- Never replace unsaved text. checktime follows Neovim's reload safeguards.
    if (event.full or event.worktree) and not vim.bo[buf].modified then
      pcall(vim.cmd, "silent! checktime " .. buf)
    end
    return M.lines(buf), buf
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

-- Settle every candidate before publishing a new comparison.
function M.read(session, event, previous, done)
  local data = { sources = M.describe(session), ticks = {} }
  local git = require("codediff.core.git")
  local remaining, first_error = 1, nil
  local function finish(err)
    first_error = first_error or err
    remaining = remaining - 1
    if remaining == 0 then
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
        local value, buf = read_working(input, event)
        data[side] = value
        if buf then
          data.ticks[buf] = api.nvim_buf_get_changedtick(buf)
        end
        finish()
      elseif same_source(input, old) and not policy.needs_read(input.revision, event) then
        data[side] = event.buffer and side ~= "base" and M.lines(session[side .. "_bufnr"]) or vim.deepcopy(previous[side])
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
    data.result = M.lines(session.result_bufnr)
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

return M
