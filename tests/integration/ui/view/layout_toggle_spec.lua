local h = require("tests.support")

h.ensure_plugin_loaded()

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local side_by_side = require("codediff.ui.view.side_by_side")
local welcome = require("codediff.ui.welcome")
local navigation = require("codediff.ui.view.navigation")
local inline = require("codediff.ui.inline")
local path = require("codediff.core.path")

local function setup_command()
  pcall(vim.api.nvim_del_user_command, "CodeDiff")
  local commands = require("codediff.commands")
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

local function temp_file(name, lines)
  local path = vim.fn.tempname() .. "_" .. name
  vim.fn.writefile(lines, path)
  return path
end

local function create_explorer_placeholder(git_root)
  view.create({
    panel = {
      name = "explorer",
      data = {
        status_result = {
          unstaged = {},
          staged = {},
          conflicts = {},
        },
      },
    },
    git_root = git_root,
    original = path.make_ref("", git_root),
    modified = path.make_ref("", git_root),
  })

  return vim.api.nvim_get_current_tabpage()
end

local function create_standalone_diff(left_lines, right_lines)
  local left = temp_file("layout_toggle_left.txt", left_lines)
  local right = temp_file("layout_toggle_right.txt", right_lines)
  view.create({
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  assert.is_true(h.wait_for_session_ready(tabpage, 10000), "Standalone diff should be ready")

  return tabpage, left, right
end

local function open_codediff_and_wait(repo, entry_file)
  setup_command()
  vim.fn.chdir(repo.dir)
  vim.cmd("edit " .. repo.path(entry_file or "file.txt"))
  vim.cmd("CodeDiff")

  local tabpage
  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and (session.panel or {}).view then
        tabpage = tp
        local orig_buf, mod_buf = lifecycle.get_buffers(tp)
        return orig_buf and mod_buf and vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff explorer session should be ready")

  local session = lifecycle.get_session(tabpage)
  return tabpage, session, (session.panel or {}).view
end

local function open_history_and_wait(repo, entry_file)
  local git = require("codediff.core.git")
  local commits
  local err
  local file_path = entry_file or "file.txt"

  git.get_commit_list("", repo.dir, {
    no_merges = true,
    path = file_path,
  }, function(cb_err, cb_commits)
    err = cb_err
    commits = cb_commits
  end)

  local commits_ready = vim.wait(10000, function()
    return err ~= nil or commits ~= nil
  end, 100)

  assert.is_true(commits_ready, "History commits should load")
  assert.is_nil(err, "History commit list should load without error")
  assert.is_true(commits and #commits > 0, "History should contain commits")

  view.create({
    panel = {
      name = "history",
      data = {
        commits = commits,
        range = "",
        file_path = file_path,
      },
    },
    git_root = repo.dir,
    original = path.make_ref("", repo.dir),
    modified = path.make_ref("", repo.dir),
  }, "")

  local tabpage
  local history
  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      local panel = lifecycle.get_panel_view(tp)
      if session and session.panel and session.panel.name == "history" and panel then
        tabpage = tp
        history = panel
        return history.data.current_selection
          and session.original_revision
          and session.modified_revision
          and session.original_bufnr
          and session.modified_bufnr
          and vim.api.nvim_buf_is_valid(session.original_bufnr)
          and vim.api.nvim_buf_is_valid(session.modified_bufnr)
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff history session should be ready")

  return tabpage, lifecycle.get_session(tabpage), history
end

local function select_explorer_file(tabpage, explorer, file_data, wait_for)
  explorer.on_file_select(file_data)
  local ok = vim.wait(10000, function()
    local session = lifecycle.get_session(tabpage)
    return session and wait_for(session)
  end, 100)
  assert.is_true(ok, "Explorer selection should update the diff view")
end

local function get_buffer_mapping_callback(bufnr, lhs)
  return vim.api.nvim_buf_call(bufnr, function()
    local map = vim.fn.maparg(lhs, "n", false, true)
    return map and map.callback or nil
  end)
end

local function wait_for(tabpage, predicate, message)
  local ok = vim.wait(10000, function()
    local session = lifecycle.get_session(tabpage)
    return session and predicate(session)
  end, 100)
  assert.is_true(ok, message)
end

local function capture_layout_snapshot(tabpage)
  local session = lifecycle.get_session(tabpage)
  local panel = session and (session.panel or {}).view or nil
  local panel_win = panel and panel.winid
  local diff_win = session and session.modified_win
  return {
    window_count = #vim.api.nvim_tabpage_list_wins(tabpage),
    panel_width = panel_win and vim.api.nvim_win_is_valid(panel_win) and vim.api.nvim_win_get_width(panel_win) or nil,
    diff_width = diff_win and vim.api.nvim_win_is_valid(diff_win) and vim.api.nvim_win_get_width(diff_win) or nil,
    same_diff_window = session and session.original_win == session.modified_win or false,
  }
end

local function move_cursor_to_hunk(winid, bufnr, range)
  local visible_buf = vim.api.nvim_win_get_buf(winid)
  local line_count = vim.api.nvim_buf_line_count(visible_buf)
  local target_line = range.start_line
  if range.start_line >= range.end_line then
    target_line = math.max(1, range.start_line - 1)
  end
  target_line = math.max(1, math.min(target_line, line_count))
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { target_line, 0 })
end

describe("Layout toggle", function()
  local repo
  local paths = {}
  local original_cwd

  local function track(path)
    table.insert(paths, path)
    return path
  end

  before_each(function()
    require("codediff").setup({
      diff = { layout = "side-by-side" },
      keymaps = {
        view = {
          stage_hunk = "H",
          unstage_hunk = "J",
          discard_hunk = "K",
          open_in_prev_tab = "P",
        },
      },
    })
    repo = nil
    paths = {}
    original_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end

    for _, path in ipairs(paths) do
      pcall(vim.fn.delete, path)
    end
    if repo then
      repo.cleanup()
    end
    vim.fn.chdir(original_cwd)
  end)

  it("toggles a normal diff per session without changing the default layout", function()
    local tabpage, left, right = create_standalone_diff({ "one", "two", "three" }, { "one", "changed", "three" })
    track(left)
    track(right)
    assert.equals("side-by-side", view.get_current_layout(tabpage))
    assert.equals("side-by-side", require("codediff.config").options.diff.layout)

    assert.is_true(view.toggle_layout(tabpage))
    local toggled_inline = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.layout == "inline" and session.original_win == session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
    end, 50)
    assert.is_true(toggled_inline, "Diff should toggle into inline layout")
    assert.equals("side-by-side", require("codediff.config").options.diff.layout)

    assert.is_true(view.toggle_layout(tabpage))
    local toggled_back = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session
        and session.layout == "side-by-side"
        and session.original_win
        and session.modified_win
        and session.original_win ~= session.modified_win
        and vim.api.nvim_win_is_valid(session.original_win)
        and vim.api.nvim_win_is_valid(session.modified_win)
        and not session.single_pane
    end, 50)
    assert.is_true(toggled_back, "Diff should toggle back into side-by-side layout")
    assert.equals("side-by-side", require("codediff.config").options.diff.layout)
  end)

  it("rerenders the current history selection when toggling layouts", function()
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "version 1", "shared" })
    repo.git("add file.txt")
    repo.git('commit -m "first"')
    repo.write_file("file.txt", { "version 2", "shared", "added line" })
    repo.git("add file.txt")
    repo.git('commit -m "second"')
    repo.write_file("file.txt", { "version 3", "shared changed", "added line" })
    repo.git("add file.txt")
    repo.git('commit -m "third"')

    local tabpage, session, history = open_history_and_wait(repo, "file.txt")
    local selected = vim.deepcopy(history.data.current_selection)

    assert.equals("side-by-side", session.layout)
    assert.is_not_nil(selected, "History should track the current file selection")

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(current_session)
      local current_history = lifecycle.get_panel_view(tabpage)
      local mod_buf = current_session.modified_bufnr
      local marks = mod_buf and vim.api.nvim_buf_is_valid(mod_buf) and vim.api.nvim_buf_get_extmarks(mod_buf, inline.ns_inline, 0, -1, {}) or {}
      return current_session.layout == "inline"
        and current_session.original_win == current_session.modified_win
        and current_history
        and current_history.data.current_selection
        and current_history.data.current_selection.commit_hash == selected.commit_hash
        and current_history.data.current_selection.path == selected.path
        and #marks > 0
    end, "History toggle should replay the selected file as a native inline render")

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(current_session)
      local current_history = lifecycle.get_panel_view(tabpage)
      return current_session.layout == "side-by-side"
        and current_session.original_win
        and current_session.modified_win
        and current_session.original_win ~= current_session.modified_win
        and vim.api.nvim_win_is_valid(current_session.original_win)
        and vim.api.nvim_win_is_valid(current_session.modified_win)
        and current_history
        and current_history.data.current_selection
        and current_history.data.current_selection.commit_hash == selected.commit_hash
        and current_history.data.current_selection.path == selected.path
    end, "History toggle should restore the same selected file in side-by-side mode")
  end)

  it("toggles an untracked single-file preview without losing preview state", function()
    repo = h.create_temp_git_repo()
    repo.write_file("tracked.txt", { "tracked" })
    repo.git("add tracked.txt")
    repo.git('commit -m "initial"')
    repo.write_file("toggle_untracked.txt", { "preview line" })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "tracked.txt")
    local file_path = repo.path("toggle_untracked.txt")
    select_explorer_file(tabpage, explorer, {
      path = "toggle_untracked.txt",
      status = "??",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.single_pane == true
        and session.modified.absolute == file_path
        and session.modified_win
        and not session.original_win
        and vim.api.nvim_win_is_valid(session.modified_win)
    end)

    assert.is_true(view.toggle_layout(tabpage))
    local inline_ready = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.layout == "inline" and session.original_win == session.modified_win and session.modified.absolute == file_path
    end, 50)
    assert.is_true(inline_ready, "Untracked preview should toggle into inline layout")

    assert.is_true(view.toggle_layout(tabpage))
    local side_by_side_ready = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session
        and session.layout == "side-by-side"
        and session.single_pane == true
        and session.modified.absolute == file_path
        and session.modified_win
        and not session.original_win
        and vim.api.nvim_win_is_valid(session.modified_win)
    end, 50)
    assert.is_true(side_by_side_ready, "Untracked preview should toggle back into single-pane side-by-side")
  end)

  it("preserves original-side deleted previews across layout toggles", function()
    repo = h.create_temp_git_repo()
    repo.write_file("keep.txt", { "keep" })
    repo.write_file("gone.txt", { "tracked line" })
    repo.git("add keep.txt gone.txt")
    repo.git('commit -m "add files"')
    vim.fn.delete(repo.path("gone.txt"))

    local tabpage, _, explorer = open_codediff_and_wait(repo, "keep.txt")
    select_explorer_file(tabpage, explorer, {
      path = "gone.txt",
      status = "D",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.single_pane == true
        and session.original_win
        and not session.modified_win
        and session.original_revision == ":0"
        and session.original.absolute == repo.path("gone.txt")
        and vim.api.nvim_win_is_valid(session.original_win)
    end)

    assert.is_true(view.toggle_layout(tabpage))
    local inline_deleted_ready = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      local diff_buf = session and session.original_win and vim.api.nvim_win_is_valid(session.original_win) and vim.api.nvim_win_get_buf(session.original_win) or nil
      return session
        and session.layout == "inline"
        and session.original_win == session.modified_win
        and session.original_bufnr == diff_buf
        and session.original_revision == ":0"
        and session.original.relative == "gone.txt"
        and path.is_empty(session.modified)
    end, 50)
    assert.is_true(inline_deleted_ready, "Deleted preview should stay logically on the original side in inline mode")

    assert.is_true(view.toggle_layout(tabpage))
    local restored_deleted_ready = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session
        and session.layout == "side-by-side"
        and session.single_pane == true
        and session.original_win
        and not session.modified_win
        and session.original.absolute == repo.path("gone.txt")
        and vim.api.nvim_win_is_valid(session.original_win)
    end, 50)
    assert.is_true(restored_deleted_ready, "Deleted preview should restore to the original side in side-by-side mode")
  end)

  it("toggles the welcome page without leaving welcome state", function()
    local tabpage = create_explorer_placeholder(h.get_temp_dir())
    local welcome_buf = welcome.create_buffer(80, 24)
    side_by_side.show_welcome(tabpage, welcome_buf)

    local side_by_side_welcome = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.single_pane == true and session.modified_win and not session.original_win and welcome.is_welcome_buffer(session.modified_bufnr)
    end, 50)
    assert.is_true(side_by_side_welcome, "Welcome page should start in side-by-side single-pane mode")

    assert.is_true(view.toggle_layout(tabpage))
    local inline_welcome = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.layout == "inline" and session.original_win == session.modified_win and welcome.is_welcome_buffer(session.modified_bufnr)
    end, 50)
    assert.is_true(inline_welcome, "Welcome page should toggle into inline layout")

    assert.is_true(view.toggle_layout(tabpage))
    local restored_welcome = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session
        and session.layout == "side-by-side"
        and session.single_pane == true
        and session.modified_win
        and not session.original_win
        and welcome.is_welcome_buffer(session.modified_bufnr)
    end, 50)
    assert.is_true(restored_welcome, "Welcome page should toggle back into side-by-side welcome state")
  end)

  it("keeps hunk navigation working after toggling layouts", function()
    local tabpage, left, right = create_standalone_diff({ "keep", "old one", "middle", "old two", "tail" }, { "keep", "new one", "middle", "new two", "tail" })
    track(left)
    track(right)

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(session)
      return session.layout == "inline"
        and session.modified_win
        and vim.api.nvim_win_is_valid(session.modified_win)
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes == 2
    end, "Inline diff should be fully rendered after toggle")

    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })
    assert.is_true(navigation.next_hunk(), "next_hunk should work in inline layout after toggle")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(session.modified_win))

    vim.api.nvim_win_set_cursor(session.modified_win, { 5, 0 })
    assert.is_true(navigation.prev_hunk(), "prev_hunk should work in inline layout after toggle")
    assert.same({ 4, 0 }, vim.api.nvim_win_get_cursor(session.modified_win))

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(s)
      return s.layout == "side-by-side"
        and s.original_win
        and s.modified_win
        and s.original_win ~= s.modified_win
        and vim.api.nvim_win_is_valid(s.original_win)
        and vim.api.nvim_win_is_valid(s.modified_win)
        and not s.single_pane
        and s.stored_diff_result
        and s.stored_diff_result.changes
        and #s.stored_diff_result.changes == 2
    end, "Side-by-side diff should be fully restored after toggling back")
    session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 1, 0 })
    assert.is_true(navigation.next_hunk(), "next_hunk should still work after toggling back to side-by-side")
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(session.modified_win))
  end)

  it("keeps diffget and diffput working after toggling back to side-by-side", function()
    local tabpage, left, right = create_standalone_diff({ "line 1", "left value", "line 3" }, { "line 1", "right value", "line 3" })
    track(left)
    track(right)

    assert.is_true(view.toggle_layout(tabpage))
    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(session)
      return session.layout == "side-by-side"
        and session.original_win
        and session.modified_win
        and vim.api.nvim_win_is_valid(session.original_win)
        and vim.api.nvim_win_is_valid(session.modified_win)
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end, "Side-by-side diff should be ready before diffget/diffput assertions")

    local session = lifecycle.get_session(tabpage)
    local get_cb = get_buffer_mapping_callback(session.original_bufnr, "do")
    local put_cb = get_buffer_mapping_callback(session.modified_bufnr, "dp")
    local hunk_line = session.stored_diff_result.changes[1].original.start_line
    assert.is_function(get_cb, "diff_get mapping should exist after toggling back")
    assert.is_function(put_cb, "diff_put mapping should exist after toggling back")
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { hunk_line, 0 })
    get_cb()
    vim.wait(100)
    assert.same({ "line 1", "right value", "line 3" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))

    vim.api.nvim_buf_set_lines(session.original_bufnr, 0, -1, false, { "line 1", "left again", "line 3" })
    view.update(tabpage, {
      original = path.make_ref(left, nil),
      modified = path.make_ref(right, nil),
    }, false)
    assert.is_true(h.wait_for_session_ready(tabpage, 10000), "Diff should rerender after manual reset")

    session = lifecycle.get_session(tabpage)
    hunk_line = session.stored_diff_result.changes[1].modified.start_line
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { hunk_line, 0 })
    put_cb = get_buffer_mapping_callback(session.modified_bufnr, "dp")
    put_cb()
    vim.wait(100)
    assert.same({ "line 1", "right value", "line 3" }, vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false))
  end)

  it("keeps open_in_prev_tab working after toggle", function()
    vim.cmd("tabnew")
    local previous_tab = vim.api.nvim_get_current_tabpage()
    local tabpage, left, right = create_standalone_diff({ "line 1", "left", "line 3" }, { "line 1", "right", "line 3" })
    track(left)
    track(right)

    assert.is_true(view.toggle_layout(tabpage))
    local session = lifecycle.get_session(tabpage)
    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_win_set_cursor(session.modified_win, { 2, 0 })

    local callback = get_buffer_mapping_callback(session.modified_bufnr, "P")
    assert.is_function(callback, "open_in_prev_tab mapping should exist on toggled buffers")
    callback()

    assert.equals(previous_tab, vim.api.nvim_get_current_tabpage())
    assert.equals(vim.fn.resolve(vim.fn.fnamemodify(right, ":p")), vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())))
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("keeps explorer file navigation working after toggle", function()
    repo = h.create_temp_git_repo()
    repo.write_file("file1.txt", { "one" })
    repo.write_file("file2.txt", { "two" })
    repo.git("add file1.txt file2.txt")
    repo.git('commit -m "initial files"')
    repo.write_file("file1.txt", { "one changed" })
    repo.write_file("file2.txt", { "two changed" })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "file1.txt")
    select_explorer_file(tabpage, explorer, {
      path = "file1.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.modified.absolute == repo.path("file1.txt")
    end)

    assert.is_true(view.toggle_layout(tabpage))
    assert.is_true(navigation.next_file(), "next_file should work after toggling layout")
    local moved_next = vim.wait(10000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.modified.absolute == repo.path("file2.txt")
    end, 100)
    assert.is_true(moved_next, "Explorer next_file should move to the next file after toggle")

    assert.is_true(navigation.prev_file(), "prev_file should work after toggling layout")
    local moved_prev = vim.wait(10000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.modified.absolute == repo.path("file1.txt")
    end, 100)
    assert.is_true(moved_prev, "Explorer prev_file should move back after toggle")
  end)

  it("replays the native inline explorer layout exactly when toggled", function()
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "line 1", "line 2" })
    repo.git("add file.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file.txt", { "line 1", "line 2 changed" })

    local toggled_tabpage, _, toggled_explorer = open_codediff_and_wait(repo, "file.txt")
    select_explorer_file(toggled_tabpage, toggled_explorer, {
      path = "file.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.modified.absolute == repo.path("file.txt") and session.layout == "side-by-side"
    end)

    assert.is_true(view.toggle_layout(toggled_tabpage))
    wait_for(toggled_tabpage, function(session)
      return session.layout == "inline"
        and session.original_win == session.modified_win
        and session.modified_win
        and vim.api.nvim_win_is_valid(session.modified_win)
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end, "Toggled explorer diff should settle into inline layout")
    local toggled_snapshot = capture_layout_snapshot(toggled_tabpage)

    vim.cmd("tabclose")

    require("codediff").setup({
      diff = { layout = "inline" },
      keymaps = {
        view = {
          stage_hunk = "H",
          unstage_hunk = "J",
          discard_hunk = "K",
          open_in_prev_tab = "P",
        },
      },
    })

    local native_tabpage, _, native_explorer = open_codediff_and_wait(repo, "file.txt")
    select_explorer_file(native_tabpage, native_explorer, {
      path = "file.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.modified.absolute == repo.path("file.txt")
        and session.layout == "inline"
        and session.original_win == session.modified_win
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end)

    local native_snapshot = capture_layout_snapshot(native_tabpage)
    assert.same(native_snapshot, toggled_snapshot)
  end)

  it("keeps stage and unstage hunk working after toggle", function()
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "line 1", "line 2", "line 3" })
    repo.git("add file.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file.txt", { "line 1", "changed line", "line 3" })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "file.txt")
    select_explorer_file(tabpage, explorer, {
      path = "file.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.modified.absolute == repo.path("file.txt")
        and session.modified_revision == nil
        and session.modified_bufnr
        and vim.api.nvim_buf_is_valid(session.modified_bufnr)
        and vim.api.nvim_buf_line_count(session.modified_bufnr) >= 3
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end)

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(s)
      return s.layout == "inline"
        and s.modified_win
        and vim.api.nvim_win_is_valid(s.modified_win)
        and s.original_bufnr
        and vim.api.nvim_buf_is_valid(s.original_bufnr)
        and s.modified_bufnr
        and vim.api.nvim_buf_is_valid(s.modified_bufnr)
        and vim.api.nvim_win_get_buf(s.modified_win) == s.modified_bufnr
        and vim.api.nvim_buf_line_count(s.modified_bufnr) >= 3
        and s.stored_diff_result
        and s.stored_diff_result.changes
        and #s.stored_diff_result.changes > 0
    end, "Inline explorer diff should be ready before staging")
    local session = lifecycle.get_session(tabpage)
    move_cursor_to_hunk(session.modified_win, session.modified_bufnr, session.stored_diff_result.changes[1].modified)

    local stage_cb = get_buffer_mapping_callback(vim.api.nvim_win_get_buf(session.modified_win), "H")
    assert.is_function(stage_cb, "stage_hunk mapping should exist after toggle")
    stage_cb()

    -- Spin to let the full async chain complete (git apply → callback → refresh → status → render)
    vim.wait(10000, function()
      return false
    end, 50)

    local s = lifecycle.get_session(tabpage)
    assert.is_true(s and s.layout == "inline" and s.modified_revision == ":0", "Staging a hunk should still work after toggle")

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(s)
      return s.layout == "side-by-side"
        and s.modified_win
        and vim.api.nvim_win_is_valid(s.modified_win)
        and s.modified_bufnr
        and vim.api.nvim_buf_is_valid(s.modified_bufnr)
        and vim.api.nvim_win_get_buf(s.modified_win) == s.modified_bufnr
        and vim.api.nvim_buf_line_count(s.modified_bufnr) >= 3
        and s.stored_diff_result
        and s.stored_diff_result.changes
        and #s.stored_diff_result.changes > 0
    end, "Side-by-side staged diff should be ready before unstaging")
    session = lifecycle.get_session(tabpage)
    move_cursor_to_hunk(session.modified_win, session.modified_bufnr, session.stored_diff_result.changes[1].modified)

    local unstage_cb = get_buffer_mapping_callback(vim.api.nvim_win_get_buf(session.modified_win), "J")
    assert.is_function(unstage_cb, "unstage_hunk mapping should exist after toggling back")
    unstage_cb()

    -- Spin to let the full async chain complete
    vim.wait(10000, function()
      return false
    end, 50)

    local s = lifecycle.get_session(tabpage)
    assert.is_true(s and s.modified_revision == nil, "Unstaging a hunk should still work after toggling back")
  end)

  it("keeps discard hunk working after toggle", function()
    -- Regression: after `t` toggles layout to inline, the discard-hunk
    -- callback (bound to `K` by the outer describe's before_each) must still
    -- fire against the correct buffer AND the follow-up refresh must observe
    -- that the file now matches HEAD (no diff → welcome page). The prior
    -- `pending(...)` marked this out because the assertion used
    -- `vim.wait(10000, function() return false end)` — an unconditional 10s
    -- sleep that raced with the two-step async chain (git apply → status
    -- refresh → re-render). This version uses a real predicate on the
    -- welcome buffer, so it terminates as soon as the chain lands.
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "line 1", "line 2", "line 3" })
    repo.git("add file.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file.txt", { "line 1", "discard me", "line 3" })

    local tabpage, _, explorer = open_codediff_and_wait(repo, "file.txt")
    select_explorer_file(tabpage, explorer, {
      path = "file.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    }, function(session)
      return session.modified.absolute == repo.path("file.txt")
        and session.modified_revision == nil
        and session.modified_bufnr
        and vim.api.nvim_buf_is_valid(session.modified_bufnr)
        and vim.api.nvim_buf_line_count(session.modified_bufnr) >= 3
        and session.stored_diff_result
        and session.stored_diff_result.changes
        and #session.stored_diff_result.changes > 0
    end)

    assert.is_true(view.toggle_layout(tabpage))
    wait_for(tabpage, function(s)
      return s.layout == "inline"
        and s.modified_win
        and vim.api.nvim_win_is_valid(s.modified_win)
        and s.original_bufnr
        and vim.api.nvim_buf_is_valid(s.original_bufnr)
        and s.modified_bufnr
        and vim.api.nvim_buf_is_valid(s.modified_bufnr)
        and vim.api.nvim_win_get_buf(s.modified_win) == s.modified_bufnr
        and vim.api.nvim_buf_line_count(s.modified_bufnr) >= 3
        and s.stored_diff_result
        and s.stored_diff_result.changes
        and #s.stored_diff_result.changes > 0
    end, "Inline explorer diff should be ready before discarding")
    local session = lifecycle.get_session(tabpage)
    move_cursor_to_hunk(session.modified_win, session.modified_bufnr, session.stored_diff_result.changes[1].modified)

    -- discard_hunk pops a confirm dialog via `vim.fn.confirm`; in headless
    -- that returns 0 (no user input). Stub it to auto-select "Discard" (the
    -- 1st option in "&Discard\n&Cancel") so the async chain proceeds unattended.
    local old_confirm = vim.fn.confirm
    vim.fn.confirm = function() return 1 end

    local discard_cb = get_buffer_mapping_callback(vim.api.nvim_win_get_buf(session.modified_win), "K")
    assert.is_function(discard_cb, "discard_hunk mapping should exist after toggle")
    discard_cb()

    -- Deterministic wait for the full chain: git apply --reverse writes the
    -- working tree back to HEAD, the refresh callback re-runs `git status`,
    -- the empty result triggers the welcome page. Poll for that terminal
    -- state instead of sleeping a flat 10s (fixes the Windows-CI flake called
    -- out in the previous `pending` comment).
    local welcome_ready = vim.wait(15000, function()
      local s = lifecycle.get_session(tabpage)
      return s
        and s.modified_bufnr
        and vim.api.nvim_buf_is_valid(s.modified_bufnr)
        and welcome.is_welcome_buffer(s.modified_bufnr)
    end, 100)

    vim.fn.confirm = old_confirm

    assert.is_true(welcome_ready,
      "discard_hunk after layout toggle should end in the welcome buffer once the async chain completes")
    -- Sanity: the working tree really does match HEAD again (git-level check
    -- so we don't confuse a stale UI with actual discard success).
    local worktree = table.concat(vim.fn.readfile(repo.path("file.txt")), "\n")
    assert.equal("line 1\nline 2\nline 3", worktree,
      "working-tree file must be restored to its HEAD content after discard_hunk")
  end)

  it("does not persist the layout override across separate CodeDiff runs", function()
    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "line 1", "line 2" })
    repo.git("add file.txt")
    repo.git('commit -m "initial"')
    repo.write_file("file.txt", { "line 1", "line 2 changed" })

    local tabpage = open_codediff_and_wait(repo, "file.txt")
    assert.is_true(view.toggle_layout(tabpage))
    local toggled = vim.wait(5000, function()
      local session = lifecycle.get_session(tabpage)
      return session and session.layout == "inline"
    end, 100)
    assert.is_true(toggled, "First CodeDiff run should toggle to inline")

    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabclose")

    local second_tabpage = open_codediff_and_wait(repo, "file.txt")
    local second_session = lifecycle.get_session(second_tabpage)
    assert.equals("side-by-side", second_session.layout)
    assert.equals("side-by-side", view.get_current_layout(second_tabpage))
  end)

  it("blocks toggling in conflict-mode sessions", function()
    local tabpage, left, right = create_standalone_diff({ "left" }, { "right" })
    track(left)
    track(right)

    local session = lifecycle.get_session(tabpage)
    session.result_win = session.modified_win

    assert.is_false(view.toggle_layout(tabpage))
    assert.equals("side-by-side", session.layout)
  end)
end)
