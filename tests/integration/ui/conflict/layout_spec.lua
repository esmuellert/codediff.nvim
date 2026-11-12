local h = require("tests.support")
local path = require("codediff.core.path")

describe("conflict editor layout", function()
  local repo
  local saved_layout
  local saved_result_position
  local saved_show_base

  before_each(function()
    h.ensure_plugin_loaded()
    local config = require("codediff.config")
    saved_layout = config.options.diff.layout
    saved_result_position = config.options.diff.conflict_result_position
    saved_show_base = config.options.diff.conflict_show_base
    config.options.diff.layout = "side-by-side"

    -- Base is taller than either side so the Base pane needs input fillers.
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "top", "base 1", "base 2", "base 3", "bottom" })
    repo.git("add file.txt")
    repo.git("commit -m base")
    repo.git("checkout -b feature")
    repo.write_file("file.txt", { "top", "feature", "bottom" })
    repo.git("commit -am feature")
    repo.git("checkout main")
    repo.write_file("file.txt", { "top", "main", "bottom" })
    repo.git("commit -am main")
    local merge_output = repo.git("merge feature --no-edit")
    assert.is_true(merge_output:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
  end)

  after_each(function()
    local config = require("codediff.config")
    config.options.diff.layout = saved_layout
    config.options.diff.conflict_result_position = saved_result_position
    config.options.diff.conflict_show_base = saved_show_base
    require("codediff.ui.lifecycle").cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
    end
  end)

  local function open_conflict_editor()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("file.txt")))

    local ready = false
    require("codediff.ui.view").create({
      git_root = repo.dir,
      original = path.make_ref("file.txt", repo.dir),
      modified = path.make_ref("file.txt", repo.dir),
      original_revision = ":3",
      modified_revision = ":2",
      conflict = true,
    }, nil, function()
      ready = true
    end)

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session
    assert.is_true(
      vim.wait(15000, function()
        session = lifecycle.get_session(tabpage)
        return ready
          and session
          and session.original_win
          and session.modified_win
          and session.result_win
          and vim.api.nvim_win_is_valid(session.original_win)
          and vim.api.nvim_win_is_valid(session.modified_win)
          and vim.api.nvim_win_is_valid(session.result_win)
      end, 50),
      "conflict editor never became ready"
    )
    return session, tabpage
  end

  local function displayed_rows(bufnr)
    local rows = vim.api.nvim_buf_line_count(bufnr)
    for _, count in pairs(require("codediff.ui.filler").get_virt_line_counts(bufnr)) do
      rows = rows + count
    end
    return rows
  end

  it("places Result between the two inputs in center mode", function()
    require("codediff.config").options.diff.conflict_result_position = "center"
    local session = open_conflict_editor()

    assert.is_nil(session.base_win, "Base pane is opt-in")
    local original_position = vim.api.nvim_win_get_position(session.original_win)
    local modified_position = vim.api.nvim_win_get_position(session.modified_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    assert.equals(original_position[1], result_position[1])
    assert.equals(modified_position[1], result_position[1])
    assert.is_true(result_position[2] > math.min(original_position[2], modified_position[2]))
    assert.is_true(result_position[2] < math.max(original_position[2], modified_position[2]))
  end)

  it("places Base between the two inputs above Result when enabled in bottom mode", function()
    local config = require("codediff.config")
    config.options.diff.conflict_result_position = "bottom"
    config.options.diff.conflict_show_base = true
    local session = open_conflict_editor()

    assert.is_true(session.base_win ~= nil and vim.api.nvim_win_is_valid(session.base_win), "Base pane must open")
    assert.same({ "top", "base 1", "base 2", "base 3", "bottom" }, vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false))
    assert.is_false(vim.bo[session.base_bufnr].modifiable)
    -- A stage-:1 virtual revision buffer, highlighted without setting
    -- filetype, so FileType never fires and no LSP attaches to it.
    local base_name = vim.api.nvim_buf_get_name(session.base_bufnr)
    assert.is_not_nil(base_name:match("^codediff:///.+///:1/file%.txt$"), base_name)
    assert.equals("", vim.bo[session.base_bufnr].filetype)
    assert.is_true(vim.bo[session.base_bufnr].buflisted)
    assert.is_true(vim.wo[session.base_win].scrollbind)
    assert.is_true(vim.wo[session.base_win].winbar:find("Base", 1, true) ~= nil)

    local original_position = vim.api.nvim_win_get_position(session.original_win)
    local modified_position = vim.api.nvim_win_get_position(session.modified_win)
    local base_position = vim.api.nvim_win_get_position(session.base_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    assert.equals(original_position[1], base_position[1])
    assert.equals(modified_position[1], base_position[1])
    assert.is_true(base_position[2] > math.min(original_position[2], modified_position[2]))
    assert.is_true(base_position[2] < math.max(original_position[2], modified_position[2]))
    assert.is_true(result_position[1] > base_position[1])

    -- All three top panes show the same number of rows.
    local base_rows = displayed_rows(session.base_bufnr)
    assert.equals(base_rows, displayed_rows(session.original_bufnr))
    assert.equals(base_rows, displayed_rows(session.modified_bufnr))
  end)

  it("stacks Base above Result in the middle column in center mode", function()
    local config = require("codediff.config")
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_show_base = true
    local session = open_conflict_editor()

    assert.is_true(session.base_win ~= nil and vim.api.nvim_win_is_valid(session.base_win), "Base pane must open")
    local base_position = vim.api.nvim_win_get_position(session.base_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    local original_position = vim.api.nvim_win_get_position(session.original_win)
    assert.equals(result_position[2], base_position[2])
    assert.equals(original_position[1], base_position[1])
    assert.is_true(result_position[1] > base_position[1])
  end)

  it("toggles Base on and off and restores two-column alignment", function()
    local session, tabpage = open_conflict_editor()
    local base_view = require("codediff.ui.conflict.view.base")
    local window_count = #vim.api.nvim_tabpage_list_wins(tabpage)
    assert.equals(3, displayed_rows(session.original_bufnr))

    base_view.toggle(tabpage)
    assert.is_true(base_view.is_visible(session))
    assert.equals(window_count + 1, #vim.api.nvim_tabpage_list_wins(tabpage))
    assert.equals(5, displayed_rows(session.original_bufnr))
    assert.equals(5, displayed_rows(session.modified_bufnr))
    assert.equals(5, displayed_rows(session.base_bufnr))

    base_view.toggle(tabpage)
    assert.is_false(base_view.is_visible(session))
    assert.is_nil(session.base_win)
    assert.equals(window_count, #vim.api.nvim_tabpage_list_wins(tabpage))
    assert.equals(3, displayed_rows(session.original_bufnr))
    assert.equals(3, displayed_rows(session.modified_bufnr))
  end)

  it("toggles Base with the configured key from an input pane and from Base itself", function()
    local session = open_conflict_editor()
    local base_view = require("codediff.ui.conflict.view.base")

    local function press_toggle(bufnr)
      local lhs
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if map.desc == "Toggle merge base pane" then
          lhs = map.lhs
        end
      end
      assert.is_true(lhs ~= nil, "toggle_base must be mapped in buffer " .. bufnr)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
    end

    vim.api.nvim_set_current_win(session.modified_win)
    press_toggle(session.modified_bufnr)
    assert.is_true(base_view.is_visible(session))
    assert.equals(session.modified_win, vim.api.nvim_get_current_win(), "toggling keeps focus")

    vim.api.nvim_set_current_win(session.base_win)
    press_toggle(session.base_bufnr)
    assert.is_false(base_view.is_visible(session))
    assert.equals(session.modified_win, vim.api.nvim_get_current_win(), "focus falls back to Current")
  end)
end)
