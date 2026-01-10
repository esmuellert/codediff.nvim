-- Semantic tokens for diff buffers
--
-- IMPORTANT: This module vendors critical functions from Neovim's LSP semantic tokens
-- implementation because there is no public API to process semantic token responses
-- for arbitrary buffers.
--
-- Source: /usr/share/nvim/runtime/lua/vim/lsp/semantic_tokens.lua
-- Requires: Neovim 0.9+ (when vim.lsp.semantic_tokens was introduced)
--
-- Functions vendored:
--   - modifiers_from_number(): Decodes token modifiers from bit field
--   - tokens_to_ranges(): Converts LSP token array to highlight ranges
--
-- These are copied from Neovim core because:
--   1. No public API exists to process semantic token responses
--   2. STHighlighter class is private and buffer-bound
--
-- Version compatibility:
--   - Neovim 0.9+: Fully supported
--   - Neovim 0.8 and earlier: Gracefully skipped (TreeSitter only)
--
-- Future-proofing:
--   - The LSP semantic tokens format is stable (LSP spec)
--   - Token encoding (delta format) is unlikely to change
--   - If Neovim adds public API, we can switch to it
--
-- Tested with: Neovim 0.9-0.12
--
local M = {}

local api = vim.api
local bit = require("bit")

-- Namespace for semantic token highlights
local ns_semantic = api.nvim_create_namespace("codediff_semantic_tokens")

-- ============================================================================
-- VENDORED FROM: vim/lsp/semantic_tokens.lua
-- ============================================================================

--- Extract modifier strings from encoded number
--- @param x integer
--- @param modifiers_table string[]
--- @return table<string, boolean>
local function modifiers_from_number(x, modifiers_table)
  local modifiers = {}
  local idx = 1
  while x > 0 do
    if bit.band(x, 1) == 1 then
      modifiers[modifiers_table[idx]] = true
    end
    x = bit.rshift(x, 1)
    idx = idx + 1
  end
  return modifiers
end

--- Convert raw token data to highlight ranges
--- @param data integer[]
--- @param bufnr integer
--- @param legend table
--- @param encoding string
--- @return table[]
local function tokens_to_ranges(data, bufnr, legend, encoding)
  local token_types = legend.tokenTypes
  local token_modifiers = legend.tokenModifiers
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local eol_offset = vim.bo[bufnr].fileformat == "dos" and 2 or 1
  local ranges = {}

  local line = nil
  local start_char = 0

  -- Data format: [deltaLine, deltaStart, length, tokenType, tokenModifiers]
  for i = 1, #data, 5 do
    local delta_line = data[i]
    line = line and line + delta_line or delta_line
    local delta_start = data[i + 1]
    start_char = delta_line == 0 and start_char + delta_start or delta_start

    local token_type = token_types[data[i + 3] + 1]

    if token_type then
      local modifiers = modifiers_from_number(data[i + 4], token_modifiers)
      local end_char = start_char + data[i + 2]
      local buf_line = lines[line + 1] or ""
      local end_line = line
      local start_col = vim.str_byteindex(buf_line, encoding, start_char, false)

      local new_end_char = end_char - vim.str_utfindex(buf_line, encoding) - eol_offset

      -- Handle tokens spanning multiple lines
      while new_end_char > 0 do
        end_char = new_end_char
        end_line = end_line + 1
        buf_line = lines[end_line + 1] or ""
        new_end_char = new_end_char - vim.str_utfindex(buf_line, encoding) - eol_offset
      end

      local end_col = vim.str_byteindex(buf_line, encoding, end_char, false)

      ranges[#ranges + 1] = {
        line = line,
        end_line = end_line,
        start_col = start_col,
        end_col = end_col,
        type = token_type,
        modifiers = modifiers,
      }
    end
  end

  return ranges
end

-- ============================================================================
-- END VENDORED CODE
-- ============================================================================

--- Apply highlights to buffer from token ranges
--- @param bufnr integer
--- @param ranges table[]
local function apply_highlights(bufnr, ranges)
  -- Clear existing semantic token highlights
  api.nvim_buf_clear_namespace(bufnr, ns_semantic, 0, -1)

  for _, token in ipairs(ranges) do
    -- Build highlight group name
    local hl_group = "@lsp.type." .. token.type

    -- Add modifiers
    for modifier, _ in pairs(token.modifiers) do
      hl_group = hl_group .. "." .. modifier
    end

    -- Apply extmark with semantic token highlight
    pcall(api.nvim_buf_set_extmark, bufnr, ns_semantic, token.line, token.start_col, {
      hl_group = hl_group,
      end_line = token.end_line,
      end_col = token.end_col,
      priority = vim.hl.priorities and vim.hl.priorities.semantic_tokens or 125,
      strict = false,
    })
  end
end

--- Request and apply semantic tokens to left buffer from right buffer's LSP
--- The left buffer is a virtual file (codediff://) which we manually register with LSP
--- @param left_buf integer Left buffer (virtual file with codediff:// URI)
--- @param right_buf integer Right buffer (real file, has LSP attached)
--- @return boolean success
function M.apply_semantic_tokens(left_buf, right_buf)
  -- Check Neovim version - semantic tokens added in 0.9
  if not vim.lsp.semantic_tokens then
    return false
  end

  -- Check for required APIs
  if not vim.str_byteindex then
    return false
  end

  -- Verify both buffers are valid
  if not api.nvim_buf_is_valid(left_buf) or not api.nvim_buf_is_valid(right_buf) then
    return false
  end

  -- Get LSP clients from right buffer
  local clients = vim.lsp.get_clients({ bufnr = right_buf })
  if #clients == 0 then
    return false
  end

  -- Find a client that supports semantic tokens
  local client = nil
  for _, c in ipairs(clients) do
    if c.server_capabilities.semanticTokensProvider then
      client = c
      break
    end
  end

  if not client then
    return false
  end

  -- Get URI and content from left buffer
  local left_uri = vim.uri_from_bufnr(left_buf)
  local left_lines = api.nvim_buf_get_lines(left_buf, 0, -1, false)
  local left_text = table.concat(left_lines, "\n")

  -- Get language ID from right buffer's filetype
  local language_id = vim.bo[right_buf].filetype or "text"

  -- First, notify LSP about this virtual file via textDocument/didOpen
  local didopen_params = {
    textDocument = {
      uri = left_uri,
      languageId = language_id,
      version = 1,
      text = left_text,
    },
  }

  client.notify("textDocument/didOpen", didopen_params)

  -- Now request semantic tokens for this file
  local params = {
    textDocument = {
      uri = left_uri,
    },
  }

  -- Make async request for semantic tokens
  client.request("textDocument/semanticTokens/full", params, function(err, result)
    if err then
      return
    end

    if not result then
      return
    end

    -- Process response
    vim.schedule(function()
      -- Verify buffer is still valid
      if not api.nvim_buf_is_valid(left_buf) then
        return
      end

      -- Extract token data
      local data = result.data
      if not data or #data == 0 then
        return
      end

      -- Get legend from client capabilities
      local legend = client.server_capabilities.semanticTokensProvider.legend
      local encoding = client.offset_encoding or "utf-16"

      -- Convert tokens to ranges
      local ranges = tokens_to_ranges(data, left_buf, legend, encoding)

      -- Apply highlights
      apply_highlights(left_buf, ranges)
    end)
  end, left_buf)

  return true
end

--- Clear semantic token highlights from buffer
---@param bufnr integer
function M.clear(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns_semantic, 0, -1)
  end
end

return M
