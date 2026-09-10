-- Render precomputed conflict markers for filler virtual lines.
local M = {}

local states = {}
local expression = "%!v:lua.require'codediff.ui.conflict.gutter.statuscolumn'.render()"

local function number_item(win)
  local options = vim.wo[win]
  if not options.number and not options.relativenumber then
    return ""
  end

  -- %l preserves native relative numbers, hybrid alignment and wrapped rows.
  -- With signcolumn=number, signs need right alignment even on the cursor row.
  if options.signcolumn == "number" then
    local cursor_number = options.number and options.relativenumber and vim.v.relnum == 0 and vim.v.virtnum == 0
    if cursor_number then
      local row = vim.v.lnum - 1
      local signs = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), -1, { row, 0 }, { row, -1 }, { type = "sign", limit = 1 })
      cursor_number = #signs == 0
    end
    if not cursor_number then
      return "%=%l "
    end
  end
  return "%l "
end

local function default_statuscolumn(win)
  return "%C%s" .. number_item(win)
end

local function render_marker(win, marker)
  local marker_text = marker.text == "[" and "[ " or marker.text
  local highlighted = "%#" .. marker.highlight .. "#" .. marker_text .. "%*"
  local options = vim.wo[win]
  if options.signcolumn == "number" and (options.number or options.relativenumber) then
    return "%C%=" .. highlighted .. " "
  end
  return "%C" .. highlighted .. number_item(win)
end

--- Render in the drawing window's context, even if another pane has focus.
function M.render()
  local win = tonumber(vim.g.statusline_winid)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local state = states[win]
  if state and state.bufnr == vim.api.nvim_win_get_buf(win) and vim.v.virtnum < 0 and vim.wo[win].signcolumn ~= "no" then
    local line_markers = state.markers[vim.v.lnum]
    local marker = line_markers and line_markers[-vim.v.virtnum]
    if marker then
      return render_marker(win, marker)
    end
  end
  return default_statuscolumn(win)
end

--- Attach only when the column is native or inherited from our renderer.
function M.attach(win)
  if vim.fn.exists("+statuscolumn") ~= 1 or not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local current = vim.wo[win].statuscolumn
  if current ~= "" and current ~= expression then
    states[win] = nil
    return false
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  local state = states[win]
  if not state or state.bufnr ~= bufnr then
    states[win] = { bufnr = bufnr, markers = {} }
  end
  if current ~= expression then
    vim.wo[win].statuscolumn = expression
  end
  return true
end

--- Index precomputed markers by Neovim's statuscolumn coordinates.
function M.update(win, projections, filler_counts)
  local state = states[win]
  if not state or not vim.api.nvim_win_is_valid(win) or state.bufnr ~= vim.api.nvim_win_get_buf(win) or vim.wo[win].statuscolumn ~= expression then
    M.detach(win)
    return false
  end

  local markers = {}
  local bof_count = filler_counts and filler_counts[0] or 0
  for _, projection in ipairs(projections or {}) do
    for line, offsets in pairs(projection.markers) do
      for offset, text in pairs(offsets) do
        if offset > 0 then
          -- BOF fillers and fillers after line one share v:lnum=1; Neovim
          -- numbers them consecutively, including off-screen BOF fillers.
          local lnum = math.max(1, line)
          local virtnum = offset + (line == 1 and bof_count or 0)
          markers[lnum] = markers[lnum] or {}
          markers[lnum][virtnum] = { text = text, highlight = projection.highlight }
        end
      end
    end
  end
  state.markers = markers
  return true
end

--- Restore the option only while we still own it.
function M.detach(win)
  local state = states[win]
  if not state then
    return
  end
  states[win] = nil
  if vim.api.nvim_win_is_valid(win) and vim.wo[win].statuscolumn == expression then
    vim.wo[win].statuscolumn = ""
  end
end

if vim.fn.exists("+statuscolumn") == 1 then
  local group = vim.api.nvim_create_augroup("CodeDiffConflictGutterWindows", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      states[tonumber(event.match)] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local state = states[win]
      if state and state.bufnr ~= vim.api.nvim_win_get_buf(win) then
        M.detach(win)
      elseif not state and vim.wo[win].statuscolumn == expression then
        -- A split can inherit the expression, but not ownership of its state.
        vim.wo[win].statuscolumn = ""
      end
    end,
  })
end

return M
