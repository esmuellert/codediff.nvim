-- Creates side-by-side diff views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local helpers = require("codediff.ui.view.helpers")
local readiness = require("codediff.ui.view.readiness")
local render = require("codediff.ui.view.render")
local conflict_view = require("codediff.ui.conflict.view")
local view_keymaps = require("codediff.ui.view.keymaps")
local panel = require("codediff.ui.view.panel")
local welcome_window = require("codediff.ui.view.welcome_window")

local is_virtual_revision = helpers.is_virtual_revision
local prepare_buffer = helpers.prepare_buffer
local is_panel_placeholder = helpers.is_panel_placeholder
local show_real_file_buffer = helpers.show_real_file_buffer
local open_real_file = helpers.open_real_file
local compute_and_render = render.compute_and_render
local compute_and_render_conflict = conflict_view.compute_and_render_conflict
local setup_auto_refresh = render.setup_auto_refresh
local setup_conflict_result_window = conflict_view.setup_conflict_result_window
local setup_all_keymaps = view_keymaps.setup_all_keymaps

--- Split direction that lands the modified pane on the side the user asked for.
--- Explicit rather than relying on 'splitright'.
--- @return string
local function diff_split_cmd()
  return config.options.diff.original_position == "right" and "leftabove vsplit" or "rightbelow vsplit"
end

--- Open the two panes with throwaway scratch buffers, for a session whose
--- content arrives later via the panel.
--- @param tabpage number
--- @return number original_win, number modified_win, table original_info, table modified_info
local function open_placeholder_panes(tabpage)
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd(diff_split_cmd())
  local modified_win = vim.api.nvim_get_current_win()

  -- A buffer each, so the tab's initial buffer can be deleted afterwards.
  local orig_scratch = vim.api.nvim_create_buf(false, true)
  local mod_scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[orig_scratch].buftype = "nofile"
  vim.bo[mod_scratch].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, orig_scratch, "CodeDiff " .. tabpage .. ".1")
  pcall(vim.api.nvim_buf_set_name, mod_scratch, "CodeDiff " .. tabpage .. ".2")
  vim.api.nvim_win_set_buf(original_win, orig_scratch)
  vim.api.nvim_win_set_buf(modified_win, mod_scratch)
  welcome_window.sync(original_win)
  welcome_window.sync(modified_win)

  return original_win, modified_win, { bufnr = orig_scratch }, { bufnr = mod_scratch }
end

--- Show one side's content in `win`, whether it is a git revision or a real file.
--- @param win number
--- @param info table From prepare_buffer
--- @param is_virtual boolean
local function load_side(win, info, is_virtual)
  if is_virtual then
    if info.needs_edit then
      vim.cmd("edit! " .. vim.fn.fnameescape(info.target))
      info.bufnr = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(win, info.bufnr)
    end
  elseif info.needs_edit then
    info.bufnr = open_real_file(win, info.target)
  else
    show_real_file_buffer(win, info.bufnr)
  end
end

--- Open the two panes with the diff's actual content loaded.
--- @param session_config SessionConfig
--- @return number original_win, number modified_win, table original_info, table modified_info
local function open_diff_panes(session_config)
  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  local original_info = prepare_buffer(original_is_virtual, session_config.git_root, session_config.original_revision, session_config.original)
  local modified_info = prepare_buffer(modified_is_virtual, session_config.git_root, session_config.modified_revision, session_config.modified)

  local original_win = vim.api.nvim_get_current_win()
  load_side(original_win, original_info, original_is_virtual)

  vim.cmd(diff_split_cmd())
  local modified_win = vim.api.nvim_get_current_win()
  load_side(modified_win, modified_info, modified_is_virtual)

  welcome_window.sync(original_win)
  welcome_window.sync(modified_win)

  return original_win, modified_win, original_info, modified_info
end

--- Window options both diff panes get. 'wrap' is load-bearing for native
--- scrollbind alignment. 'number'/'relativenumber' are left alone so the
--- user's own settings survive.
--- @param original_win number
--- @param modified_win number
local function apply_pane_options(original_win, modified_win)
  local win_opts = {
    cursorline = true,
    wrap = false,
    list = false,
  }
  for opt, val in pairs(win_opts) do
    vim.wo[original_win][opt] = val
    vim.wo[modified_win][opt] = val
  end
end

