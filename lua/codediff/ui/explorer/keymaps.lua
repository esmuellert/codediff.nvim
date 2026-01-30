-- Keymaps for explorer panel
local config = require("codediff.config")

local M = {}

-- Will be injected by init.lua
local actions_module = nil
local refresh_module = nil
local render_module = nil

M._set_actions_module = function(a)
  actions_module = a
end

M._set_refresh_module = function(r)
  refresh_module = r
end

M._set_render_module = function(r)
  render_module = r
end

-- Setup keymaps for explorer panel
-- @param explorer: explorer object with tree, split, git_root, on_file_select, etc.
function M.setup(explorer)
  local tree = explorer.tree
  local split = explorer.split
  local git_root = explorer.git_root

  local map_options = { noremap = true, silent = true, nowait = true }
  local explorer_keymaps = config.options.keymaps.explorer or {}

  -- Toggle expand/collapse or select file
  if explorer_keymaps.select then
    vim.keymap.set("n", explorer_keymaps.select, function()
      local node = tree:get_node()
      if not node then
        return
      end

      if node.data and (node.data.type == "group" or node.data.type == "directory") then
        -- Toggle group or directory
        if node:is_expanded() then
          node:collapse()
        else
          node:expand()
        end
        tree:render()
      else
        -- File selected
        if node.data then
          explorer.on_file_select(node.data)
        end
      end
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Select/toggle entry" }))
  end

  -- Double click also works for files
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local node = tree:get_node()
    if not node or not node.data or node.data.type == "group" or node.data.type == "directory" then
      return
    end
    explorer.on_file_select(node.data)
  end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Select file" }))

  -- Hover to show full path (K key, like LSP hover)
  local hover_win = nil
  if explorer_keymaps.hover then
    vim.keymap.set("n", explorer_keymaps.hover, function()
      -- Close existing hover window
      if hover_win and vim.api.nvim_win_is_valid(hover_win) then
        vim.api.nvim_win_close(hover_win, true)
        hover_win = nil
        return
      end

      local node = tree:get_node()
      if not node or not node.data or node.data.type == "group" then
        return
      end

      local full_path = node.data.path
      local display_text = git_root .. "/" .. full_path

      -- Create hover buffer
      local hover_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, { display_text })
      vim.bo[hover_buf].modifiable = false

      -- Calculate window position (next to cursor)
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1
      local col = vim.api.nvim_win_get_width(0)

      -- Calculate window dimensions with wrapping
      local max_width = 80
      local text_len = #display_text
      local width = math.min(text_len + 2, max_width)
      local height = math.ceil(text_len / (max_width - 2)) -- Account for padding

      -- Create floating window with wrap enabled
      hover_win = vim.api.nvim_open_win(hover_buf, false, {
        relative = "win",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
      })

      -- Enable wrap in hover window
      vim.wo[hover_win].wrap = true

      -- Auto-close on cursor move or buffer leave
      vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
        buffer = split.bufnr,
        once = true,
        callback = function()
          if hover_win and vim.api.nvim_win_is_valid(hover_win) then
            vim.api.nvim_win_close(hover_win, true)
            hover_win = nil
          end
        end,
      })
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Show full path" }))
  end

  -- Refresh explorer (R key)
  if explorer_keymaps.refresh then
    vim.keymap.set("n", explorer_keymaps.refresh, function()
      refresh_module.refresh(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Refresh explorer" }))
  end

  -- Toggle view mode (i key) - switch between 'list' and 'tree'
  if explorer_keymaps.toggle_view_mode then
    vim.keymap.set("n", explorer_keymaps.toggle_view_mode, function()
      actions_module.toggle_view_mode(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Toggle list/tree view" }))
  end

  -- Stage all files (S key)
  if explorer_keymaps.stage_all then
    vim.keymap.set("n", explorer_keymaps.stage_all, function()
      actions_module.stage_all(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Stage all files" }))
  end

  -- Unstage all files (U key)
  if explorer_keymaps.unstage_all then
    vim.keymap.set("n", explorer_keymaps.unstage_all, function()
      actions_module.unstage_all(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Unstage all files" }))
  end

  -- Restore/discard changes (X key)
  if explorer_keymaps.restore then
    vim.keymap.set("n", explorer_keymaps.restore, function()
      actions_module.restore_entry(explorer, tree)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Restore/discard changes" }))
  end

  -- Navigate to next file (uses view keymaps)
  if config.options.keymaps.view.next_file then
    vim.keymap.set("n", config.options.keymaps.view.next_file, function()
      render_module.navigate_next(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Next file" }))
  end

  -- Navigate to previous file (uses view keymaps)
  if config.options.keymaps.view.prev_file then
    vim.keymap.set("n", config.options.keymaps.view.prev_file, function()
      render_module.navigate_prev(explorer)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Previous file" }))
  end

  -- Helper: focus the modified (right) pane after async file load
  local function focus_modified_pane()
    vim.defer_fn(function()
      local lifecycle = require('codediff.ui.lifecycle')
      local _, mod_win = lifecycle.get_windows(explorer.tabpage)
      if mod_win and vim.api.nvim_win_is_valid(mod_win) then
        vim.api.nvim_set_current_win(mod_win)
      end
    end, 200)
  end

  -- Open (alias for select) — opens file but keeps focus in explorer
  if explorer_keymaps.open then
    vim.keymap.set("n", explorer_keymaps.open, function()
      local node = tree:get_node()
      if not node then return end
      if node.data and (node.data.type == "group" or node.data.type == "directory") then
        if node:is_expanded() then
          node:collapse()
        else
          node:expand()
        end
        tree:render()
      elseif node.data then
        explorer.on_file_select(node.data)
      end
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Open file or toggle group" }))
  end

  -- Focus file: jump to modified pane if file is already open, otherwise open it
  if explorer_keymaps.focus_file then
    vim.keymap.set("n", explorer_keymaps.focus_file, function()
      local node = tree:get_node()
      if not node or not node.data then return end

      -- If cursor is on the already-open file, jump to the modified (right) pane
      if node.data.path and node.data.path == explorer.current_file_path
          and (node.data.group or "unstaged") == explorer.current_file_group then
        local lifecycle = require('codediff.ui.lifecycle')
        local _, mod_win = lifecycle.get_windows(explorer.tabpage)
        if mod_win and vim.api.nvim_win_is_valid(mod_win) then
          vim.api.nvim_set_current_win(mod_win)
          return
        end
      end

      -- Otherwise open the file (same as select for files, toggle for groups)
      if node.data.type == "group" or node.data.type == "directory" then
        if node:is_expanded() then
          node:collapse()
        else
          node:expand()
        end
        tree:render()
      elseif node.data.path then
        explorer.on_file_select(node.data)
        focus_modified_pane()
      end
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Focus file in diff view" }))
  end

  -- Stage file (git add)
  local function bind_stage_file(key)
    if key then
      vim.keymap.set("n", key, function()
        local node = tree:get_node()
        if not node or not node.data or not node.data.path then return end
        actions_module.stage_file(explorer, node.data)
      end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Stage file" }))
    end
  end
  bind_stage_file(explorer_keymaps.stage_file)
  bind_stage_file(explorer_keymaps.stage_file_alt)

  -- Unstage file (git restore --staged)
  if explorer_keymaps.unstage_file then
    vim.keymap.set("n", explorer_keymaps.unstage_file, function()
      local node = tree:get_node()
      if not node or not node.data or not node.data.path then return end
      actions_module.unstage_file(explorer, node.data)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Unstage file" }))
  end

  -- Discard file changes (with confirmation)
  if explorer_keymaps.discard_file then
    vim.keymap.set("n", explorer_keymaps.discard_file, function()
      local node = tree:get_node()
      if not node or not node.data or not node.data.path then return end
      actions_module.discard_file(explorer, node.data)
    end, vim.tbl_extend("force", map_options, { buffer = split.bufnr, desc = "Discard file changes" }))
  end
end

return M
