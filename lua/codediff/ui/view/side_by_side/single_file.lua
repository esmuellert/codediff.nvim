-- Displays one-sided files in a side-by-side session.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local auto_refresh = require("codediff.ui.auto_refresh")
local core = require("codediff.ui.core")
local path = require("codediff.core.path")
local layout = require("codediff.ui.layout")
local helpers = require("codediff.ui.view.helpers")
local welcome_window = require("codediff.ui.view.welcome_window")

local show_real_file_buffer = helpers.show_real_file_buffer

--- True when the pane already shows exactly what this call would render.
--- Explorer refreshes re-select the file that is already open. For real diffs
--- on_file_select short-circuits that, but untracked/added/deleted files return
--- before reaching its guard, so the window was torn down and rebuilt on every
--- refresh, and the layout pass at the end of the rebuild discarded any pane
--- the user had resized. Comparing the displayed buffer covers path and
--- revision at once, since virtual revisions resolve to distinct buffers.
---@param session table
---@param opts table
---@return boolean
local function single_file_unchanged(session, opts)
  if not session.single_pane then
    return false
  end
  if session.single_side ~= (opts.highlight ~= false and opts.keep or nil) then
    return false
  end
  local keep_win = opts.keep == "original" and session.original_win or session.modified_win
  local other_win = opts.keep == "original" and session.modified_win or session.original_win
  if other_win and vim.api.nvim_win_is_valid(other_win) then
    return false
  end
  if not keep_win or not vim.api.nvim_win_is_valid(keep_win) then
    return false
  end
  return vim.api.nvim_win_get_buf(keep_win) == opts.load_bufnr
end

