-- Session CRUD operations for diff views
-- Manages the active_diffs data structure
local M = {}

local config = require("codediff.config")
local virtual_file = require("codediff.core.virtual_file")
local accessors = require("codediff.ui.lifecycle.accessors")
local keymaps = require("codediff.ui.lifecycle.keymaps")
local welcome_window = require("codediff.ui.view.welcome_window")
-- Eagerly loaded: sessions are created from scheduled callbacks that may run
-- after the CWD changed, and a first-time require would fail there.
local keymap = require("codediff.keymap")

-- Track active diff sessions
-- Structure: {
--   tabpage_id = {
--     original_bufnr, modified_bufnr, original_win, modified_win,
--     panel = { name = "explorer"|"history", view = table? }?, -- nil for a bare diff
--     merge = boolean?, -- 3-way merge view; result_bufnr only says if the pane exists
--     git_root = string?,
--     original = Path,
--     modified = Path,
--     original_revision = string?, -- nil | "WORKING" | "STAGED" | commit_hash
--     modified_revision = string?,
--     original_state, modified_state,
--     suspended = bool,
--     single_side = "original" | "modified" | nil,
--     stored_diff_result = table,
--     compact_mode = boolean, -- session preference; folds may be inactive with no hunks
--     changedtick = { original = number, modified = number },
--     mtime = { original = number?, modified = number? },
--     -- Conflict mode result buffer (3-way merge)
--     result_bufnr = number?,  -- Real file buffer reset to BASE
--     result_win = number?,    -- Bottom window for result
--     conflict_files = table?, -- { [file_path] = true } tracks files opened in conflict mode
--   }
-- }
local active_diffs = {}

-- Get the active_diffs table (for other modules to access)
function M.get_active_diffs()
  return active_diffs
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Compute virtual URI from revision (not stored, computed on-demand)
local function compute_virtual_uri(git_root, revision, path)
  if not is_virtual_revision(revision) then
    return nil
  end
  return virtual_file.create_url(git_root, revision, path)
end

-- Expose compute_virtual_uri for other modules
M.compute_virtual_uri = compute_virtual_uri

--- What a layout produces once it has opened its panes and computed a diff.
--- Everything else is copied from the SessionConfig it was asked to open.
--- @class SessionPanes
--- @field original_bufnr number
--- @field modified_bufnr number
--- @field original_win number
--- @field modified_win number
--- @field lines_diff table? Initial diff result
--- @field reapply_keymaps function? Called when the session's shape changes

