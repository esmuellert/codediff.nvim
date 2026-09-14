-- Coverage contract: every configured keymap must be *reachable* in every
-- session shape that is supposed to provide it.
--
-- Reachability is checked through `maparg`, not `nvim_buf_get_keymap`: a
-- mapping can be listed yet unreachable if its lhs was encoded twice, which is
-- exactly the regression that broke <2-LeftMouse>, <Down> and <Up>.

local h = require("tests.support")
local path = require("codediff.core.path")
h.ensure_plugin_loaded()

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local commands = require("codediff.commands")
local config = require("codediff.config")

local function reset_config(opts)
  vim.g.mapleader = "\\"
  config.options = vim.deepcopy(config.defaults)
  require("codediff").setup(opts or {})
  require("codediff.ui.highlights").setup()
end

local function temp_file(suffix, lines)
  local f = vim.fn.tempname() .. suffix
  vim.fn.writefile(lines, f)
  return f
end

local function wait_diff(tp)
  return vim.wait(10000, function()
    local s = lifecycle.get_session(tp)
    return s and s.stored_diff_result ~= nil
  end, 50)
end

-- Is `key` reachable in `mode` on any of the session's buffers?
local function reachable(tp, key, modes)
  local s = lifecycle.get_session(tp)
  -- Build without holes: a nil mid-table would make ipairs stop early and
  -- silently skip later roles (this bit me once already).
  local bufs = {}
  for _, b in pairs({ s.original_bufnr, s.modified_bufnr, (s.panel or {}).view and (s.panel or {}).view.bufnr or nil, s.result_bufnr }) do
    table.insert(bufs, b)
  end
  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, mode in ipairs(modes) do
        local m = vim.api.nvim_buf_call(buf, function()
          return vim.fn.maparg(key, mode, false, true)
        end)
        if type(m) == "table" and next(m) ~= nil and m.buffer == 1 then
          return true
        end
      end
    end
  end
  return false
end

local NORMAL = { "n" }
local TEXTOBJ = { "o", "x" }

-- scope -> { config_key -> { expected in these shapes } }
-- "expected" lists the shapes where the mapping MUST be reachable.
local EXPECT = {
  view = {
    quit = { "standalone", "inline", "explorer", "history", "conflict" },
    next_hunk = { "standalone", "inline", "explorer", "history", "conflict" },
    prev_hunk = { "standalone", "inline", "explorer", "history", "conflict" },
    diff_get = { "standalone", "inline", "explorer", "history" },
    diff_put = { "standalone", "inline", "explorer", "history" },
    open_in_prev_tab = { "standalone", "inline", "explorer", "history", "conflict" },
    toggle_layout = { "standalone", "inline", "explorer", "history", "conflict" },
    toggle_compact = { "standalone", "inline", "explorer", "history", "conflict" },
    show_help = { "standalone", "inline", "explorer", "history", "conflict" },
    stage_hunk = { "standalone", "inline", "explorer", "history", "conflict" },
    unstage_hunk = { "standalone", "inline", "explorer", "history", "conflict" },
    discard_hunk = { "standalone", "inline", "explorer", "history", "conflict" },
    next_file = { "explorer", "history" },
    prev_file = { "explorer", "history" },
    toggle_explorer = { "explorer" },
    focus_explorer = { "explorer" },
    toggle_stage = { "explorer" },
    toggle_staged_view = { "explorer" },
    align_move = { "moves" },
  },
  explorer = {
    select = { "explorer" },
    hover = { "explorer" },
    refresh = { "explorer" },
    toggle_view_mode = { "explorer" },
    stage_all = { "explorer" },
    unstage_all = { "explorer" },
    restore = { "explorer" },
    toggle_changes = { "explorer" },
    toggle_staged = { "explorer" },
    fold_open = { "explorer" },
    fold_open_recursive = { "explorer" },
    fold_close = { "explorer" },
    fold_close_recursive = { "explorer" },
    fold_toggle = { "explorer" },
    fold_toggle_recursive = { "explorer" },
    fold_open_all = { "explorer" },
    fold_close_all = { "explorer" },
  },
  history = {
    select = { "history" },
    toggle_view_mode = { "history" },
    refresh = { "history" },
    fold_open = { "history" },
    fold_open_recursive = { "history" },
    fold_close = { "history" },
    fold_close_recursive = { "history" },
    fold_toggle = { "history" },
    fold_toggle_recursive = { "history" },
    fold_open_all = { "history" },
    fold_close_all = { "history" },
  },
  conflict = {
    accept_incoming = { "conflict" },
    accept_current = { "conflict" },
    accept_both = { "conflict" },
    discard = { "conflict" },
    accept_all_incoming = { "conflict" },
    accept_all_current = { "conflict" },
    accept_all_both = { "conflict" },
    discard_all = { "conflict" },
    next_conflict = { "conflict" },
    prev_conflict = { "conflict" },
    diffget_incoming = { "conflict" },
    diffget_current = { "conflict" },
  },
}

local failures = {}
local checked = 0

