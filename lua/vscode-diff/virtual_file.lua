-- Virtual file scheme for git revisions
-- Inspired by vim-fugitive's fugitive:// URL scheme
-- This allows LSP to attach to git historical content

local M = {}

local api = vim.api

-- Create a fugitive-style URL for a git revision
-- Format: vscodediff:///<git-root>///<commit>/<filepath>
-- Supports commit hash or :0 (staged index)
function M.create_url(git_root, commit, filepath)
  -- Normalize and encode components
  local encoded_root = vim.fn.fnamemodify(git_root, ':p')
  -- Remove trailing slashes (both / and \)
  encoded_root = encoded_root:gsub('[/\\]$', '')
  -- Normalize to forward slashes
  encoded_root = encoded_root:gsub('\\', '/')
  
  local encoded_commit = commit or 'HEAD'
  local encoded_path = filepath:gsub('^/', '')
  
  return string.format('vscodediff:///%s///%s/%s', 
    encoded_root, encoded_commit, encoded_path)
end

-- Parse a vscodediff:// URL
-- Returns: git_root, commit, filepath
function M.parse_url(url)
  -- Pattern accepts SHA hash (hex chars) or :0 for staged index
  local pattern = '^vscodediff:///(.-)///([a-fA-F0-9]+)/(.+)$'
  local git_root, commit, filepath = url:match(pattern)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end
  
  -- Try :0 pattern for staged index
  local pattern_staged = '^vscodediff:///(.-)///(:[0-9])/(.+)$'
  git_root, commit, filepath = url:match(pattern_staged)
  return git_root, commit, filepath
end

-- Setup the BufReadCmd autocmd to handle vscodediff:// URLs
function M.setup()
  -- Create autocmd group
  local group = api.nvim_create_augroup('VscodeDiffVirtualFile', { clear = true })
  
  -- Handle reading vscodediff:// URLs
  api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'vscodediff:///*',
    callback = function(args)
      local url = args.match
      local buf = args.buf

      local git_root, commit, filepath = M.parse_url(url)

      if not git_root or not commit or not filepath then
        vim.notify('Invalid vscodediff URL: ' .. url, vim.log.levels.ERROR)
        return
      end

      -- Set buffer options FIRST to prevent LSP attachment
      vim.bo[buf].buftype = 'nowrite'
      vim.bo[buf].bufhidden = 'wipe'

      -- Get the file content from git using the new async API
      local git = require('vscode-diff.git')

      git.get_file_content(commit, git_root, filepath, function(err, lines)
        vim.schedule(function()
          if err then
            -- Set error message in buffer
            api.nvim_buf_set_lines(buf, 0, -1, false, {
              'Error reading from git:',
              err
            })
            vim.bo[buf].modifiable = false
            vim.bo[buf].readonly = true
            return
          end

          -- Set the content
          api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          
          -- Make it read-only
          vim.bo[buf].modifiable = false
          vim.bo[buf].readonly = true
          
          -- Detect filetype from the original file path (for TreeSitter only)
          local ft = vim.filetype.match({ filename = filepath })
          if ft then
            vim.bo[buf].filetype = ft
          end
          
          -- Disable diagnostics for this buffer completely
          -- This prevents LSP diagnostics from showing even though LSP might attach
          vim.diagnostic.enable(false, { bufnr = buf })
          
          api.nvim_exec_autocmds('User', {
            pattern = 'VscodeDiffVirtualFileLoaded',
            data = { buf = buf }
          })
          
          -- DO NOT trigger BufRead - we don't want LSP to attach
          -- TreeSitter will work from filetype alone
        end)
      end)
    end,
  })
  
  -- Prevent writing to these buffers
  api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    pattern = 'vscodediff:///*',
    callback = function()
      vim.notify('Cannot write to git revision buffer', vim.log.levels.WARN)
    end,
  })
end

return M