--- @param tabpage number
--- @param session_config SessionConfig What was asked for
--- @param panes SessionPanes What the layout built for it
function M.create_session(tabpage, session_config, panes)
  if active_diffs[tabpage] and active_diffs[tabpage].refresh then
    active_diffs[tabpage].refresh:dispose()
  end
  local state = require("codediff.ui.lifecycle.state")
  local original_bufnr, modified_bufnr = panes.original_bufnr, panes.modified_bufnr
  -- Save buffer states
  local original_state = state.save_buffer_state(original_bufnr)
  local modified_state = state.save_buffer_state(modified_bufnr)

  -- Create complete session in one step
  active_diffs[tabpage] = {
    tabpage = tabpage,
    -- Panel data belongs to the session; the sidebar only renders it.
    panel = session_config.panel and { name = session_config.panel.name, data = require("codediff.ui.refresh.panel").new(session_config) } or nil,
    merge = session_config.conflict or nil,
    git_root = session_config.git_root,
    original = session_config.original,
    modified = session_config.modified,
    original_revision = session_config.original_revision,
    modified_revision = session_config.modified_revision,
    source_revisions = session_config.source_revisions,

    -- Buffers & Windows
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = panes.original_win,
    modified_win = panes.modified_win,
    original_state = original_state,
    modified_state = modified_state,

    -- Lifecycle state
    layout = "side-by-side",
    exit_on_close = session_config.exit_on_close == true,
    suspended = false,
    single_side = nil,
    stored_diff_result = panes.lines_diff,
    compact_mode = config.options.diff.compact,
    changedtick = {
      original = vim.api.nvim_buf_get_changedtick(original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(modified_bufnr),
    },
    mtime = {
      original = state.get_file_mtime(original_bufnr),
      modified = state.get_file_mtime(modified_bufnr),
    },

    -- Conflict mode result buffer (3-way merge)
    result_bufnr = nil,
    result_win = nil,
    conflict_files = {}, -- Tracks files opened in conflict mode for unsaved warning
    reapply_keymaps = panes.reapply_keymaps,
    -- Owns every mapping this session installs, so teardown can hand each key
    -- back to whatever owned it before codediff.
    keymaps = keymap.new("codediff-session:" .. tostring(tabpage)),
  }

  welcome_window.capture_session_profiles(active_diffs[tabpage])
  local created = active_diffs[tabpage]
  vim.schedule(function()
    if active_diffs[tabpage] == created then
      require("codediff.ui.refresh").attach(tabpage)
    end
  end)

  -- Mark windows with restore flag
  vim.w[panes.original_win].codediff_restore = 1
  vim.w[panes.modified_win].codediff_restore = 1

  -- Continuously enforce inlay hint settings via LspAttach (handles LazyVim re-enabling)
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  -- Setup tab autocmds
  local tab_augroup = vim.api.nvim_create_augroup("codediff_lifecycle_tab_" .. tabpage, { clear = true })

  -- Re-disable inlay hints when LSP attaches (LazyVim/distributions may re-enable them)
  if config.options.diff.disable_inlay_hints then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = tab_augroup,
      callback = function(ev)
        if not active_diffs[tabpage] then
          return
        end
        vim.schedule(function()
          if vim.api.nvim_get_current_tabpage() == tabpage then
            pcall(vim.lsp.inlay_hint.enable, false, { bufnr = ev.buf })
          end
        end)
      end,
    })
  end

  -- Force disable winbar to prevent alignment issues (except in conflict mode)
  local function sync_window_ui(sess, win)
    -- In conflict mode, preserve existing winbar titles set by the conflict view.
    if sess and sess.result_win and vim.api.nvim_win_is_valid(sess.result_win) then
      return
    end
    -- Normal diff mode: disable winbar
    if sess and sess.original_win and vim.api.nvim_win_is_valid(sess.original_win) then
      vim.wo[sess.original_win].winbar = ""
    end
    if sess and sess.modified_win and vim.api.nvim_win_is_valid(sess.modified_win) then
      vim.wo[sess.modified_win].winbar = ""
    end
  end

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType" }, {
    group = tab_augroup,
    callback = function()
      local sess = active_diffs[tabpage]
      if not sess then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win == sess.original_win or win == sess.modified_win then
        sync_window_ui(sess, win)
        -- Re-apply critical window options that might get reset by ftplugins/autocmds
        vim.wo[win].wrap = false
        welcome_window.sync(win)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = tab_augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        keymaps.clear_tab_keymaps(tabpage)
        state.suspend_diff(tabpage)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = tab_augroup,
    callback = function()
      vim.schedule(function()
        local current_tab = vim.api.nvim_get_current_tabpage()
        if current_tab == tabpage and active_diffs[tabpage] then
          local sess = active_diffs[tabpage]
          -- resume_diff tears the session down when a pane was wiped while we
          -- were away; let it run first so we never reinstall mappings onto a
          -- session that is about to disappear.
          local panes_valid = vim.api.nvim_buf_is_valid(sess.original_bufnr) and vim.api.nvim_buf_is_valid(sess.modified_bufnr)
          if not panes_valid then
            state.resume_diff(tabpage)
            return
          end
          keymaps.restore_tab_keymaps(tabpage)
          if sess.reapply_keymaps then
            pcall(sess.reapply_keymaps)
          end
          state.resume_diff(tabpage)
        end
      end)
    end,
  })
end

return M
