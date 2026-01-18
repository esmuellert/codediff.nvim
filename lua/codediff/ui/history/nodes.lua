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

  for i, file in ipairs(files) do
    local icon, icon_color = M.get_file_icon(file.path)
    local status_info = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }

    file_nodes[#file_nodes + 1] = Tree.Node({
      text = file.path,
      id = "file:" .. commit.hash .. ":" .. file.path,
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
        is_last = i == #files,
      },
    })
  end

  return Tree.Node({
    text = commit.subject,
    id = "commit:" .. commit.hash,
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
-- Match diffview format: [fold] [file count] | [adds] [dels] | hash subject author, date
function M.prepare_node(node, max_width, selected_commit, selected_file)
  local line = NuiLine()
  local data = node.data or {}

  if data.type == "title" then
    -- Title node - styled header
    line:append(data.title, "CodeDiffHistoryTitle")

  elseif data.type == "commit" then
    -- Commit node format (diffview style):
    -- [fold icon] N file(s) | +adds -dels | hash subject author, date
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
    line:append(expand_icon, get_hl("NonText"))

    -- File count (padded to align) - skip in single file mode (when file_path is set)
    if not data.file_path then
      local file_count = data.file_count or data.files_changed or 0
      local file_word = file_count == 1 and "file " or "files"
      local files_width = data.max_files_width or 2
      local file_str = string.format("%" .. files_width .. "d %s ", file_count, file_word)
      line:append(file_str, get_hl("NonText"))
    end

    -- Stats with pipe separators: | <ins> <del> |
    -- One space after |, numbers left-aligned to max width, one space between, one before |
    local insertions = data.insertions or 0
    local deletions = data.deletions or 0
    local ins_width = data.max_ins_width or #tostring(insertions)
    local del_width = data.max_del_width or #tostring(deletions)
    
    local ins_str = string.format("%-" .. ins_width .. "d", insertions)
    local del_str = string.format("%-" .. del_width .. "d", deletions)
    
    line:append("| ", get_hl("NonText"))
    line:append(ins_str, get_hl("DiagnosticOk"))
    line:append(" ")
    line:append(del_str, get_hl("DiagnosticError"))
    line:append(" | ", get_hl("NonText"))

    -- Short hash (8 chars like diffview)
    local hash_display = data.short_hash
    if #hash_display < 8 and data.hash then
      hash_display = data.hash:sub(1, 8)
    end
    line:append(hash_display, get_hl("Identifier"))

    -- Ref names (branches, tags) if present
    if data.ref_names and data.ref_names ~= "" then
      line:append(" (" .. data.ref_names .. ")", get_hl("String"))
    end

    -- Subject (main text, truncated to 72 chars like diffview)
    local subject = data.subject
    if #subject > 72 then
      subject = subject:sub(1, 71) .. "…"
    end
    if subject == "" then
      subject = "[empty message]"
    end
    line:append(" " .. subject, get_hl("Normal"))

    -- Author, date at end (dimmed)
    line:append(" " .. data.author .. ", " .. data.date_relative, get_hl("Comment"))

  elseif data.type == "file" then
    -- File node format (diffview style):
    -- [tree char] [status] [icon] [path/]filename
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

    -- Tree line character (diffview uses └ for last, │ for others)
    local tree_char = data.is_last and "└   " or "│   "
    line:append(tree_char, get_hl("Comment"))

    -- Status symbol
    line:append(data.status_symbol .. " ", get_hl(data.status_color))

    -- File icon
    if data.icon then
      line:append(data.icon .. " ", get_hl(data.icon_color))
    end

    -- Split path into directory and filename
    local full_path = data.path
    local filename = full_path:match("([^/]+)$") or full_path
    local directory = full_path:sub(1, -(#filename + 2))

    -- Directory path (dimmed)
    if #directory > 0 then
      line:append(directory .. "/", get_hl("Comment"))
    end

    -- Filename
    line:append(filename, get_hl("Normal"))

    -- Pad with spaces to fill full line width when selected
    if is_selected and max_width then
      local current_len = #line:content()
      if current_len < max_width then
        line:append(string.rep(" ", max_width - current_len), get_hl("Normal"))
      end
    end
  end

  return line
end

return M