local function run_audit()
  local function check_shape(shape, tp)
    for scope, entries in pairs(EXPECT) do
      for cfg_key, shapes in pairs(entries) do
        if vim.tbl_contains(shapes, shape) then
          local key = config.options.keymaps[scope][cfg_key]
          if type(key) == "string" then
            checked = checked + 1
            if not reachable(tp, key, NORMAL) then
              table.insert(failures, string.format("%-10s %s.%-22s %-14s NOT REACHABLE", shape, scope, cfg_key, key))
            end
          end
        end
      end
    end
    -- textobject lives in operator-pending / visual
    local ih = config.options.keymaps.view.hunk_textobject
    if type(ih) == "string" then
      checked = checked + 1
      if not reachable(tp, ih, TEXTOBJ) then
        table.insert(failures, string.format("%-10s %-33s %-14s NOT REACHABLE (o/x)", shape, "view.hunk_textobject", ih))
      end
    end
    -- panel double click
    if shape == "explorer" or shape == "history" then
      checked = checked + 1
      if not reachable(tp, "<2-LeftMouse>", NORMAL) then
        table.insert(failures, string.format("%-10s %-33s %-14s NOT REACHABLE", shape, "panel.double_click", "<2-LeftMouse>"))
      end
    end
  end

  local function finish(tp, teardown)
    lifecycle.cleanup_all()
    h.close_extra_tabs()
    if teardown then
      teardown()
    end
  end

  -- standalone (side-by-side / inline / moves)
  for _, spec in ipairs({
    { "standalone", { diff = { layout = "side-by-side" } } },
    { "inline", { diff = { layout = "inline" } } },
    { "moves", { diff = { compute_moves = true } } },
  }) do
    local shape, opts = spec[1], spec[2]
    reset_config(opts)
    local L = temp_file("_x.txt", { "alpha1", "alpha2", "alpha3", "alpha4", "alpha5", "u1", "u2", "u3", "b1", "b2", "b3", "b4", "b5" })
    local R = temp_file("_y.txt", { "u1", "u2", "u3", "b1", "b2", "b3", "b4", "b5", "alpha1", "alpha2", "alpha3", "alpha4", "alpha5" })
    view.create({ original = path.make_ref(L, nil), modified = path.make_ref(R, nil) })
    local tp = vim.api.nvim_get_current_tabpage()
    wait_diff(tp)
    check_shape(shape, tp)
    finish(tp, function()
      vim.fn.delete(L)
      vim.fn.delete(R)
    end)
  end

  -- explorer
  do
    reset_config({})
    local repo = h.create_temp_git_repo()
    repo.write_file("t.txt", { "a", "b", "c" })
    repo.git("add .")
    repo.git("commit -m i")
    repo.write_file("t.txt", { "a", "X", "c" })
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("t.txt")))
    commands.vscode_diff({ fargs = {} })
    local tp
    vim.wait(15000, function()
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        local s = lifecycle.get_session(t)
        if s and (s.panel or {}).view and (s.panel or {}).view.bufnr then
          tp = t
          return true
        end
      end
      return false
    end, 50)
    local ex = (lifecycle.get_session(tp).panel or {}).view
    ex.on_file_select({ path = "t.txt", group = "unstaged", status = "M", git_root = repo.dir })
    wait_diff(tp)
    check_shape("explorer", tp)
    finish(tp, repo.cleanup)
  end

  -- history
  do
    reset_config({})
    local repo = h.create_temp_git_repo()
    repo.write_file("t.txt", { "a" })
    repo.git("add .")
    repo.git("commit -m one")
    repo.write_file("t.txt", { "a", "b" })
    repo.git("commit -am two")
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("t.txt")))
    commands.vscode_diff({ fargs = { "history" } })
    local tp
    vim.wait(15000, function()
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        local s = lifecycle.get_session(t)
        if s and s.panel and s.panel.name == "history" and (s.panel or {}).view and (s.panel or {}).view.bufnr then
          tp = t
          return true
        end
      end
      return false
    end, 50)
    check_shape("history", tp)
    finish(tp, repo.cleanup)
  end

  -- conflict
  do
    reset_config({})
    local repo = h.create_temp_git_repo()
    repo.write_file("c.txt", { "l1", "l2", "l3" })
    repo.git("add -A")
    repo.git("commit -m base")
    repo.git("checkout -b f")
    repo.write_file("c.txt", { "F", "l2", "l3" })
    repo.git("commit -am f")
    repo.git("checkout main")
    repo.write_file("c.txt", { "M", "l2", "l3" })
    repo.git("commit -am m")
    repo.git("merge f --no-edit")
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("c.txt")))
    local ready = false
    view.create(
      {
        git_root = repo.dir,
        original = path.make_ref("c.txt", repo.dir),
        modified = path.make_ref("c.txt", repo.dir),
        original_revision = ":3",
        modified_revision = ":2",
        conflict = true,
      },
      "",
      function()
        ready = true
      end
    )
    vim.wait(15000, function()
      return ready
    end, 50)
    local tp
    for _, t in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(t)
      if s and s.result_bufnr then
        tp = t
        break
      end
    end
    check_shape("conflict", tp)
    finish(tp, repo.cleanup)
  end

  return checked, failures
end

describe("keymap coverage", function()
  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
  end)

  it("makes every configured keymap reachable in every applicable session shape", function()
    local count, missing = run_audit()
    assert.are.same({}, missing, "these configured keymaps are not reachable")
    assert.is_true(count > 100, "audit should exercise the full keymap surface, ran " .. count)
  end)
end)
