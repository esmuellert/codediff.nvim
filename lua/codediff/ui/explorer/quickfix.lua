local M = {}

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

local function status_to_prefix(status)
  local map = {
    M = "[M]",
    A = "[A]",
    D = "[D]",
    ["??"] = "[?]",
    UU = "[C]",
    AA = "[C]",
    DD = "[C]",
  }
  return map[status] or "[" .. status .. "]"
end

local function build_qf_items(status_result, git_root)
  local items = {}

  if status_result.conflicts and #status_result.conflicts > 0 then
    for _, file in ipairs(status_result.conflicts) do
      table.insert(items, {
        filename = git_root and (git_root .. "/" .. file.path) or file.path,
        text = status_to_prefix(file.status) .. " " .. file.path,
        user_data = { path = file.path, status = file.status, group = "conflicts" },
      })
    end
  end

  for _, file in ipairs(status_result.unstaged) do
    table.insert(items, {
      filename = git_root and (git_root .. "/" .. file.path) or file.path,
      text = status_to_prefix(file.status) .. " " .. file.path,
      user_data = { path = file.path, status = file.status, group = "unstaged" },
    })
  end

  for _, file in ipairs(status_result.staged) do
    table.insert(items, {
      filename = git_root and (git_root .. "/" .. file.path) or file.path,
      text = status_to_prefix(file.status) .. " staged: " .. file.path,
      user_data = { path = file.path, status = file.status, group = "staged" },
    })
  end

  return items
end

function M.create(status_result, git_root, tabpage, base_revision, target_revision, opts)
  opts = opts or {}

  local items = build_qf_items(status_result, git_root)
  if #items == 0 then
    vim.notify("No changes to show", vim.log.levels.INFO)
    return nil
  end

  vim.fn.setqflist({}, "r", {
    title = "CodeDiff: Changed Files",
    items = items,
  })

  local group = vim.api.nvim_create_augroup("CodeDiffQuickfix_" .. tabpage, { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "codediff://*",
    callback = function(ev)
      local path = ev.file:match("^codediff://(.+)$")
      if not path then
        return
      end

      local qflist = vim.fn.getqflist({ items = 1 }).items
      for _, item in ipairs(qflist) do
        local data = item.user_data
        if data and data.path == path then
          M.select_file(tabpage, git_root, data, base_revision, target_revision, opts)
          break
        end
      end
    end,
  })

  vim.cmd("copen")

  local qf_bufnr = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "<CR>", function()
    local idx = vim.fn.line(".")
    local qflist = vim.fn.getqflist({ items = 1 }).items
    local item = qflist[idx]
    if item and item.user_data then
      M.select_file(tabpage, git_root, item.user_data, base_revision, target_revision, opts)
    end
  end, { buffer = qf_bufnr, desc = "Open diff for selected file" })

  vim.keymap.set("n", "q", function()
    vim.cmd("cclose")
  end, { buffer = qf_bufnr, desc = "Close quickfix" })

  if #items > 0 then
    local first = items[1].user_data
    M.select_file(tabpage, git_root, first, base_revision, target_revision, opts)
  end

  return {
    tabpage = tabpage,
    git_root = git_root,
    base_revision = base_revision,
    target_revision = target_revision,
    status_result = status_result,
  }
end

function M.select_file(tabpage, git_root, file_data, base_revision, target_revision, opts)
  opts = opts or {}
  local file_path = file_data.path
  local group = file_data.group
  local status = file_data.status

  local original_revision, modified_revision
  local original_path, modified_path
  local is_conflict = (group == "conflicts")

  if is_conflict then
    original_revision = ":3"
    modified_revision = ":2"
    original_path = file_path
    modified_path = file_path
  elseif group == "staged" then
    original_revision = base_revision or "HEAD"
    modified_revision = ":0"
    original_path = file_path
    modified_path = file_path
  else
    original_revision = base_revision or "HEAD"
    modified_revision = (target_revision == "WORKING" or not target_revision) and nil or target_revision
    original_path = file_path
    modified_path = git_root and (git_root .. "/" .. file_path) or file_path
  end

  if status == "A" then
    original_revision = nil
    original_path = nil
  elseif status == "D" then
    modified_revision = nil
    modified_path = nil
  end

  local session = lifecycle.get_session(tabpage)
  if session then
    view.update(tabpage, {
      mode = "explorer",
      git_root = git_root,
      original_path = original_path or "",
      modified_path = modified_path or "",
      original_revision = original_revision,
      modified_revision = modified_revision,
      conflict = is_conflict,
    }, true)
  end
end

return M
