-- Session CRUD operations for diff views
-- Manages the active_diffs data structure
local M = {}

local config = require("codediff.config")
local virtual_file = require("codediff.core.virtual_file")
local accessors = require("codediff.ui.lifecycle.accessors")

-- Import from sibling modules (will be set by init.lua)
local state = nil
M._set_state_module = function(s)
  state = s
end

-- Track active diff sessions
-- Structure: {
--   tabpage_id = {
--     original_bufnr, modified_bufnr, original_win, modified_win,
--     mode = "standalone" | "explorer",
--     git_root = string?,
--     original_path = string,
--     modified_path = string,
--     original_revision = string?, -- nil | "WORKING" | "STAGED" | commit_hash
--     modified_revision = string?,
--     original_state, modified_state,
--     suspended = bool,
--     stored_diff_result = table,
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

function M.create_session(
  tabpage,
  mode,
  git_root,
  original_path,
  modified_path,
  original_revision,
  modified_revision,
  original_bufnr,
  modified_bufnr,
  original_win,
  modified_win,
  lines_diff,
  reapply_keymaps
)
  -- Save buffer states
  local original_state = state.save_buffer_state(original_bufnr)
  local modified_state = state.save_buffer_state(modified_bufnr)

  -- Create complete session in one step
  active_diffs[tabpage] = {
    -- Mode & Git Context (immutable)
    mode = mode,
    git_root = git_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = original_revision,
    modified_revision = modified_revision,

    -- Buffers & Windows
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
    original_state = original_state,
    modified_state = modified_state,

    -- Lifecycle state
    suspended = false,
    stored_diff_result = lines_diff,
    changedtick = {
      original = vim.api.nvim_buf_get_changedtick(original_bufnr),
      modified = vim.api.nvim_buf_get_changedtick(modified_bufnr),
    },
    mtime = {
      original = state.get_file_mtime(original_bufnr),
      modified = state.get_file_mtime(modified_bufnr),
    },

    -- Explorer reference (only for explorer mode)
    explorer = nil,

    -- Conflict mode result buffer (3-way merge)
    result_bufnr = nil,
    result_win = nil,
    conflict_files = {}, -- Tracks files opened in conflict mode for unsaved warning
    reapply_keymaps = reapply_keymaps,
  }

  -- Mark windows with restore flag
  vim.w[original_win].codediff_restore = 1
  vim.w[modified_win].codediff_restore = 1

  -- Apply inlay hint settings if configured
  if config.options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  -- Setup tab autocmds
  local tab_augroup = vim.api.nvim_create_augroup("codediff_lifecycle_tab_" .. tabpage, { clear = true })

  -- Force disable winbar to prevent alignment issues
  local function ensure_no_winbar()
    if vim.api.nvim_win_is_valid(original_win) then
      vim.wo[original_win].winbar = ""
    end
    if vim.api.nvim_win_is_valid(modified_win) then
      vim.wo[modified_win].winbar = ""
    end
  end

  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
    group = tab_augroup,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      if win == original_win or win == modified_win then
        ensure_no_winbar()
        -- Re-apply critical window options that might get reset by ftplugins/autocmds
        vim.wo[win].wrap = false
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = tab_augroup,
    callback = function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      if current_tab == tabpage then
        accessors.clear_tab_keymaps(tabpage)
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
