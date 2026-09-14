-- Creates inline diff views.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")
local welcome_window = require("codediff.ui.view.welcome_window")
local helpers = require("codediff.ui.view.helpers")
local panel = require("codediff.ui.view.panel")
local buffers = require("codediff.ui.view.inline_view.buffers")
local inline_render = require("codediff.ui.view.inline_view.render")
local inline_keymaps = require("codediff.ui.view.inline_view.keymaps")

local is_virtual_revision = helpers.is_virtual_revision
local prepare_buffer = helpers.prepare_buffer
local is_panel_placeholder = helpers.is_panel_placeholder
local show_real_file_buffer = helpers.show_real_file_buffer
local open_real_file = helpers.open_real_file
local set_scratch_lines = buffers.set_scratch_lines
local new_scratch = buffers.new_scratch
local compute_and_render_inline = inline_render.compute_and_render_inline
local setup_keymaps = inline_keymaps.setup

-- Helper: mark session as inline layout after creation
local function mark_inline(tabpage)
  lifecycle.update_layout(tabpage, "inline")
end

--- Options for the single inline pane. No 'list' here: side-by-side sets it
--- to keep the two panes visually identical, which does not apply to one pane.
--- @param win number
local function apply_pane_options(win)
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
end

--- Reapply-keymaps callback stored on the session.
--- @param tabpage number
--- @param original_bufnr number
--- @return function
local function make_reapply_keymaps(tabpage, original_bufnr)
  return function()
    local _, mb = lifecycle.get_buffers(tabpage)
    if mb then
      setup_keymaps(tabpage, original_bufnr, mb)
    end
  end
end

--- Attach the panels, lay the tab out, announce the view, and describe it.
--- @param tabpage number
--- @param session_config SessionConfig
--- @param modified_win number
--- @param original_bufnr number
--- @param modified_bufnr number
--- @return table
local function finish_create(tabpage, session_config, modified_win, original_bufnr, modified_bufnr)
  panel.setup_explorer(tabpage, session_config, modified_win, modified_win)
  panel.setup_history(tabpage, session_config, modified_win, modified_win)

  layout.arrange(tabpage)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffOpen",
    modeline = false,
    data = { tabpage = tabpage, mode = lifecycle.event_mode(session_config.panel), layout = "inline" },
  })

  return { modified_buf = modified_bufnr, original_buf = original_bufnr, modified_win = modified_win }
end

--- Open the single pane with a scratch buffer, for a session whose content
--- arrives later via the panel. The hidden original side gets a scratch buffer
--- too, so the session always has two buffers to talk about.
--- @param tabpage number
--- @param modified_win number
--- @return number original_bufnr, number modified_bufnr
local function open_placeholder_pane(tabpage, modified_win)
  local mod_scratch = new_scratch()
  pcall(vim.api.nvim_buf_set_name, mod_scratch, "CodeDiff " .. tabpage .. ".inline")
  vim.api.nvim_win_set_buf(modified_win, mod_scratch)
  welcome_window.sync(modified_win)

  return new_scratch(), mod_scratch
end

--- Show the modified side in the visible pane.
--- @param win number
--- @param info table From prepare_buffer; info.bufnr is updated in place
--- @param is_virtual boolean
local function load_visible_side(win, info, is_virtual)
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
  welcome_window.sync(win)
end

--- Materialise the original side, which inline never puts in a window.
--- A codediff:// buffer carries bufhidden=wipe, so with no window showing it
--- :edit would destroy it at once; it gets a scratch buffer instead.
--- @param info table From prepare_buffer; info.bufnr is updated in place
--- @param is_virtual boolean
local function load_hidden_original(info, is_virtual)
  if is_virtual and info.needs_edit then
    info.bufnr = new_scratch()
  elseif info.needs_edit then
    local bufnr = vim.fn.bufadd(info.target)
    vim.fn.bufload(bufnr)
    info.bufnr = bufnr
  end
end

--- Call `render` once the modified buffer's virtual content has loaded.
--- @param tabpage number
--- @param modified_bufnr number
--- @param render function
local function render_after_modified_loads(tabpage, modified_bufnr, render)
  local group = vim.api.nvim_create_augroup("CodeDiffInlineVirtualLoad_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      if event.data and event.data.buf == modified_bufnr then
        vim.schedule(render)
        vim.api.nvim_del_augroup_by_id(group)
      end
    end,
  })
end

