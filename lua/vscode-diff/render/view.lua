-- Diff view creation and window management
local M = {}

local core = require('vscode-diff.render.core')
local lifecycle = require('vscode-diff.render.lifecycle')
local semantic = require('vscode-diff.render.semantic_tokens')
local virtual_file = require('vscode-diff.virtual_file')

-- Buffer type enumeration
M.BufferType = {
  VIRTUAL_FILE = "VIRTUAL_FILE",  -- Virtual file (vscodediff://) for LSP semantic tokens
  REAL_FILE = "REAL_FILE",        -- Real file on disk
}

-- Create a buffer based on its type and configuration
local function create_buffer(buffer_type, config)
  if buffer_type == M.BufferType.VIRTUAL_FILE then
    -- Virtual file: URL is returned, buffer created by :edit command
    local virtual_url = virtual_file.create_url(config.git_root, config.git_revision, config.relative_path)
    return nil, virtual_url
  elseif buffer_type == M.BufferType.REAL_FILE then
    -- Real file: reuse existing buffer or create new one
    local existing_buf = vim.fn.bufnr(config.file_path)
    if existing_buf ~= -1 then
      return existing_buf, nil
    else
      -- For real files, we should use :edit to properly load the file
      -- This ensures filetype detection, no modification flag, etc.
      return nil, config.file_path
    end
  end
end

-- Create side-by-side diff view
-- @param original_lines table: Lines from the original version
-- @param modified_lines table: Lines from the modified version
-- @param lines_diff table: Diff result from compute_diff
-- @param opts table: Required settings
--   - left_type string: Buffer type for left buffer (BufferType.VIRTUAL_FILE or REAL_FILE)
--   - right_type string: Buffer type for right buffer (BufferType.VIRTUAL_FILE or REAL_FILE)
--   - left_config table: Configuration for left buffer (depends on left_type)
--   - right_config table: Configuration for right buffer (depends on right_type)
--   - filetype string (optional): Filetype for syntax highlighting
function M.create(original_lines, modified_lines, lines_diff, opts)
  opts = opts or {}
  
  -- Create buffers based on their types
  local left_buf, left_url = create_buffer(opts.left_type, opts.left_config or {})
  local right_buf, right_url = create_buffer(opts.right_type, opts.right_config or {})
  
  -- Determine if we need to use :edit command (for virtual files or new real files)
  local left_needs_edit = (left_url ~= nil)
  local right_needs_edit = (right_url ~= nil)
  
  -- Determine if we need to wait for virtual file content to load
  local has_virtual_buffer = (opts.left_type == M.BufferType.VIRTUAL_FILE) or (opts.right_type == M.BufferType.VIRTUAL_FILE)
  local defer_render = has_virtual_buffer or left_needs_edit or right_needs_edit
  
  -- Always defer render when we need to use :edit or have virtual files
  local result = nil

  -- Create side-by-side windows
  vim.cmd("tabnew")
  local initial_buf = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  
  -- Set left buffer/window
  if left_needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(left_url))
    left_buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(left_win, left_buf)
  end

  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  
  -- Set right buffer/window
  if right_needs_edit then
    vim.cmd("edit " .. vim.fn.fnameescape(right_url))
    right_buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(right_win, right_buf)
  end
  
  -- Clean up initial buffer
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= left_buf and initial_buf ~= right_buf then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  -- Reset both cursors to line 1 BEFORE enabling scrollbind
  vim.api.nvim_win_set_cursor(left_win, {1, 0})
  vim.api.nvim_win_set_cursor(right_win, {1, 0})

  -- Window options
  local win_opts = {
    number = true,
    relativenumber = false,
    cursorline = true,
    scrollbind = true,
    wrap = false,
  }

  for opt, val in pairs(win_opts) do
    vim.wo[left_win][opt] = val
    vim.wo[right_win][opt] = val
  end
  
  -- Note: Filetype is automatically detected when using :edit for real files
  -- For virtual files, filetype is set in the virtual_file module

  -- Register this diff view for lifecycle management
  local current_tab = vim.api.nvim_get_current_tabpage()
  lifecycle.register(current_tab, left_buf, right_buf, left_win, right_win)
  
  -- Set up rendering after buffers are ready
  -- For virtual files, we wait for VscodeDiffVirtualFileLoaded event
  -- For real files loaded via :edit, we render immediately (they're synchronously loaded)
  if has_virtual_buffer then
    -- Virtual file(s) exist: Set up autocmd to apply diff highlights after content loads
    local trigger_buf = (opts.left_type == M.BufferType.VIRTUAL_FILE) and left_buf or right_buf
    local group = vim.api.nvim_create_augroup('VscodeDiffVirtualFileHighlight_' .. trigger_buf, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'VscodeDiffVirtualFileLoaded',
      callback = function(event)
        if event.data and event.data.buf == trigger_buf then
          vim.schedule(function()
            result = core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff, 
                                       opts.right_type == M.BufferType.REAL_FILE, true)
            
            -- Apply semantic tokens if we have virtual file(s)
            vim.schedule(function()
              if opts.left_type == M.BufferType.VIRTUAL_FILE then
                semantic.apply_semantic_tokens(left_buf, right_buf)
              end
              if opts.right_type == M.BufferType.VIRTUAL_FILE then
                semantic.apply_semantic_tokens(right_buf, left_buf)
              end
            end)
            
            if #lines_diff.changes > 0 then
              local first_change = lines_diff.changes[1]
              local target_line = first_change.original.start_line
              
              pcall(vim.api.nvim_win_set_cursor, left_win, {target_line, 0})
              pcall(vim.api.nvim_win_set_cursor, right_win, {target_line, 0})
              
              if vim.api.nvim_win_is_valid(right_win) then
                vim.api.nvim_set_current_win(right_win)
                vim.cmd("normal! zz")
              end
            end
            
            vim.api.nvim_del_augroup_by_id(group)
          end)
        end
      end,
    })
  else
    -- Real files only: Render immediately after :edit loads them
    vim.schedule(function()
      -- For real files loaded via :edit, skip setting content (already loaded)
      local skip_left = (opts.left_type == M.BufferType.REAL_FILE)
      local skip_right = (opts.right_type == M.BufferType.REAL_FILE)
      
      result = core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff, skip_right, skip_left)
      
      if #lines_diff.changes > 0 then
        local first_change = lines_diff.changes[1]
        local target_line = first_change.original.start_line
        
        vim.api.nvim_win_set_cursor(left_win, {target_line, 0})
        vim.api.nvim_win_set_cursor(right_win, {target_line, 0})
        
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("normal! zz")
      end
    end)
  end

  return {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    result = result,
  }
end

return M
