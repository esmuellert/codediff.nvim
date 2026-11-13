-- Keymap setup for conflict resolution
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local resolve = require("codediff.keymap.resolve")
local tracking = require("codediff.ui.conflict.tracking")
local resolution = require("codediff.ui.conflict.resolution")
local navigation = require("codediff.ui.conflict.navigation")

-- Dot-repeatable actions are expr mappings (see conflict.tracking).
local REPEATABLE_ACTIONS = {
  { key = "accept_incoming", fn = resolution.accept_incoming, desc = "Accept incoming change" },
  { key = "accept_current", fn = resolution.accept_current, desc = "Accept current change" },
  { key = "accept_both", fn = resolution.accept_both, desc = "Accept both changes" },
  { key = "discard", fn = resolution.discard, desc = "Discard changes (keep base)" },
}

-- Required lazily: the Base view requires codediff.ui.conflict, which loads
-- this module, so a top-level require would be circular. `fn` must be a
-- function taking the tabpage, like every other action.
local TOGGLE_BASE = {
  key = "toggle_base",
  fn = function(tabpage)
    require("codediff.ui.conflict.view.base").toggle(tabpage)
  end,
  desc = "Toggle merge base pane",
}

local PLAIN_ACTIONS = {
  { key = "accept_all_incoming", fn = resolution.accept_all_incoming, desc = "Accept ALL incoming changes" },
  { key = "accept_all_current", fn = resolution.accept_all_current, desc = "Accept ALL current changes" },
  { key = "accept_all_both", fn = resolution.accept_all_both, desc = "Accept ALL both changes" },
  { key = "discard_all", fn = resolution.discard_all, desc = "Discard ALL, reset to base" },
  { key = "next_conflict", fn = navigation.navigate_next_conflict, desc = "Next conflict" },
  { key = "prev_conflict", fn = navigation.navigate_prev_conflict, desc = "Previous conflict" },
  TOGGLE_BASE,
}

-- Vimdiff-style numbered diffget, only meaningful on the result buffer.
local RESULT_ONLY_ACTIONS = {
  { key = "diffget_incoming", fn = resolution.diffget_incoming, desc = "Get hunk from incoming (2do)" },
  { key = "diffget_current", fn = resolution.diffget_current, desc = "Get hunk from current (3do)" },
}

--- Setup conflict keymaps for a session
---
--- Ordinary do/dp are not deleted here. The view layer skips claiming them
--- while a result pane exists, so any mapping the user already had on those
--- keys stays intact for the duration of the merge instead of being destroyed.
--- @param tabpage number
function M.setup_keymaps(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  lifecycle.begin_keymap_scope(tabpage, "conflict")

  local keymaps = resolve.keymaps_for("conflict")

  -- Bind to incoming (left), current (right), AND result buffers
  local buffers = { session.original_bufnr, session.modified_bufnr, session.result_bufnr }

  local base_opts = { noremap = true, silent = true, nowait = true }

  local function bind(bufnr, action, opts)
    if not keymaps[action.key] then
      return
    end
    lifecycle.set_buf_keymap(tabpage, bufnr, "n", keymaps[action.key], opts.rhs, vim.tbl_extend("force", base_opts, opts.extra or {}))
  end

  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, action in ipairs(REPEATABLE_ACTIONS) do
        bind(bufnr, action, {
          rhs = tracking.make_repeatable(function()
            action.fn(tabpage)
          end),
          extra = { desc = action.desc, expr = true },
        })
      end

      for _, action in ipairs(PLAIN_ACTIONS) do
        bind(bufnr, action, {
          rhs = function()
            action.fn(tabpage)
          end,
          extra = { desc = action.desc },
        })
      end

      if bufnr == session.result_bufnr then
        for _, action in ipairs(RESULT_ONLY_ACTIONS) do
          bind(bufnr, action, {
            rhs = tracking.make_repeatable(function()
              action.fn(tabpage)
            end),
            extra = { desc = action.desc, expr = true },
          })
        end
      end
    end
  end

  -- The read-only Base pane only needs a way to hide itself and to quit.
  local base_bufnr = session.base_bufnr
  if base_bufnr and vim.api.nvim_buf_is_valid(base_bufnr) then
    bind(base_bufnr, TOGGLE_BASE, {
      rhs = function()
        TOGGLE_BASE.fn(tabpage)
      end,
      extra = { desc = TOGGLE_BASE.desc },
    })
    local quit = resolve.keymaps_for("view").quit
    if quit then
      lifecycle.set_buf_keymap(tabpage, base_bufnr, "n", quit, function()
        lifecycle.close(tabpage)
      end, vim.tbl_extend("force", base_opts, { desc = "Close codediff tab" }))
    end
  end

  lifecycle.end_keymap_scope(tabpage, "conflict")
end

return M
