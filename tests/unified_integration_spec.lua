local commands = require("codediff.commands")

local function setup_command()
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

describe("Unified Mode Integration", function()
  local temp_dir

  before_each(function()
    local nui_dir = vim.fn.stdpath("data") .. "/nui.nvim"
    nui_dir = nui_dir:gsub("\\", "/")
    if not package.path:find(nui_dir) then
      package.path = package.path .. ";" .. nui_dir .. "/lua/?.lua;" .. nui_dir .. "/lua/?/init.lua"
    end

    setup_command()

    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")

    local function git(args)
      local cmd
      if vim.fn.has("win32") == 1 then
        cmd = string.format('git -C "%s" %s', temp_dir, args)
      else
        cmd = string.format('git -C %s %s', vim.fn.shellescape(temp_dir), args)
      end
      return vim.fn.system(cmd)
    end

    git("init")
    git("branch -m main")
    git('config user.email "test@example.com"')
    git('config user.name "Test User"')

    vim.fn.writefile({"line 1", "line 2"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Initial commit"')

    vim.fn.writefile({"line 1", "line 2 modified"}, temp_dir .. "/file.txt")
    git("add file.txt")
    git('commit -m "Second commit"')

    vim.fn.writefile({"file a content"}, temp_dir .. "/file_a.txt")
    vim.fn.writefile({"file b content"}, temp_dir .. "/file_b.txt")

    vim.cmd("edit " .. temp_dir .. "/file.txt")
  end)

  after_each(function()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.wait(200)

    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end

    _G._codediff_use_unified = nil
  end)

  local function assert_unified_view_opened()
    local opened = vim.wait(5000, function()
      return vim.fn.tabpagenr('$') > 1
    end)
    assert.is_true(opened, "Should open a new tab")

    local has_diff_buf = false
    vim.wait(2000, function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].filetype == "diff" then
          has_diff_buf = true
          return true
        end
      end
      return false
    end)
    assert.is_true(has_diff_buf, "Should have diff buffer")
  end

  local function get_unified_buffer_lines()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "diff" then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end
    end
    return nil
  end

  it("Creates unified view with --unified flag", function()
    vim.cmd("CodeDiff --unified HEAD~1 HEAD")
    assert_unified_view_opened()

    local lines = get_unified_buffer_lines()
    assert.is_not_nil(lines, "Should have unified buffer")

    local has_hunk_header = false
    for _, line in ipairs(lines) do
      if line:match("^@@") then
        has_hunk_header = true
        break
      end
    end
    assert.is_true(has_hunk_header, "Should have hunk header")
  end)

  it("Creates unified view for file comparison", function()
    vim.cmd("CodeDiff --unified file " .. temp_dir .. "/file_a.txt " .. temp_dir .. "/file_b.txt")
    assert_unified_view_opened()

    local lines = get_unified_buffer_lines()
    assert.is_not_nil(lines, "Should have unified buffer")
  end)

  it("Respects config default_layout setting", function()
    require("codediff").setup({
      diff = {
        default_layout = "unified",
      }
    })

    vim.cmd("CodeDiff HEAD~1 HEAD")
    assert_unified_view_opened()

    local lines = get_unified_buffer_lines()
    assert.is_not_nil(lines, "Should have unified buffer")
  end)

  it("Shows deletions and insertions", function()
    vim.cmd("CodeDiff --unified HEAD~1 HEAD")
    assert_unified_view_opened()

    vim.wait(1000)

    local lines = get_unified_buffer_lines()
    assert.is_not_nil(lines, "Should have unified buffer")

    local has_deletion = false
    local has_insertion = false
    for _, line in ipairs(lines) do
      if line:match("^%-") then
        has_deletion = true
      end
      if line:match("^%+") then
        has_insertion = true
      end
    end

    assert.is_true(has_deletion or has_insertion, "Should have diff markers")
  end)

  it("Applies highlights to unified buffer", function()
    vim.cmd("CodeDiff --unified HEAD~1 HEAD")
    assert_unified_view_opened()

    vim.wait(1000)

    local highlights = require("codediff.ui.highlights")
    local buf = nil
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "diff" then
        buf = bufnr
        break
      end
    end

    assert.is_not_nil(buf, "Should find diff buffer")

    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks > 0, "Should have highlight extmarks")
  end)
end)
