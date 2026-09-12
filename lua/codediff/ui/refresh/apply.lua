-- Update an existing comparison without reopening files or resetting editor state.
local M = {}
local api = vim.api
local snapshot = require("codediff.ui.refresh.snapshot")
local policy = require("codediff.ui.refresh.policy")

local function put(buf, value)
  if vim.deep_equal(snapshot.lines(buf), value) then
    return
  end
  local modifiable, readonly = vim.bo[buf].modifiable, vim.bo[buf].readonly
  vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
  api.nvim_buf_set_lines(buf, 0, -1, false, value)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = modifiable, readonly
end

local function materialize(session, side, input, value)
  local buf = session[side .. "_bufnr"]
  if not input.path or input.path.absolute == "" then
    return buf
  end
  if policy.is_working(input.revision) then
    -- Real buffers were reloaded by checktime, never by replacing their text.
    if vim.bo[buf].buftype ~= "" then
      put(buf, value)
    end
    return buf
  end

  if input.resolved ~= session[side .. "_revision"] then
    local virtual = require("codediff.core.virtual_file")
    local name = virtual.create_url(session.git_root, input.resolved, input.path.relative)
    local existing = -1
    for _, candidate in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_get_name(candidate) == name then
        existing = candidate
        break
      end
    end
    if existing ~= -1 and api.nvim_buf_is_loaded(existing) then
      buf = existing
    else
      buf = api.nvim_create_buf(false, true)
      if existing == -1 then
        api.nvim_buf_set_name(buf, name)
      end
      vim.bo[buf].buftype = "nowrite"
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
      vim.bo[buf].readonly = true
      vim.bo[buf].modifiable = false
    end
    session[side .. "_bufnr"] = buf
    local win = session[side .. "_win"]
    local hidden = side == "original" and session.layout == "inline" and session.single_side ~= "original"
    if win and api.nvim_win_is_valid(win) and not hidden then
      api.nvim_win_set_buf(win, buf)
      vim.bo[buf].bufhidden = "wipe"
    end
  end
  require("codediff.core.virtual_file").set_content(buf, value, input.path.relative)
  session[side .. "_revision"] = input.resolved
  return buf
end

local function options()
  local config = require("codediff.config").options.diff
  return {
    max_computation_time_ms = config.max_computation_time_ms,
    ignore_trim_whitespace = config.ignore_trim_whitespace,
    compute_moves = config.compute_moves,
  }
end

function M.result(session)
  if not session.result_bufnr or not api.nvim_buf_is_valid(session.result_bufnr) or not session.result_base_lines then
    return
  end
  local value = snapshot.lines(session.result_bufnr)
  local result = require("codediff.core.diff").compute_diff(session.result_base_lines, value, options())
  if result then
    require("codediff.ui.core").render_single_buffer(session.result_bufnr, result, "modified")
  end
  require("codediff.ui.conflict").refresh(session)
end

function M.run(session, data, previous, redraw)
  local input_changed = not snapshot.same_inputs(previous, data)
  local result_changed = session.result_bufnr and not vim.deep_equal(previous and previous.result, snapshot.lines(session.result_bufnr))
  local seed = session.result_base_lines or {}
  -- Neovim represents an empty Result as one empty line, not an empty array.
  local untouched = vim.deep_equal(snapshot.lines(session.result_bufnr), #seed > 0 and seed or { "" })
  if session.result_bufnr and input_changed and not untouched then
    if not session.refresh.blocked or not snapshot.same_inputs(session.refresh.blocked, data) then
      vim.notify("Conflict inputs changed; Result has unsaved edits. Reopen the conflict view to reload its inputs.", vim.log.levels.WARN)
      session.refresh.blocked = data
    end
    if result_changed or redraw then
      M.result(session)
    end
    return false
  end
  if not input_changed and not redraw then
    if result_changed then
      M.result(session)
    end
    return true
  end

  local views = {}
  for _, side in ipairs({ "original", "modified", "result" }) do
    local win = session[side .. "_win"]
    if win and api.nvim_win_is_valid(win) and not views[win] then
      views[win] = { view = api.nvim_win_call(win, vim.fn.winsaveview), scrollbind = vim.wo[win].scrollbind }
      vim.wo[win].scrollbind = false
    end
  end
  local focused = api.nvim_get_current_win()
  local old_original, old_modified = session.original_bufnr, session.modified_bufnr
  local ok, err = xpcall(function()
    if input_changed then
      materialize(session, "original", data.sources.original, data.original)
      materialize(session, "modified", data.sources.modified, data.modified)
    end
    local core = require("codediff.ui.core")
    local compute = require("codediff.core.diff").compute_diff
    if session.result_bufnr then
      local original = assert(compute(data.base, data.original, options()))
      local modified = assert(compute(data.base, data.modified, options()))
      core.render_merge_view(session.original_bufnr, session.modified_bufnr, original, modified, data.base, data.original, data.modified)
      if input_changed then
        local result, blocks = require("codediff.ui.conflict.merge").compute_auto_merged_result(original, modified, data.base, data.original, data.modified)
        put(session.result_bufnr, result)
        session.result_base_lines, session.merge_base_lines, session.conflict_blocks = result, data.base, blocks
        require("codediff.ui.conflict").initialize_tracking(session.result_bufnr, blocks)
      end
      session.stored_diff_result = modified
      require("codediff.ui.conflict").attach_gutter(session.original_win, session.modified_win)
      M.result(session)
    elseif session.single_side then
      core.render_whole_file(session[session.single_side .. "_bufnr"], session.single_side)
      session.stored_diff_result = { changes = {}, moves = {} }
    else
      local diff = assert(compute(data.original, data.modified, options()))
      if session.layout == "inline" then
        require("codediff.ui.inline").render_inline_diff(session.modified_bufnr, diff, data.original, data.modified)
      else
        core.render_diff(session.original_bufnr, session.modified_bufnr, data.original, data.modified, diff)
      end
      session.stored_diff_result = diff
    end
    session.changedtick.original = api.nvim_buf_get_changedtick(session.original_bufnr)
    session.changedtick.modified = api.nvim_buf_get_changedtick(session.modified_bufnr)
    if old_original ~= session.original_bufnr or old_modified ~= session.modified_bufnr then
      require("codediff.ui.lifecycle").update_buffers(session.refresh.tabpage, session.original_bufnr, session.modified_bufnr)
      if session.reapply_keymaps then
        session.reapply_keymaps()
      end
    end
    require("codediff.ui.view.compact").refresh(session.refresh.tabpage)
  end, debug.traceback)
  for win, saved in pairs(views) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_call(win, function()
        local cursor = require("codediff.ui.view.cursor").clamp_cursor(win, { saved.view.lnum, saved.view.col })
        saved.view.lnum, saved.view.col = cursor[1], cursor[2]
        vim.fn.winrestview(saved.view)
      end)
      vim.wo[win].scrollbind = saved.scrollbind
    end
  end
  if api.nvim_win_is_valid(focused) and api.nvim_get_current_win() ~= focused then
    api.nvim_set_current_win(focused)
  end
  if not ok then
    error(err)
  end
  return true
end

return M