--- Reapply-keymaps callback stored on the session, so a shape change (panel
--- appearing, layout toggle) can reinstall the right mappings.
--- @param tabpage number
--- @param opts? table { conflict: boolean }
--- @return function
local function make_reapply_keymaps(tabpage, opts)
  local is_conflict = opts and opts.conflict or false
  return function()
    local ob, mb = lifecycle.get_buffers(tabpage)
    if not ob or not mb then
      return
    end
    if is_conflict then
      setup_all_keymaps(tabpage, ob, mb, false)
      require("codediff.ui.conflict").setup_keymaps(tabpage)
    else
      setup_all_keymaps(tabpage, ob, mb, lifecycle.get_panel_name(tabpage) == "explorer")
    end
  end
end

--- Attach the panels, announce the view, and describe it to the caller.
--- @param tabpage number
--- @param session_config SessionConfig
--- @param original_win number
--- @param modified_win number
--- @param original_info table
--- @param modified_info table
--- @return table
local function finish_create(tabpage, session_config, original_win, modified_win, original_info, modified_info)
  panel.setup_explorer(tabpage, session_config, original_win, modified_win)
  panel.setup_history(tabpage, session_config, original_win, modified_win)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffOpen",
    modeline = false,
    data = {
      tabpage = tabpage,
      mode = lifecycle.event_mode(session_config.panel),
    },
  })

  return {
    original_buf = original_info.bufnr,
    modified_buf = modified_info.bufnr,
    original_win = original_win,
    modified_win = modified_win,
  }
end

--- Render a 3-way merge: fetch the merge base, diff both sides against it,
--- then register the session and open the result pane.
--- @param ctx table { tabpage, session_config, wins, infos, lines, on_ready }
local function render_conflict_view(ctx)
  local git = require("codediff.core.git")
  local session_config = ctx.session_config
  local tabpage = ctx.tabpage
  local original_win, modified_win = ctx.original_win, ctx.modified_win
  local original_info, modified_info = ctx.original_info, ctx.modified_info

  git.get_file_content(":1", session_config.git_root, session_config.original.relative, function(err, base_lines)
    -- Add/add conflicts (AA) have no base version; treat it as empty.
    if err then
      base_lines = {}
    end

    vim.schedule(function()
      local conflict_diffs = compute_and_render_conflict(
        original_info.bufnr,
        modified_info.bufnr,
        base_lines,
        ctx.original_lines,
        ctx.modified_lines,
        original_win,
        modified_win,
        config.options.diff.jump_to_first_change
      )
      if not conflict_diffs then
        return
      end

      lifecycle.create_session(tabpage, session_config, {
        original_bufnr = original_info.bufnr,
        modified_bufnr = modified_info.bufnr,
        original_win = original_win,
        modified_win = modified_win,
        lines_diff = conflict_diffs.base_to_modified_diff,
        reapply_keymaps = make_reapply_keymaps(tabpage, { conflict = true }),
      })

      local success = setup_conflict_result_window(tabpage, session_config, original_win, modified_win, base_lines, conflict_diffs, false)
      if success then
        setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, false)
        -- After setup_all_keymaps, so the conflict mappings win.
        require("codediff.ui.conflict").setup_keymaps(tabpage)
      end

      if ctx.on_ready then
        ctx.on_ready()
      end
    end)
  end)
end

--- Render an ordinary two-pane diff and register the session.
--- @param ctx table { tabpage, session_config, wins, infos, lines, virtual flags, on_ready }
local function render_diff_view(ctx)
  local session_config = ctx.session_config
  local tabpage = ctx.tabpage
  local original_info, modified_info = ctx.original_info, ctx.modified_info

  local lines_diff = compute_and_render(
    original_info.bufnr,
    modified_info.bufnr,
    ctx.original_lines,
    ctx.modified_lines,
    ctx.original_is_virtual,
    ctx.modified_is_virtual,
    ctx.original_win,
    ctx.modified_win,
    config.options.diff.jump_to_first_change
  )
  if not lines_diff then
    return
  end

  lifecycle.create_session(tabpage, session_config, {
    original_bufnr = original_info.bufnr,
    modified_bufnr = modified_info.bufnr,
    original_win = ctx.original_win,
    modified_win = ctx.modified_win,
    lines_diff = lines_diff,
    reapply_keymaps = make_reapply_keymaps(tabpage),
  })

  -- Real file buffers only; virtual ones never change under us.
  setup_auto_refresh(original_info.bufnr, modified_info.bufnr, ctx.original_is_virtual, ctx.modified_is_virtual)
  setup_all_keymaps(tabpage, original_info.bufnr, modified_info.bufnr, false)
  require("codediff.ui.follow_working_file").enable(tabpage, ctx.original_is_virtual, ctx.modified_is_virtual)

  if ctx.on_ready then
    ctx.on_ready()
  end
