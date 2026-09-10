local M = {}

-- Build a block with deliberately different buffer coordinates in each pane.
-- Only the public conflict entry points render it; no calculator/backend calls.
function M.open_block(screen, case_index)
  return screen:exec(
    [[
    local case_index = ...
    local case = require('tests.fixtures.conflict_gutter')[case_index]
    local conflict = require('codediff.ui.conflict')
    local lifecycle = require('codediff.ui.lifecycle')
    local path = require('codediff.core.path')
    local filler = require('codediff.ui.filler')
    require('codediff').setup({ diff = { filler_text = '╱' } })
    local words = { 'one', 'two', 'three', 'four', 'five', 'six' }
    local function buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end
    local function window(buf, split)
      if split then vim.cmd('rightbelow vsplit') end
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      for name, value in pairs({
        number = false, relativenumber = false, foldcolumn = '0',
        signcolumn = 'yes', statuscolumn = '', wrap = false,
        cursorline = false, cursorcolumn = false, winbar = '',
      }) do
        vim.wo[win][name] = value
      end
      return win
    end
    local original_buf = buffer(words)
    local original_win = window(original_buf)
    local modified_lines = { 'prefix', 'prefix' }
    vim.list_extend(modified_lines, words)
    local modified_buf = buffer(modified_lines)
    local modified_win = window(modified_buf, true)
    local base_lines = { 'base one', 'base two', 'base three', 'base four', 'base five', 'base six', 'base seven' }
    local result_buf = buffer(base_lines)
    local result_win = window(result_buf, true)
    local tab = vim.api.nvim_get_current_tabpage()
    lifecycle.create_session(tab, {
      conflict = true, original = path.make_ref('', nil), modified = path.make_ref('', nil),
    }, {
      original_bufnr = original_buf, modified_bufnr = modified_buf,
      original_win = original_win, modified_win = modified_win,
    })
    lifecycle.set_result(tab, result_buf, result_win)
    lifecycle.set_result_base_lines(tab, base_lines)
    local blocks = {{
      base_range = { start_line = 4, end_line = 6 },
      result_range = { start_line = 4, end_line = 6 },
      output1_range = vim.deepcopy(case.range),
      output2_range = { start_line = case.range.start_line + 2, end_line = case.range.end_line + 2 },
    }}
    lifecycle.set_conflict_blocks(tab, blocks)
    for anchor, count in pairs(case.fillers) do
      filler.place(original_buf, anchor - 1, count)
      filler.place(modified_buf, anchor + 1, count)
    end
    conflict.initialize_tracking(result_buf, blocks)
    conflict.attach_gutter(original_win, modified_win)
    conflict.setup_refresh_autocmd(tab, result_buf)
    conflict.refresh(lifecycle.get_session(tab))
    vim.api.nvim_win_call(original_win, function()
      vim.fn.winrestview({ topline = 1, topfill = case.fillers[0] or 0 })
    end)
    return {
      tab = tab, original = original_win, modified = modified_win, result = result_win,
      foreground = vim.api.nvim_get_hl(0, { name = 'CodeDiffConflictSign', link = false }).fg,
    }
  ]],
    { case_index }
  )
end

function M.expect_pane(screen, win, rows, label, highlight)
  local position = screen:exec(
    [[
    local win = ...
    local position = vim.api.nvim_win_get_position(win)
    if vim.wo[win].winbar ~= '' then position[1] = position[1] + 1 end
    return position
  ]],
    { win }
  )
  local row, col = position[1] + 1, position[2] + 1
  screen:expect_rows(row, col, rows, label)
  if highlight then
    local expected = type(highlight) == "table" and highlight or { foreground = highlight }
    for index, text in ipairs(rows) do
      local first = vim.fn.strcharpart(text, 0, 1)
      if first == "[" or first == "╭" or first == "│" or first == "╰" then
        for offset = 0, 1 do
          local actual = screen:highlight(row + index - 1, col + offset)
          for attr, value in pairs(expected) do
            assert.equals(value, actual[attr], label .. ": marker " .. attr .. " on display row " .. index)
          end
        end
      end
    end
  end
end

function M.block_rows(case)
  local modified = { "  prefix", "  prefix" }
  vim.list_extend(modified, case.rows)
  return {
    original = case.rows,
    modified = modified,
    result = { "  base one", "  base two", "  base three", "╭─base four", "╰─base five", "  base six", "  base seven" },
  }
end

