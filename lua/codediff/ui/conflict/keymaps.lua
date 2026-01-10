-- Keymap setup for conflict resolution
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

-- Will be injected by init.lua
local tracking = nil
local actions = nil
local diffget = nil
local navigation = nil
M._set_tracking_module = function(t)
  tracking = t
end
M._set_actions_module = function(a)
  actions = a
end
M._set_diffget_module = function(d)
  diffget = d
end
M._set_navigation_module = function(n)
  navigation = n
end

--- Setup conflict keymaps for a session
--- @param tabpage number
function M.setup_keymaps(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local keymaps = config.options.keymaps.conflict or {}
  local view_keymaps = config.options.keymaps.view or {}

  -- Bind to incoming (left), current (right), AND result buffers
  local buffers = { session.original_bufnr, session.modified_bufnr, session.result_bufnr }

  local base_opts = { noremap = true, silent = true, nowait = true }

  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      -- Unbind normal mode do/dp from view keymaps (they don't apply in merge conflict mode)
      if view_keymaps.diff_get then
        pcall(vim.keymap.del, "n", view_keymaps.diff_get, { buffer = bufnr })
      end
      if view_keymaps.diff_put then
        pcall(vim.keymap.del, "n", view_keymaps.diff_put, { buffer = bufnr })
      end

      -- Accept incoming
      if keymaps.accept_incoming then
        vim.keymap.set(
          "n",
          keymaps.accept_incoming,
          tracking.make_repeatable(function()
            actions.accept_incoming(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Accept incoming change", expr = true })
        )
      end

      -- Accept current
      if keymaps.accept_current then
        vim.keymap.set(
          "n",
          keymaps.accept_current,
          tracking.make_repeatable(function()
            actions.accept_current(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Accept current change", expr = true })
        )
      end

      -- Accept both
      if keymaps.accept_both then
        vim.keymap.set(
          "n",
          keymaps.accept_both,
          tracking.make_repeatable(function()
            actions.accept_both(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Accept both changes", expr = true })
        )
      end

      -- Discard
      if keymaps.discard then
        vim.keymap.set(
          "n",
          keymaps.discard,
          tracking.make_repeatable(function()
            actions.discard(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Discard changes (keep base)", expr = true })
        )
      end

      -- Navigation
      if keymaps.next_conflict then
        vim.keymap.set("n", keymaps.next_conflict, function()
          navigation.navigate_next_conflict(tabpage)
        end, vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Next conflict" }))
      end

      if keymaps.prev_conflict then
        vim.keymap.set("n", keymaps.prev_conflict, function()
          navigation.navigate_prev_conflict(tabpage)
        end, vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Previous conflict" }))
      end

      -- Vimdiff-style diffget from incoming (2do) - only on result buffer
      if keymaps.diffget_incoming and bufnr == session.result_bufnr then
        vim.keymap.set(
          "n",
          keymaps.diffget_incoming,
          tracking.make_repeatable(function()
            diffget.diffget_incoming(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Get hunk from incoming (2do)", expr = true })
        )
      end

      -- Vimdiff-style diffget from current (3do) - only on result buffer
      if keymaps.diffget_current and bufnr == session.result_bufnr then
        vim.keymap.set(
          "n",
          keymaps.diffget_current,
          tracking.make_repeatable(function()
            diffget.diffget_current(tabpage)
          end),
          vim.tbl_extend("force", base_opts, { buffer = bufnr, desc = "Get hunk from current (3do)", expr = true })
        )
      end
    end
  end
end

return M