--- Run `render` once both sides hold their content.
--- The original side, when virtual, is fetched here rather than through
--- BufReadCmd, because it has no window to trigger one.
--- @param ctx table { tabpage, session_config, original_info, modified_info, virtual flags }
--- @param render function
local function render_when_loaded(ctx, render)
  local original_info, modified_info = ctx.original_info, ctx.modified_info

  if not ctx.original_is_virtual then
    if ctx.modified_is_virtual then
      render_after_modified_loads(ctx.tabpage, modified_info.bufnr, render)
    else
      vim.schedule(render)
    end
    return
  end

  local git = require("codediff.core.git")
  local session_config = ctx.session_config
  git.get_file_content(session_config.original_revision, session_config.git_root, session_config.original.relative, function(err, lines)
    vim.schedule(function()
      if not set_scratch_lines(original_info.bufnr, err and {} or lines) then
        return
      end

      if ctx.modified_is_virtual then
        render_after_modified_loads(ctx.tabpage, modified_info.bufnr, render)
      else
        render()
      end
    end)
  end)
end

---@param session_config SessionConfig
---@param filetype? string
---@param on_ready? function
---@return table|nil
function M.create(session_config, filetype, on_ready)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local modified_win = vim.api.nvim_get_current_win()
  local initial_buf = vim.api.nvim_get_current_buf()

  --- Drop the tab's starting buffer once the real ones are in place.
  local function drop_initial_buf(...)
    for _, keep in ipairs({ ... }) do
      if initial_buf == keep then
        return
      end
    end
    if vim.api.nvim_buf_is_valid(initial_buf) then
      pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
    end
  end

  if is_panel_placeholder(session_config) then
    local orig_scratch, mod_scratch = open_placeholder_pane(tabpage, modified_win)
    drop_initial_buf(mod_scratch)
    apply_pane_options(modified_win)

    -- The panel populates this session on first file selection.
    lifecycle.create_session(tabpage, session_config, {
      original_bufnr = orig_scratch,
      modified_bufnr = mod_scratch,
      original_win = modified_win,
      modified_win = modified_win, -- both point to the single window
      lines_diff = {},
      reapply_keymaps = make_reapply_keymaps(tabpage, orig_scratch),
    })

    mark_inline(tabpage)
    return finish_create(tabpage, session_config, modified_win, orig_scratch, mod_scratch)
  end

  local original_is_virtual = is_virtual_revision(session_config.original_revision)
  local modified_is_virtual = is_virtual_revision(session_config.modified_revision)

  local original_info = prepare_buffer(original_is_virtual, session_config.git_root, session_config.original_revision, session_config.original)
  local modified_info = prepare_buffer(modified_is_virtual, session_config.git_root, session_config.modified_revision, session_config.modified)

  load_visible_side(modified_win, modified_info, modified_is_virtual)
  load_hidden_original(original_info, original_is_virtual)

  drop_initial_buf(modified_info.bufnr, original_info.bufnr)
  apply_pane_options(modified_win)

  local render = function()
    if not vim.api.nvim_win_is_valid(modified_win) then
      return
    end
    if not vim.api.nvim_buf_is_valid(original_info.bufnr) or not vim.api.nvim_buf_is_valid(modified_info.bufnr) then
      return
    end

    local lines_diff = compute_and_render_inline(
      modified_info.bufnr,
      original_info.bufnr,
      vim.api.nvim_buf_get_lines(original_info.bufnr, 0, -1, false),
      vim.api.nvim_buf_get_lines(modified_info.bufnr, 0, -1, false),
      original_is_virtual,
      modified_is_virtual,
      modified_win,
      config.options.diff.jump_to_first_change
    )
    if not lines_diff then
      return
    end

    lifecycle.create_session(tabpage, session_config, {
      original_bufnr = original_info.bufnr,
      modified_bufnr = modified_info.bufnr,
      original_win = modified_win,
      modified_win = modified_win,
      lines_diff = lines_diff,
      reapply_keymaps = make_reapply_keymaps(tabpage, original_info.bufnr),
    })

    mark_inline(tabpage)

    setup_keymaps(tabpage, original_info.bufnr, modified_info.bufnr)

    -- Keep the diff pointed at the working window's file if it changes. Same
    -- as the side-by-side path: the behaviour belongs to the session shape,
    -- not to a layout.
    require("codediff.ui.follow_working_file").enable(tabpage, original_is_virtual, modified_is_virtual)

    if on_ready then
      on_ready()
    end
  end

  render_when_loaded({
    tabpage = tabpage,
    session_config = session_config,
    original_info = original_info,
    modified_info = modified_info,
    original_is_virtual = original_is_virtual,
    modified_is_virtual = modified_is_virtual,
  }, render)

  return finish_create(tabpage, session_config, modified_win, original_info.bufnr, modified_info.bufnr)
end

return M