-- A small real merge with an interior filler in incoming, plus a second file
-- whose filler is on the opposite side. Expectations are authored below.
function M.create_repo()
  local repo = require("tests.helpers").create_temp_git_repo()
  repo.write_file("conf.txt", { "before", "base1", "base2", "base3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "baseB", "afterB" })
  repo.write_file("deleted.txt", { "deleted one", "deleted two" })
  repo.git("add -A")
  repo.git("commit -m base")
  repo.git("checkout -b incoming")
  repo.write_file("conf.txt", { "before", "base1", "THEIRS2", "THEIRS3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "THEIRS_B", "extraB", "afterB" })
  repo.git("commit -am incoming")
  repo.git("checkout main")
  repo.write_file("conf.txt", { "before", "OURS1", "inserted", "OURS2", "base3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "OURS_B", "afterB" })
  repo.git("commit -am current")
  local _, code = repo.git("merge incoming --no-edit")
  assert.equals(1, code, "fixture must produce a merge conflict")
  repo.write_file("fresh.txt", { "fresh one", "fresh two" })
  repo.write_file("plain-left.txt", { "before", "same", "keep", "after" })
  repo.write_file("plain-right.txt", { "before", "same", "keep", "inserted", "after" })
  return repo
end

M.merge_rows = {
  original = { "  before", "╭─base1", "│ THEIRS2", "│ ╱╱╱╱", "╰─THEIRS3", "  after", "  tail" },
  modified = { "  before", "╭─OURS1", "│ inserted", "│ OURS2", "╰─base3", "  after", "  tail" },
  result = { "  before", "╭─base1", "│ base2", "╰─base3", "  after", "  tail" },
}

M.other_merge_rows = {
  original = { "  beforeB", "╭─THEIRS_B", "╰─extraB", "  afterB" },
  modified = { "  beforeB", "╭─╱╱╱╱", "╰─OURS_B", "  afterB" },
  result = { "  beforeB", "[ baseB", "  afterB" },
}

function M.open_merge(screen, repo)
  screen:exec(
    [[
    local root = ...
    require('codediff').setup({ diff = { filler_text = '╱', jump_to_first_change = false } })
    vim.o.number = false
    vim.o.relativenumber = false
    vim.o.foldcolumn = '0'
    local path = require('codediff.core.path')
    _G.gutter_test_config = function(file)
      return {
        git_root = root, conflict = true,
        original = path.make_ref(file or 'conf.txt', root),
        modified = path.make_ref(file or 'conf.txt', root),
        original_revision = ':3', modified_revision = ':2',
      }
    end
    require('codediff.ui.view').create(gutter_test_config(), '', function()
      _G.gutter_test_ready = true
      _G.gutter_test_tab = vim.api.nvim_get_current_tabpage()
    end)
  ]],
    { repo.dir }
  )
  screen:wait_for(function()
    return screen:exec("return _G.gutter_test_ready == true")
  end, "merge view did not open")
  return M.panes(screen)
end

function M.panes(screen)
  return screen:exec([[
    local session = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
    return {
      tab = gutter_test_tab, original = session.original_win, modified = session.modified_win,
      result = session.result_win, result_buf = session.result_bufnr,
    }
  ]])
end

function M.return_to_merge(screen, file)
  screen:exec(
    [[
    local file = ...
    require('codediff.ui.view').update(gutter_test_tab, gutter_test_config(file), false)
  ]],
    { file or "conf.txt" }
  )
  screen:wait_for(function()
    return screen:exec(
      [[
      local file = ...
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      return s and s.stored_diff_result ~= nil and s.result_win ~= nil
        and vim.api.nvim_buf_get_name(s.result_bufnr):sub(-#file) == file
    ]],
      { file or "conf.txt" }
    )
  end, "merge view did not return")
  return M.panes(screen)
end

function M.open_plain(screen, repo)
  screen:exec(
    [[
    local root = ...
    local path = require('codediff.core.path')
    require('codediff.ui.view').update(gutter_test_tab, {
      original = path.make_ref(root .. '/plain-left.txt', nil),
      modified = path.make_ref(root .. '/plain-right.txt', nil),
    }, false)
  ]],
    { repo.dir }
  )
  screen:wait_for(function()
    return screen:exec([[
      local s = require('codediff.ui.lifecycle').get_session(gutter_test_tab)
      return s and s.stored_diff_result ~= nil and s.result_win == nil
    ]])
  end, "plain diff did not open")
  return M.panes(screen)
end

function M.expect_no_conflict_markers(screen, win)
  local rect = screen:exec(
    [[
    local win = ...
    local p = vim.api.nvim_win_get_position(win)
    return { p[1] + 1, p[2] + 1, vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win) }
  ]],
    { win }
  )
  for row = rect[1], rect[1] + rect[3] - 1 do
    local text = screen:text(row, rect[2], rect[4])
    for _, glyph in ipairs({ "╭", "│", "╰", "[" }) do
      assert.is_nil(text:find(glyph, 1, true), "unexpected conflict marker in window " .. win .. ": " .. text)
    end
  end
end

return M
