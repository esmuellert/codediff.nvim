local config = require("codediff.config")
local gutter_signs = require("codediff.ui.gutter_signs")
local path = require("codediff.core.path")
local gutter_signs_namespace = vim.api.nvim_create_namespace("codediff-gutter-signs")

local get_signs = function(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, gutter_signs_namespace, 0, -1, { details = true })
  return vim.tbl_map(function(mark)
    return {
      row = mark[2],
      text = vim.trim(mark[4].sign_text or ""),
      raw_text = mark[4].sign_text,
      hl = mark[4].sign_hl_group,
      number_hl = mark[4].number_hl_group,
      priority = mark[4].priority,
      end_row = mark[4].end_row,
    }
  end, marks)
end

local find_sign = function(bufnr, text)
  for _, sign in ipairs(get_signs(bufnr)) do
    if sign.text == text then
      return sign
    end
  end
end

local create_session = function()
  local original_bufnr = vim.api.nvim_create_buf(false, true)
  local modified_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(original_bufnr, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_buf_set_lines(modified_bufnr, 0, -1, false, { "one", "changed", "three" })

  local original_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(original_win, original_bufnr)
  vim.cmd("rightbelow vsplit")
  local modified_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(modified_win, modified_bufnr)

  return {
    layout = "side-by-side",
    suspended = false,
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    original_win = original_win,
    modified_win = modified_win,
  }
end

local destroy_session = function(session)
  gutter_signs.clear_buffer(session.original_bufnr)
  gutter_signs.clear_buffer(session.modified_bufnr)
  if vim.api.nvim_win_is_valid(session.modified_win) then
    vim.api.nvim_win_close(session.modified_win, true)
  end
  for _, bufnr in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
end

local changed_ranges = {
  {
    original = { start_line = 2, end_line = 3 },
    modified = { start_line = 2, end_line = 3 },
  },
}

describe("Gutter signs", function()
  local session

  before_each(function()
    config.options = vim.deepcopy(config.defaults)
    session = create_session()
  end)

  after_each(function()
    destroy_session(session)
  end)

  it("does not create signs or change window options when disabled", function()
    vim.wo[session.original_win].signcolumn = "yes:2"
    vim.wo[session.original_win].statuscolumn = "%C%=%l %s"

    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)

    assert.same({}, get_signs(session.original_bufnr))
    assert.equals("yes:2", vim.wo[session.original_win].signcolumn)
    assert.equals("%C%=%l %s", vim.wo[session.original_win].statuscolumn)
  end)

  it("preserves move signs when changed signs are disabled", function()
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)
    gutter_signs.set_move_range(session.original_bufnr, 1, 3)

    assert.equals(250, find_sign(session.original_bufnr, "┌").priority)
    assert.equals(250, find_sign(session.original_bufnr, "│").priority)
    assert.equals(250, find_sign(session.original_bufnr, "└").priority)
  end)

  it("uses the enabled defaults for changed signs", function()
    config.options.diff.gutter_signs = {}
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)

    local original = get_signs(session.original_bufnr)[1]
    assert.same({
      row = 1,
      raw_text = "－",
      priority = 100,
      hl = "CodeDiffGutterDelete",
      number_hl = "CodeDiffGutterDeleteNumber",
    }, {
      row = original.row,
      raw_text = original.raw_text,
      priority = original.priority,
      hl = original.hl,
      number_hl = original.number_hl,
    })

    local modified = get_signs(session.modified_bufnr)[1]
    assert.equals("＋", modified.raw_text)
    assert.equals("CodeDiffGutterInsert", modified.hl)
    assert.equals("CodeDiffGutterInsertNumber", modified.number_hl)
  end)

  it("supports custom text and disabled number highlights", function()
    config.options.diff.gutter_signs = {
      insert_text = "++",
      delete_text = "--",
      highlight_numbers = false,
    }
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)

    local original = get_signs(session.original_bufnr)[1]
    local modified = get_signs(session.modified_bufnr)[1]
    assert.equals("--", original.raw_text)
    assert.equals("++", modified.raw_text)
    assert.is_nil(original.number_hl)
    assert.is_nil(modified.number_hl)
  end)

  it("leaves unchanged lines alone when unchanged_priority is nil", function()
    config.options.diff.gutter_signs = { changed_priority = 100 }
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, {})

    assert.same({}, get_signs(session.original_bufnr))
  end)

  it("uses one ranged whitespace blocker for the whole buffer", function()
    config.options.diff.gutter_signs = { changed_priority = 100, unchanged_priority = 99 }
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)

    local blocker = find_sign(session.original_bufnr, "")
    assert.equals("", blocker.text)
    assert.equals(99, blocker.priority)
    assert.equals(0, blocker.row)
    assert.equals(2, blocker.end_row)
    assert.equals(100, find_sign(session.original_bufnr, "－").priority)
  end)

  it("keeps external signs and window options untouched", function()
    config.options.diff.gutter_signs = { changed_priority = 100, unchanged_priority = 99 }
    vim.wo[session.original_win].signcolumn = "yes:2"
    vim.wo[session.original_win].statuscolumn = "%C%=%l %s"
    local external_namespace = vim.api.nvim_create_namespace("codediff-gutter-signs-test-external")
    vim.api.nvim_buf_set_extmark(session.original_bufnr, external_namespace, 0, 0, {
      sign_text = "X",
      priority = 98,
    })

    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, {})

    local external = vim.api.nvim_buf_get_extmarks(session.original_bufnr, external_namespace, 0, -1, { details = true })
    assert.equals(99, get_signs(session.original_bufnr)[1].priority)
    assert.equals(98, external[1][4].priority)
    assert.equals("yes:2", vim.wo[session.original_win].signcolumn)
    assert.equals("%C%=%l %s", vim.wo[session.original_win].statuscolumn)
  end)

  it("lets move signs override changed signs", function()
    config.options.diff.gutter_signs = { changed_priority = 100 }
    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, {
      {
        original = { start_line = 1, end_line = 4 },
        modified = { start_line = 1, end_line = 4 },
      },
    })
    gutter_signs.set_move_range(session.original_bufnr, 1, 3)

    assert.equals(0, find_sign(session.original_bufnr, "┌").row)
    assert.equals(1, find_sign(session.original_bufnr, "│").row)
    assert.equals(2, find_sign(session.original_bufnr, "└").row)

    -- Priority, not extmark creation order, has to decide the winner.
    local changed_priority = find_sign(session.original_bufnr, "－").priority
    for _, glyph in ipairs({ "┌", "│", "└" }) do
      assert.is_true(find_sign(session.original_bufnr, glyph).priority > changed_priority)
    end
  end)

  it("keeps move signs at their standalone priority when changed signs are enabled", function()
    config.options.diff.gutter_signs = false
    gutter_signs.set_move_range(session.original_bufnr, 1, 1)
    local without_gutter = find_sign(session.original_bufnr, "─").priority

    gutter_signs.clear_buffer(session.original_bufnr)
    config.options.diff.gutter_signs = { changed_priority = 100 }
    gutter_signs.set_move_range(session.original_bufnr, 1, 1)

    assert.equals(without_gutter, find_sign(session.original_bufnr, "─").priority)
  end)

  it("still renders the diff when Neovim rejects the sign text", function()
    local core = require("codediff.ui.core")
    local highlights = require("codediff.ui.highlights")
    highlights.setup()
    config.options.diff.gutter_signs = { insert_text = "→→→" }

    local original_lines = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
    local modified_lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    local ok = pcall(
      core.render_diff,
      session.original_bufnr,
      session.modified_bufnr,
      original_lines,
      modified_lines,
      { changes = changed_ranges, moves = {} }
    )

    assert.is_true(ok)
    local rendered = vim.api.nvim_buf_get_extmarks(session.modified_bufnr, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#rendered > 0)
  end)

  it("keeps a growing whole-file sign anchored across replacement and appends", function()
    config.options.diff.gutter_signs = { changed_priority = 100 }
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "loading" })
    gutter_signs.set_whole_file(session.modified_bufnr, "modified")

    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, { "one", "two", "three" })
    local sign = get_signs(session.modified_bufnr)[1]
    assert.equals("＋", sign.text)
    assert.equals("CodeDiffGutterInsert", sign.hl)
    assert.equals("CodeDiffGutterInsertNumber", sign.number_hl)
    assert.equals(0, sign.row)
    assert.equals(3, sign.end_row)

    vim.api.nvim_buf_set_lines(session.modified_bufnr, 3, -1, false, { "loaded later" })
    assert.equals(4, get_signs(session.modified_bufnr)[1].end_row)
  end)

  it("restores whole-file signs after tab resume", function()
    config.options.diff.gutter_signs = { changed_priority = 100 }
    local lifecycle = require("codediff.ui.lifecycle")
    local state = require("codediff.ui.lifecycle.state")
    local tabpage = vim.api.nvim_get_current_tabpage()
    lifecycle.create_session(tabpage, {
      original = path.empty(),
      modified = path.make_ref("modified.txt", nil),
    }, {
      original_bufnr = session.original_bufnr,
      modified_bufnr = session.modified_bufnr,
      original_win = session.original_win,
      modified_win = session.modified_win,
      lines_diff = { changes = {}, moves = {} },
    })
    local tracked = lifecycle.get_session(tabpage)
    tracked.single_side = "modified"
    gutter_signs.set_whole_file(session.modified_bufnr, "modified")

    state.suspend_diff(tabpage)
    assert.same({}, get_signs(session.modified_bufnr))
    state.resume_diff(tabpage)

    assert.equals("＋", get_signs(session.modified_bufnr)[1].text)
    lifecycle.cleanup(tabpage)
  end)

  it("clears signs during inline and conflict transitions", function()
    config.options.diff.gutter_signs = { changed_priority = 100 }
    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    lifecycle.create_session(tabpage, {
      original = path.make_ref("original.txt", nil),
      modified = path.make_ref("modified.txt", nil),
    }, {
      original_bufnr = session.original_bufnr,
      modified_bufnr = session.modified_bufnr,
      original_win = session.original_win,
      modified_win = session.modified_win,
      lines_diff = { changes = {}, moves = {} },
    })

    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)
    lifecycle.update_layout(tabpage, "inline")
    assert.same({}, get_signs(session.original_bufnr))

    gutter_signs.set_changed_ranges(session.original_bufnr, session.modified_bufnr, changed_ranges)
    lifecycle.set_result(tabpage, session.modified_bufnr, session.modified_win)
    assert.same({}, get_signs(session.original_bufnr))
    lifecycle.cleanup(tabpage)
  end)
end)