end

--- Run `render` once both panes hold their final content. Virtual buffers
--- load asynchronously via BufReadCmd; real files only need the pending :edit.
--- @param tabpage number
--- @param original_info table
--- @param modified_info table
--- @param original_is_virtual boolean
--- @param modified_is_virtual boolean
--- @param render function
local function render_when_loaded(tabpage, original_info, modified_info, original_is_virtual, modified_is_virtual, render)
  local awaited = {}
  if original_is_virtual then
    awaited[#awaited + 1] = "original"
  end
  if modified_is_virtual then
    awaited[#awaited + 1] = "modified"
  end
  if #awaited == 0 then
    vim.schedule(render)
    return
  end

  local group = vim.api.nvim_create_augroup("CodeDiffVirtualFileHighlight_" .. tabpage, { clear = true })
  local ready = readiness.when_all(awaited, function()
    vim.schedule(render)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      local buf = event.data and event.data.buf
      if not buf then
        return
      end
      if original_is_virtual and buf == original_info.bufnr then
        ready.done("original")
      end
      if modified_is_virtual and buf == modified_info.bufnr then
        ready.done("modified")
      end
    end,
  })
end

---@param session_config SessionConfig
---@param filetype? string
---@param on_ready? function
---@return table|nil
function M.create(session_config, filetype, on_ready)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local initial_buf = vim.api.nvim_get_current_buf()

  local placeholder = is_panel_placeholder(session_config)
  local original_win, modified_win, original_info, modified_info

  if placeholder then
    original_win, modified_win, original_info, modified_info = open_placeholder_panes(tabpage)
  else
    original_win, modified_win, original_info, modified_info = open_diff_panes(session_config)
  end

  -- Clean up initial buffer
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= original_info.bufnr and initial_buf ~= modified_info.bufnr then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  apply_pane_options(original_win, modified_win)

  if placeholder then
    -- The panel populates this session on first file selection.
    lifecycle.create_session(tabpage, session_config, {
      original_bufnr = original_info.bufnr,
      modified_bufnr = modified_info.bufnr,
      original_win = original_win,
      modified_win = modified_win,
      lines_diff = {}, -- Empty diff result - will be updated on first file selection
      reapply_keymaps = make_reapply_keymaps(tabpage),
    })
  else
    local original_is_virtual = is_virtual_revision(session_config.original_revision)
    local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

    local render = function()
      -- The panes may have been closed, or the buffers wiped, while we waited.
      if not vim.api.nvim_win_is_valid(original_win) or not vim.api.nvim_win_is_valid(modified_win) then
        return
      end
      if not vim.api.nvim_buf_is_valid(original_info.bufnr) or not vim.api.nvim_buf_is_valid(modified_info.bufnr) then
        return
      end

      -- Called from vim.schedule, possibly with another tab current. syncbind
      -- and friends act on the current tab, so switch to ours first.
      local target_tab = vim.api.nvim_win_get_tabpage(modified_win)
      if vim.api.nvim_get_current_tabpage() ~= target_tab then
        vim.api.nvim_set_current_tabpage(target_tab)
      end

      -- Read from the buffers, the single source of truth.
      local ctx = {
        tabpage = tabpage,
        session_config = session_config,
        original_win = original_win,
        modified_win = modified_win,
        original_info = original_info,
        modified_info = modified_info,
        original_lines = vim.api.nvim_buf_get_lines(original_info.bufnr, 0, -1, false),
        modified_lines = vim.api.nvim_buf_get_lines(modified_info.bufnr, 0, -1, false),
        original_is_virtual = original_is_virtual,
        modified_is_virtual = modified_is_virtual,
        on_ready = on_ready,
      }

      if session_config.conflict then
        render_conflict_view(ctx)
      else
        render_diff_view(ctx)
      end
    end

    render_when_loaded(tabpage, original_info, modified_info, original_is_virtual, modified_is_virtual, render)
  end

  return finish_create(tabpage, session_config, original_win, modified_win, original_info, modified_info)
end

return M
