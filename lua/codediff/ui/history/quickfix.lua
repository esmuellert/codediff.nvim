local M = {}

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")

local function build_qf_items(commits, git_root, opts)
  local items = {}
  local file_path = opts and opts.file_path

  for _, commit in ipairs(commits) do
    local text = string.format("%s %s - %s (%s)",
      commit.short_hash,
      commit.subject:sub(1, 50),
      commit.author,
      commit.date_relative
    )
    if commit.ref_names then
      text = text .. " [" .. commit.ref_names .. "]"
    end

    table.insert(items, {
      filename = git_root and (git_root .. "/" .. (file_path or "")) or "",
      text = text,
      user_data = {
        hash = commit.hash,
        short_hash = commit.short_hash,
        file_path = file_path or commit.file_path,
      },
    })
  end

  return items
end

function M.create(commits, git_root, tabpage, opts)
  opts = opts or {}

  local items = build_qf_items(commits, git_root, opts)
  if #items == 0 then
    vim.notify("No commits to show", vim.log.levels.INFO)
    return nil
  end

  vim.fn.setqflist({}, "r", {
    title = "CodeDiff: Commit History",
    items = items,
  })

  vim.cmd("copen")

  local qf_bufnr = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "<CR>", function()
    local idx = vim.fn.line(".")
    local qflist = vim.fn.getqflist({ items = 1 }).items
    local item = qflist[idx]
    if item and item.user_data then
      M.select_commit(tabpage, git_root, item.user_data, opts)
    end
  end, { buffer = qf_bufnr, desc = "Open diff for selected commit" })

  vim.keymap.set("n", "q", function()
    vim.cmd("cclose")
  end, { buffer = qf_bufnr, desc = "Close quickfix" })

  if #items > 0 then
    local first = items[1].user_data
    M.select_commit(tabpage, git_root, first, opts)
  end

  return {
    tabpage = tabpage,
    git_root = git_root,
    commits = commits,
  }
end

function M.select_commit(tabpage, git_root, commit_data, opts)
  opts = opts or {}
  local hash = commit_data.hash
  local file_path = commit_data.file_path or opts.file_path

  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  if file_path then
    view.update(tabpage, {
      mode = "history",
      git_root = git_root,
      original_path = file_path,
      modified_path = file_path,
      original_revision = hash .. "^",
      modified_revision = hash,
    }, true)
  else
    vim.notify("Select a file to view diff (no file path for commit)", vim.log.levels.INFO)
  end
end

return M
