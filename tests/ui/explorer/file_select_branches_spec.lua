-- Two branches of the explorer's file-select handler had no coverage: a file
-- added in the revision being viewed, and directory comparison mode. Stubbing
-- either left all 90 specs green.

local h = dofile("tests/helpers.lua")

local function open_explorer_on(dir, focus_file)
  local lifecycle = require("codediff.ui.lifecycle")
  lifecycle.cleanup_all()
  if focus_file then
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. focus_file))
  end
  vim.cmd("CodeDiff")
  local tabpage, explorer
  local ready = vim.wait(15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local e = lifecycle.get_panel_view(tp)
      if e and e.winid and vim.api.nvim_win_is_valid(e.winid) then
        tabpage, explorer = tp, e
        return true
      end
    end
    return false
  end, 50)
  assert.is_true(ready, "explorer should open")
  return tabpage, explorer
end

describe("explorer file select: added files", function()
  local repo, saved_cwd

  before_each(function()
    h.ensure_plugin_loaded()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    repo.write_file("kept.txt", { "k1", "k2" })
    repo.git("add -A")
    repo.git("commit -qm base")
    -- Added and staged, so the explorer lists it under Staged Changes with
    -- status "A" rather than as untracked.
    repo.write_file("added.txt", { "new1", "new2", "new3" })
    repo.git("add added.txt")
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
  end)

  after_each(function()
    if saved_cwd and vim.fn.isdirectory(saved_cwd) == 1 then
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end
    require("codediff.ui.lifecycle").cleanup_all()
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  it("shows the added file's contents, not an empty diff", function()
    local tabpage, explorer = open_explorer_on(repo.dir, "kept.txt")

    explorer.on_file_select({
      path = "added.txt",
      status = "A",
      group = "staged",
      git_root = repo.dir,
    }, {})

    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(
      vim.wait(15000, function()
        local s = lifecycle.get_session(tabpage)
        if not (s and s.modified_bufnr and vim.api.nvim_buf_is_valid(s.modified_bufnr)) then
          return false
        end
        local text = table.concat(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, -1, false), "\n")
        return text:find("new1", 1, true) ~= nil
      end, 50),
      "an added file must show its staged contents"
    )

    -- An added file has nothing to compare against, so it is shown one-sided.
    local session = lifecycle.get_session(tabpage)
    assert.is_not_nil(session.single_side, "an added file should render as a single side")
  end)
end)

describe("explorer file select: directory comparison", function()
  local dir_a, dir_b, saved_cwd

  before_each(function()
    h.ensure_plugin_loaded()
    saved_cwd = vim.fn.getcwd()
    dir_a = h.create_temp_dir()
    dir_b = h.create_temp_dir()
    vim.fn.writefile({ "left1", "same" }, dir_a .. "/f.txt")
    vim.fn.writefile({ "right1", "same" }, dir_b .. "/f.txt")
  end)

  after_each(function()
    if saved_cwd and vim.fn.isdirectory(saved_cwd) == 1 then
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end
    require("codediff.ui.lifecycle").cleanup_all()
    for _, d in ipairs({ dir_a, dir_b }) do
      if d then
        vim.fn.delete(d, "rf")
      end
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  it("diffs the two directories' copies of the file", function()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()
    vim.cmd("CodeDiff dir " .. vim.fn.fnameescape(dir_a) .. " " .. vim.fn.fnameescape(dir_b))

    local tabpage, explorer
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local e = lifecycle.get_panel_view(tp)
          if e and e.winid and vim.api.nvim_win_is_valid(e.winid) then
            tabpage, explorer = tp, e
            return true
          end
        end
        return false
      end, 50),
      "directory explorer should open"
    )

    explorer.on_file_select({ path = "f.txt", status = "M", group = "unstaged" }, {})

    assert.is_true(
      vim.wait(15000, function()
        local s = lifecycle.get_session(tabpage)
        if not (s and s.original_bufnr and s.modified_bufnr) then
          return false
        end
        if not (vim.api.nvim_buf_is_valid(s.original_bufnr) and vim.api.nvim_buf_is_valid(s.modified_bufnr)) then
          return false
        end
        local left = table.concat(vim.api.nvim_buf_get_lines(s.original_bufnr, 0, -1, false), "\n")
        local right = table.concat(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, -1, false), "\n")
        return left:find("left1", 1, true) ~= nil and right:find("right1", 1, true) ~= nil
      end, 50),
      "each side must come from its own directory"
    )
  end)
end)
