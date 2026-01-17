-- Node creation and formatting for file history panel
-- Handles commit nodes, file nodes, icons, and tree structure
local M = {}

local Tree = require("nui.tree")
local NuiLine = require("nui.line")
local config = require("codediff.config")

-- Status symbols and colors (reuse from explorer)
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "DiagnosticWarn" },
  A = { symbol = "A", color = "DiagnosticOk" },
  D = { symbol = "D", color = "DiagnosticError" },
  R = { symbol = "R", color = "DiagnosticInfo" },
}

-- File icons (basic fallback)
function M.get_file_icon(path)
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

-- Create commit node with its file children
-- commit: { hash, short_hash, author, date, date_relative, subject }
-- files: { { path, status, old_path }, ... }
-- git_root: absolute path to git repository root
function M.create_commit_node(commit, files, git_root)
  local file_nodes = {}

  for _, file in ipairs(files) do
    local icon, icon_color = M.get_file_icon(file.path)
    local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

    file_nodes[#file_nodes + 1] = Tree.Node({
      text = file.path,
      data = {
        type = "file",
        path = file.path,
        old_path = file.old_path,
        status = file.status,
        icon = icon,
        icon_color = icon_color,
        status_symbol = status_info.symbol,
        status_color = status_info.color,
        git_root = git_root,
        commit_hash = commit.hash,
      },
    })
  end

  return Tree.Node({
    text = commit.subject,
    data = {
      type = "commit",
      hash = commit.hash,
      short_hash = commit.short_hash,
      author = commit.author,
      date = commit.date,
      date_relative = commit.date_relative,
      subject = commit.subject,
      file_count = #files,
      git_root = git_root,
    },
  }, file_nodes)
end

-- Prepare node for rendering (format display)
function M.prepare_node(node, max_width, selected_commit, selected_file)
  local line = NuiLine()
  local data = node.data or {}

  if data.type == "commit" then
    -- Commit node: [icon] short_hash author date_relative subject
    local is_selected = data.hash == selected_commit and not selected_file
    local is_expanded = node:is_expanded()

    -- Get selected background color once
    local selected_bg = nil
    if is_selected then
      local sel_hl = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false })
      selected_bg = sel_hl.bg
    end

    local function get_hl(default)
      if not is_selected then
        return default or "Normal"
      end
      local base_hl_name = default or "Normal"
      local combined_name = "CodeDiffHistorySel_" .. base_hl_name:gsub("[^%w]", "_")
      local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })
      local fg = base_hl.fg
      vim.api.nvim_set_hl(0, combined_name, { fg = fg, bg = selected_bg })
      return combined_name
    end

    -- Expand/collapse indicator
    local expand_icon = is_expanded and " " or " "
    line:append(expand_icon, get_hl("Comment"))

    -- Short hash
    line:append(data.short_hash .. " ", get_hl("Identifier"))

    -- Author (dimmed)
    local author_display = data.author
    if #author_display > 15 then
      author_display = author_display:sub(1, 14) .. "…"
    end
    line:append(author_display .. " ", get_hl("Comment"))

    -- Date relative (dimmed)
    line:append(data.date_relative .. " ", get_hl("Comment"))

    -- Subject (main text)
    local used_width = vim.fn.strdisplaywidth(expand_icon)
      + vim.fn.strdisplaywidth(data.short_hash) + 1
      + vim.fn.strdisplaywidth(author_display) + 1
      + vim.fn.strdisplaywidth(data.date_relative) + 1

    local available_for_subject = max_width - used_width - 2
    local subject = data.subject
    if vim.fn.strdisplaywidth(subject) > available_for_subject then
      -- Truncate subject
      local truncated = ""
      local width = 0
      for char in vim.gsplit(subject, "") do
        local char_width = vim.fn.strdisplaywidth(char)
        if width + char_width + 1 > available_for_subject then
          break
        end
        truncated = truncated .. char
        width = width + char_width
      end
      subject = truncated .. "…"
    end
    line:append(subject, get_hl("Normal"))

  elseif data.type == "file" then
    -- File node: indented with icon, filename, status
    local is_selected = data.commit_hash == selected_commit and data.path == selected_file

    local selected_bg = nil
    if is_selected then
      local sel_hl = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false })
      selected_bg = sel_hl.bg
    end

    local function get_hl(default)
      if not is_selected then
        return default or "Normal"
      end
      local base_hl_name = default or "Normal"
      local combined_name = "CodeDiffHistorySel_" .. base_hl_name:gsub("[^%w]", "_")
      local base_hl = vim.api.nvim_get_hl(0, { name = base_hl_name, link = false })
      local fg = base_hl.fg
      vim.api.nvim_set_hl(0, combined_name, { fg = fg, bg = selected_bg })
      return combined_name
    end

    -- Indent
    line:append("    ", get_hl("Normal"))

    -- File icon
    if data.icon then
      line:append(data.icon .. " ", get_hl(data.icon_color))
    end

    -- Split path into filename and directory
    local full_path = data.path
    local filename = full_path:match("([^/]+)$") or full_path
    local directory = full_path:sub(1, -(#filename + 1))

    -- Filename
    line:append(filename, get_hl("Normal"))

    -- Directory (dimmed)
    if #directory > 0 then
      line:append(" ", get_hl("Normal"))
      line:append(directory, get_hl("Comment"))
    end

    -- Calculate padding for right-aligned status
    local used_width = 4 -- indent
      + (data.icon and (vim.fn.strdisplaywidth(data.icon) + 1) or 0)
      + vim.fn.strdisplaywidth(filename)
      + (#directory > 0 and (1 + vim.fn.strdisplaywidth(directory)) or 0)

    local status_width = vim.fn.strdisplaywidth(data.status_symbol) + 2
    local padding = max_width - used_width - status_width
    if padding > 0 then
      line:append(string.rep(" ", padding), get_hl("Normal"))
    end

    -- Status symbol
    line:append(data.status_symbol .. " ", get_hl(data.status_color))
  end

  return line
end

return M