--- Core implementation for showing a single file without diff.
--- Closes the empty pane and loads the file into the remaining pane.
---@param tabpage number
---@param opts { keep: "original"|"modified", load_bufnr: number, original_path: string, modified_path: string, original_revision: string?, modified_revision: string?, highlight: boolean? }
local function show_single_file(tabpage, opts)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  if single_file_unchanged(session, opts) then
    return
  end

  lifecycle.update_layout(tabpage, "side-by-side")
  local orig_win, mod_win = lifecycle.get_windows(tabpage)

  -- Clear highlights from current session buffers
  local old_orig_buf, old_mod_buf = lifecycle.get_buffers(tabpage)
  if old_orig_buf then
    auto_refresh.disable(old_orig_buf)
    lifecycle.clear_highlights(old_orig_buf)
  end
  if old_mod_buf then
    auto_refresh.disable(old_mod_buf)
    lifecycle.clear_highlights(old_mod_buf)
  end

  -- Mark single-pane BEFORE closing window (prevents cleanup trigger)
  session.single_pane = true

  -- Leaving conflict mode: close the result window too, mirroring M.update.
  -- Without this the 3rd conflict pane survives under the single-file view, and
  -- returning to the conflict file reuses that stale window whose buffer still
  -- has unsaved merge edits, so `:edit` fails with E37. Closing is forced so it
  -- also works when 'hidden' is off; the buffer only becomes hidden, never
  -- unloaded, so in-progress merge edits are preserved.
  local _, old_result_win = lifecycle.get_result(tabpage)
  if old_result_win and vim.api.nvim_win_is_valid(old_result_win) then
    vim.w[old_result_win].codediff_restore = nil
    pcall(vim.api.nvim_win_close, old_result_win, true)
  end
  lifecycle.set_result(tabpage, nil, nil)

  -- Close the unused window
  local keep_win, close_win
  if opts.keep == "modified" then
    keep_win, close_win = mod_win, orig_win
  else
    keep_win, close_win = orig_win, mod_win
  end

  if keep_win == close_win then
    close_win = nil
  end
  if (not keep_win or not vim.api.nvim_win_is_valid(keep_win)) and close_win and vim.api.nvim_win_is_valid(close_win) then
    keep_win = close_win
    close_win = nil
  end

  if not keep_win or not vim.api.nvim_win_is_valid(keep_win) then
    keep_win = helpers.open_pane_from_panel(tabpage, session)
  end

  -- Load the file into the kept window BEFORE closing the other one. Virtual
  -- buffers (from load_virtual_file) carry `bufhidden = "wipe"` so they get
  -- wiped as soon as they have no window; closing close_win first would leave
  -- the freshly-created virtual buffer with no window, wiping it before we can
  -- set it into keep_win — producing "Invalid buffer id" (#498).
  if keep_win and vim.api.nvim_win_is_valid(keep_win) then
    show_real_file_buffer(keep_win, opts.load_bufnr)
  end

  if close_win and vim.api.nvim_win_is_valid(close_win) then
    vim.w[close_win].codediff_restore = nil
    vim.api.nvim_win_close(close_win, true)
    close_win = nil
  end

  if keep_win and vim.api.nvim_win_is_valid(keep_win) then
    welcome_window.sync(keep_win)

    if opts.keep == "original" then
      session.original_win = keep_win
      session.modified_win = nil
    else
      session.original_win = nil
      session.modified_win = keep_win
    end

    -- Create a scratch buffer as placeholder for the empty side
    local empty_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[empty_buf].buftype = "nofile"

    local orig_bufnr = opts.keep == "original" and opts.load_bufnr or empty_buf
    local mod_bufnr = opts.keep == "modified" and opts.load_bufnr or empty_buf

    lifecycle.update_buffers(tabpage, orig_bufnr, mod_bufnr)
    lifecycle.update_paths(tabpage, path.make_ref(opts.original_path or "", session.git_root), path.make_ref(opts.modified_path or "", session.git_root))
    lifecycle.update_revisions(tabpage, opts.original_revision, opts.modified_revision)
    lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
    session.single_side = opts.highlight ~= false and opts.keep or nil
    if session.single_side then
      core.render_whole_file(opts.load_bufnr, session.single_side)
    end

    local view_keymaps = require("codediff.ui.view.keymaps")
    view_keymaps.setup_all_keymaps(tabpage, orig_bufnr, mod_bufnr, session.panel ~= nil and session.panel.name == "explorer")
  end

  layout.arrange(tabpage)
  if keep_win and vim.api.nvim_win_is_valid(keep_win) then
    welcome_window.sync_later(keep_win)
  end
end

-- Load a real file from disk, return bufnr
local function load_real_file(file_path)
  local bufnr = vim.fn.bufadd(file_path)
  vim.fn.bufload(bufnr)
  return bufnr
end

-- Load a virtual file from git revision, return bufnr
local function load_virtual_file(git_root, revision, file_path)
  local virtual_file_mod = require("codediff.core.virtual_file")
  local url = virtual_file_mod.create_url(git_root, revision, file_path)
  local bufnr = vim.fn.bufadd(url)
  vim.fn.bufload(bufnr)
  return bufnr
end

--- Show an untracked file (status "??") — modified pane only
function M.show_untracked_file(tabpage, file_path)
  show_single_file(tabpage, {
    keep = "modified",
    load_bufnr = load_real_file(file_path),
    file_path = file_path,
    modified_path = file_path,
  })
end

--- Show a deleted file (status "D", working tree) — original pane only
function M.show_deleted_file(tabpage, git_root, file_path, abs_path, group)
  local revision = (group == "staged") and "HEAD" or ":0"
  show_single_file(tabpage, {
    keep = "original",
    load_bufnr = load_virtual_file(git_root, revision, file_path),
    file_path = abs_path,
    load_revision = revision,
    load_git_root = git_root,
    rel_path = file_path,
    original_path = abs_path,
    original_revision = revision,
  })
end

--- Show an added virtual file (status "A") — modified pane only
function M.show_added_virtual_file(tabpage, git_root, file_path, revision)
  show_single_file(tabpage, {
    keep = "modified",
    load_bufnr = load_virtual_file(git_root, revision, file_path),
    file_path = file_path,
    load_revision = revision,
    load_git_root = git_root,
    rel_path = file_path,
    modified_path = file_path,
    modified_revision = revision,
  })
end

--- Show a deleted virtual file (status "D", two-revision mode) — original pane only
function M.show_deleted_virtual_file(tabpage, git_root, file_path, revision)
  show_single_file(tabpage, {
    keep = "original",
    load_bufnr = load_virtual_file(git_root, revision, file_path),
    file_path = file_path,
    load_revision = revision,
    load_git_root = git_root,
    rel_path = file_path,
    original_path = file_path,
    original_revision = revision,
  })
end

--- Show the welcome page in a single pane (modified side)
function M.show_welcome(tabpage, load_bufnr)
  show_single_file(tabpage, {
    keep = "modified",
    highlight = false,
    load_bufnr = load_bufnr,
  })
end

return M
