-- Virtual file scheme for git revisions
-- Inspired by vim-fugitive's fugitive:// URL scheme
-- LSP attachment is prevented so revision buffers use Tree-sitter highlighting only.

local M = {}

local api = vim.api
local loads = {}

-- Populate revision buffers consistently whether opening or refreshing a view.
function M.set_content(buf, lines, filepath)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  local value = #lines > 0 and lines or { "" }
  if not vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), value) then
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    api.nvim_buf_set_lines(buf, 0, -1, false, value)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  -- Setting filetype fires FileType and can attach LSPs to codediff:// URIs.
  local ft = filepath and vim.filetype.match({ filename = filepath, buf = buf })
  if ft then
    local lang = vim.treesitter.language.get_lang(ft) or ft
    if pcall(vim.treesitter.start, buf, lang) then
      vim.bo[buf].syntax = ""
    else
      vim.bo[buf].syntax = ft
    end
  end
  vim.diagnostic.enable(false, { bufnr = buf })
  return true
end

-- Helper function to load content into a virtual buffer and fire the loaded event
local function load_virtual_buffer_content(buf, git_root, commit, filepath)
  local git = require("codediff.core.git")
  loads[buf] = (loads[buf] or 0) + 1
  local generation = loads[buf]

  git.get_file_content(commit, git_root, filepath, function(err, lines)
    vim.schedule(function()
      -- Check buffer is still valid (might have been deleted during async fetch)
      if not api.nvim_buf_is_valid(buf) or loads[buf] ~= generation then
        return
      end

      if err then
        -- File doesn't exist in this revision (added/deleted file)
        -- Show empty buffer so diff can highlight the change
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
        -- Clear filetype without firing FileType autocmd (see issue #323; matches setup_buffer below).
        api.nvim_buf_call(buf, function()
          vim.cmd("noautocmd setlocal filetype=")
        end)
        vim.diagnostic.enable(false, { bufnr = buf })

        -- Fire loaded event so diff rendering proceeds
        api.nvim_exec_autocmds("User", {
          pattern = "CodeDiffVirtualFileLoaded",
          data = { buf = buf },
        })
        return
      end

      M.set_content(buf, lines, filepath)

      api.nvim_exec_autocmds("User", {
        pattern = "CodeDiffVirtualFileLoaded",
        data = { buf = buf },
      })
    end)
  end)
end

-- Refresh a virtual buffer's content (for mutable revisions like :0)
function M.refresh_buffer(buf)
  local bufname = api.nvim_buf_get_name(buf)
  local git_root, commit, filepath = M.parse_url(bufname)

  if not git_root or not commit or not filepath then
    return false
  end

  load_virtual_buffer_content(buf, git_root, commit, filepath)
  return true
end

-- Create a fugitive-style URL for a git revision
-- Format: codediff:///<git-root>///<commit>/<filepath>
-- Supports commit hash or :0 (staged index)
function M.create_url(git_root, commit, filepath)
  -- Normalize and encode components
  local encoded_root = vim.fn.fnamemodify(git_root, ":p")
  -- Remove trailing slashes (both / and \)
  encoded_root = encoded_root:gsub("[/\\]$", "")
  -- Normalize to forward slashes
  encoded_root = encoded_root:gsub("\\", "/")

  local encoded_commit = commit or "HEAD"
  local encoded_path = filepath:gsub("^/", "")

  return string.format("codediff:///%s///%s/%s", encoded_root, encoded_commit, encoded_path)
end

-- Parse a codediff:// URL
-- Returns: git_root, commit, filepath
function M.parse_url(url)
  -- Pattern accepts SHA hash (hex chars)
  local pattern = "^codediff:///(.-)///([a-fA-F0-9]+)/(.+)$"
  local git_root, commit, filepath = url:match(pattern)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try SHA with ^ suffix (parent commit reference)
  local pattern_parent = "^codediff:///(.-)///([a-fA-F0-9]+%^)/(.+)$"
  git_root, commit, filepath = url:match(pattern_parent)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try symbolic ref pattern (HEAD, branch names, etc.)
  local pattern_symbolic = "^codediff:///(.-)///([A-Za-z][A-Za-z0-9_~^%-]*)/(.+)$"
  git_root, commit, filepath = url:match(pattern_symbolic)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try :N or :N: pattern for staged index (supports :0, :1:, :2:, :3:)
  local pattern_staged = "^codediff:///(.-)///(:[0-9]:?)/(.+)$"
  git_root, commit, filepath = url:match(pattern_staged)
  return git_root, commit, filepath
end

-- Setup the BufReadCmd autocmd to handle codediff:// URLs
function M.setup()
  -- Create autocmd group
  local group = api.nvim_create_augroup("CodeDiffVirtualFile", { clear = true })

  -- Handle reading codediff:// URLs
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "codediff:///*",
    callback = function(args)
      local url = args.match
      local buf = args.buf

      local git_root, commit, filepath = M.parse_url(url)

      if not git_root or not commit or not filepath then
        vim.notify("Invalid codediff URL: " .. url, vim.log.levels.ERROR)
        return
      end

      -- Set buffer options FIRST to prevent LSP attachment
      vim.bo[buf].buftype = "nowrite"
      vim.bo[buf].bufhidden = "wipe"

      -- Clear any auto-detected filetype without firing FileType autocmd.
      -- Neovim's built-in filetype detection matches the .js/.ts/.tf extension
      -- in codediff:// URLs and sets filetype, which triggers LSP plugins to
      -- attach and crash on the custom URI scheme.
      vim.cmd("noautocmd setlocal filetype=")

      -- Load content using the shared helper
      load_virtual_buffer_content(buf, git_root, commit, filepath)
    end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      loads[event.buf] = nil
    end,
  })

  -- Prevent writing to these buffers
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "codediff:///*",
    callback = function()
      vim.notify("Cannot write to git revision buffer", vim.log.levels.WARN)
    end,
  })
end

return M
