-- Golden keymap matrix harness.
--
-- Captures every buffer-local mapping installed on a CodeDiff session's
-- buffers, keyed by *role* rather than buffer number, so the result is stable
-- across runs and can be committed as a fixture.
--
-- Purpose: prove that a refactor of the keymap layer does not change which
-- mappings land on which buffers. Any intended change shows up as a small,
-- reviewable diff of the fixture.

local M = {}

-- Modes worth capturing. 'v' is visual+select, 'x' is visual-only; both are
-- listed because codediff binds the hunk textobject via { "o", "x" }.
M.MODES = { "n", "x", "o", "v", "i" }

--- Resolve the role -> bufnr map for a session.
--- The explorer and history panels share (session.panel or {}).view, so both are
--- reported under the single "panel" role.
--- @param tabpage number
--- @return table<string, number> roles
function M.roles(tabpage)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if not session then
    return {}
  end

  local roles = {}
  if session.original_bufnr then
    roles.original = session.original_bufnr
  end
  if session.modified_bufnr then
    roles.modified = session.modified_bufnr
  end
  if (session.panel or {}).view and (session.panel or {}).view.bufnr then
    roles.panel = (session.panel or {}).view.bufnr
  end
  if session.result_bufnr then
    roles.result = session.result_bufnr
  end
  return roles
end

--- Render a key sequence in a stable, readable form ("<Space>hs" not " hs").
--- Neovim already renders special keys such as `<CR>` and `<2-LeftMouse>` in
--- printable form, so those are used verbatim. Only sequences containing a
--- space or a control byte (typically an expanded `<leader>`) are translated,
--- which avoids double-encoding an already-readable name into `<lt>CR>`.
--- @param map table Entry from nvim_buf_get_keymap
--- @return string
local function display_key(map)
  local lhs = map.lhs or ""
  if lhs ~= "" and lhs:match("^%g+$") then
    return lhs
  end
  if vim.fn.exists("*keytrans") == 1 then
    local ok, translated = pcall(vim.fn.keytrans, lhs)
    if ok and translated ~= "" then
      return translated
    end
  end
  return lhs
end

--- Capture all buffer-local mappings for one buffer.
---
--- Each entry is verified reachable: a mapping can exist in the keymap list
--- yet be unreachable by the key press if its lhs was double-encoded. Querying
--- through `maparg` with the rendered name proves the key really resolves.
--- @param bufnr number
--- @return table<string, table[]> mode -> { { lhs, desc }, ... }
function M.capture_buffer(bufnr)
  local by_mode = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return by_mode
  end

  for _, mode in ipairs(M.MODES) do
    local entries = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      local shown = display_key(map)
      local reachable = vim.api.nvim_buf_call(bufnr, function()
        local found = vim.fn.maparg(shown, mode, false, true)
        return type(found) == "table" and next(found) ~= nil and found.buffer == 1
      end)
      table.insert(entries, {
        lhs = shown,
        desc = map.desc,
        unreachable = not reachable,
      })
    end
    table.sort(entries, function(a, b)
      if a.lhs ~= b.lhs then
        return a.lhs < b.lhs
      end
      return (a.desc or "") < (b.desc or "")
    end)
    if #entries > 0 then
      by_mode[mode] = entries
    end
  end

  return by_mode
end

--- Capture the full role x mode x lhs matrix for a session.
--- @param tabpage number
--- @return table matrix
function M.capture(tabpage)
  local matrix = {}
  for role, bufnr in pairs(M.roles(tabpage)) do
    matrix[role] = M.capture_buffer(bufnr)
  end
  return matrix
end

-- Deterministic role ordering for rendering.
local ROLE_ORDER = { "original", "modified", "panel", "result" }

--- Render a captured matrix into stable, diffable text lines.
--- @param label string Scenario name
--- @param matrix table Result of M.capture
--- @return string[] lines
function M.render(label, matrix)
  local lines = { "## " .. label }

  for _, role in ipairs(ROLE_ORDER) do
    local by_mode = matrix[role]
    if by_mode then
      for _, mode in ipairs(M.MODES) do
        for _, entry in ipairs(by_mode[mode] or {}) do
          -- An unreachable entry is a bug: the mapping is registered under a
          -- key sequence the user cannot actually press.
          local suffix = entry.unreachable and "   [UNREACHABLE]" or ""
          table.insert(lines, string.format("%-8s %-2s %-14s %s%s", role, mode, entry.lhs, entry.desc or "-", suffix))
        end
      end
    end
  end

  if #lines == 1 then
    table.insert(lines, "(no mappings captured)")
  end
  return lines
end

--- Capture and render in one step.
--- @param label string
--- @param tabpage number
--- @return string[] lines
function M.snapshot(label, tabpage)
  return M.render(label, M.capture(tabpage))
end

--- Collect buffer-local mappings for an arbitrary buffer outside a session.
--- Used to assert that pre-existing user mappings survive a session, and that
--- codediff mappings do not outlive it.
--- @param bufnr number
--- @param mode string
--- @return table<string, string> lhs -> desc ("-" when absent)
function M.map_index(bufnr, mode)
  local index = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return index
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    index[map.lhs] = map.desc or "-"
  end
  return index
end

return M
