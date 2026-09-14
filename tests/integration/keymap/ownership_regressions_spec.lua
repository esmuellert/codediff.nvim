-- Regression tests for the keymap-ownership issues this refactor closes.
--
-- Each check follows the reproduction steps from the GitHub issue as written,
-- so a future change that reopens one of them fails here by name:
--
--   #289 / #334  gitsigns [c and ]c stop working after closing CodeDiff
--   #211 / #224  keymaps not restored after navigating files then quitting
--   #394         lifecycle teardown hygiene (ih in o/x, conflict keys, gf escape)
--
-- The remaining checks are guard rails for issues fixed earlier, so this
-- refactor cannot silently reopen them.
local h = require("tests.support")
h.ensure_plugin_loaded()

local path = require("codediff.core.path")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local commands = require("codediff.commands")
local config = require("codediff.config")

local results = {}
local function record(issue, name, ok, detail)
  table.insert(results, { issue = issue, name = name, ok = ok, detail = detail or "" })
end

local function reset(opts)
  vim.g.mapleader = "\\"
  config.options = vim.deepcopy(config.defaults)
  require("codediff").setup(opts or {})
  require("codediff.ui.highlights").setup()
end

local function wait_diff(tp)
  return vim.wait(10000, function()
    local s = lifecycle.get_session(tp)
    return s and s.stored_diff_result ~= nil
  end, 50)
end

--- Resolve a key as the user would experience it in `bufnr`: buffer-local
--- first, then global. Returns desc plus whether it is buffer-local.
local function effective(bufnr, key, mode)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "<invalid>", false
  end
  local m = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(key, mode or "n", false, true)
  end)
  if type(m) ~= "table" or next(m) == nil then
    return "NONE", false
  end
  return m.desc or "<set>", m.buffer == 1
end

local function temp_pair(a, b)
  local L = vim.fn.tempname() .. "_l.txt"
  local R = vim.fn.tempname() .. "_r.txt"
  vim.fn.writefile(a, L)
  vim.fn.writefile(b, R)
  return L, R
end

local function open_standalone(premap)
  local L, R = temp_pair({ "a", "b", "c", "d" }, { "a", "X", "c", "Y" })
  local rb = vim.fn.bufadd(R)
  vim.fn.bufload(rb)
  if premap then
    premap(rb)
  end
  view.create({ original = path.make_ref(L, nil), modified = path.make_ref(R, nil) })
  local tp = vim.api.nvim_get_current_tabpage()
  wait_diff(tp)
  return tp, rb, function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
    vim.fn.delete(L)
    vim.fn.delete(R)
  end
end

local function open_explorer(opts)
  reset(opts)
  local repo = h.create_temp_git_repo()
  repo.write_file("one.txt", { "a", "b", "c" })
  repo.write_file("two.txt", { "p", "q", "r" })
  repo.git("add .")
  repo.git("commit -m init")
  repo.write_file("one.txt", { "a", "X", "c" })
  repo.write_file("two.txt", { "p", "Y", "r" })
  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("one.txt")))
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
  return tp, repo
end

-- ===========================================================================
-- #289 / #334: gitsigns [c and ]c stop working after closing CodeDiff.
-- The reported configs use gitsigns' on_attach map helper, which may produce a
-- global or a buffer-local mapping. Both paths must end up working again.
-- ===========================================================================
reset({ keymaps = { view = { next_hunk = "]c", prev_hunk = "[c" } } })
do
  -- (a) global gitsigns mappings
  vim.keymap.set("n", "]c", function() end, { desc = "GITSIGNS-GLOBAL-NEXT" })
  vim.keymap.set("n", "[c", function() end, { desc = "GITSIGNS-GLOBAL-PREV" })
  local tp, rb, done = open_standalone()
  local during = effective(rb, "]c")
  lifecycle.close(tp)
  vim.wait(200)
  local after_next = effective(rb, "]c")
  local after_prev = effective(rb, "[c")
  record("#289/#334", "global gitsigns ]c works again after close", after_next == "GITSIGNS-GLOBAL-NEXT", "during=" .. during .. " after=" .. after_next)
  record("#289/#334", "global gitsigns [c works again after close", after_prev == "GITSIGNS-GLOBAL-PREV", after_prev)
  done()
  pcall(vim.keymap.del, "n", "]c")
  pcall(vim.keymap.del, "n", "[c")
end

reset({ keymaps = { view = { next_hunk = "]c", prev_hunk = "[c" } } })
do
  -- (b) buffer-local gitsigns mappings (gitsigns' documented on_attach form)
  local tp, rb, done = open_standalone(function(b)
    vim.keymap.set("n", "]c", function() end, { buffer = b, desc = "GITSIGNS-LOCAL-NEXT" })
    vim.keymap.set("n", "[c", function() end, { buffer = b, desc = "GITSIGNS-LOCAL-PREV" })
  end)
  lifecycle.close(tp)
  vim.wait(200)
  record("#289/#334", "buffer-local gitsigns ]c restored after close", effective(rb, "]c") == "GITSIGNS-LOCAL-NEXT", effective(rb, "]c"))
  record("#289/#334", "buffer-local gitsigns [c restored after close", effective(rb, "[c") == "GITSIGNS-LOCAL-PREV", effective(rb, "[c"))
  done()
end

-- ===========================================================================
-- #211 / #224: custom keymaps not restored after pressing next-file then q.
-- The issue stresses that step 2 (navigating files) matters, because that is
-- what swaps buffers underneath the session.
-- ===========================================================================
do
  local tp, repo = open_explorer({
    keymaps = { view = { next_hunk = "]h", prev_hunk = "[h", next_file = "J", prev_file = "K" }, explorer = { hover = "gk" } },
  })
  local ex = (lifecycle.get_session(tp).panel or {}).view

  ex.on_file_select({ path = "one.txt", group = "unstaged", status = "M", git_root = repo.dir })
  wait_diff(tp)
  local first = lifecycle.get_session(tp).modified_bufnr

  -- Step 2: navigate to the next file, as the issue insists.
  ex.on_file_select({ path = "two.txt", group = "unstaged", status = "M", git_root = repo.dir })
  vim.wait(10000, function()
    local s = lifecycle.get_session(tp)
    return s and s.modified_bufnr ~= first and s.stored_diff_result ~= nil
  end, 50)
  local second = lifecycle.get_session(tp).modified_bufnr

  -- Step 3: quit.
  lifecycle.close(tp)
  vim.wait(300)

  local leaked = {}
  for _, key in ipairs({ "]h", "[h", "J", "K" }) do
    for _, b in ipairs({ first, second }) do
      if vim.api.nvim_buf_is_valid(b) then
        local d, is_local = effective(b, key)
        if is_local then
          table.insert(leaked, key .. "@" .. b .. "=" .. d)
        end
      end
    end
  end
  record("#211/#224", "no codediff mappings survive after next-file then quit", #leaked == 0, table.concat(leaked, " "))
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

-- ===========================================================================
-- #394: lifecycle teardown hygiene. Two symptoms it calls out specifically:
-- ih leaks because cleanup hard-codes normal mode, and conflict keys are never
-- deleted at all. Plus the gf escape, which it calls the most insidious case.
-- ===========================================================================
reset()
do
  local tp, rb, done = open_standalone()
  lifecycle.close(tp)
  vim.wait(200)
  local o = select(2, effective(rb, "ih", "o"))
  local x = select(2, effective(rb, "ih", "x"))
  record("#394", "ih released from operator-pending and visual", not o and not x, string.format("o_local=%s x_local=%s", o, x))
  done()
end

reset()
do
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
  local cb = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "do", "<Cmd>echo 1<CR>", { buffer = cb, desc = "USER-DO" })
  local ready = false
  view.create({
    git_root = repo.dir,
    original = path.make_ref("c.txt", repo.dir),
    modified = path.make_ref("c.txt", repo.dir),
    original_revision = ":3",
    modified_revision = ":2",
    conflict = true,
  }, "", function()
    ready = true
  end)
  vim.wait(15000, function()
    return ready
  end, 50)
  record("#394", "conflict mode does not destroy the user's do", effective(cb, "do") == "USER-DO", effective(cb, "do"))

  local tp
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    local s = lifecycle.get_session(t)
    if s and s.result_bufnr then
      tp = t
      break
    end
  end
  if tp then
    local s = lifecycle.get_session(tp)
    local rbuf, obuf = s.result_bufnr, s.original_bufnr
    -- The merge result buffer holds unsaved auto-merged content, so close()
    -- prompts. Headless confirm() answers "cancel", which would leave the
    -- session open and make this check meaningless. Answer "discard".
    local real_confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    local closed = lifecycle.close(tp)
    vim.fn.confirm = real_confirm
    vim.wait(300)
    record("#394", "conflict session actually closes when confirmed", closed and lifecycle.get_session(tp) == nil, "closed=" .. tostring(closed))
    local left = {}
    for _, key in ipairs({ "]x", "[x", "2do", "3do", "\\ct", "\\co" }) do
      for _, b in ipairs({ rbuf, obuf }) do
        if b and vim.api.nvim_buf_is_valid(b) and select(2, effective(b, key)) then
          table.insert(left, key)
        end
      end
    end
    record("#394", "conflict mappings removed on close", #left == 0, table.concat(left, " "))
  end
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

do
  -- gf escape: the buffer moves to another tab while the session stays alive.
  local tp, repo = open_explorer({})
  local ex = (lifecycle.get_session(tp).panel or {}).view
  ex.on_file_select({ path = "one.txt", group = "unstaged", status = "M", git_root = repo.dir })
  wait_diff(tp)
  local s = lifecycle.get_session(tp)
  local mod = s.modified_bufnr
  vim.api.nvim_set_current_win(vim.fn.bufwinid(mod))
  local cb = vim.api.nvim_buf_call(mod, function()
    local m = vim.fn.maparg("gf", "n", false, true)
    return m and m.callback
  end)
  if cb then
    pcall(cb)
  end
  vim.wait(500)
  local alive = lifecycle.get_session(tp) ~= nil
  local still_mapped = select(2, effective(mod, "q"))
  record("#394", "gf escape leaves the file clean while session lives", alive and not still_mapped, "session_alive=" .. tostring(alive) .. " q_local=" .. tostring(still_mapped))
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

-- ===========================================================================
-- Guard rails: previously-fixed issues that must not regress.
-- ===========================================================================
reset()
do
  -- #428: ordinary close must never exit Neovim, even as the last codediff tab
  local tp, _, done = open_standalone()
  vim.cmd("tabonly!")
  local qall = false
  local realcmd = vim.cmd
  vim.cmd = function(c)
    if c == "qall" then
      qall = true
      return
    end
    return realcmd(c)
  end
  lifecycle.close(tp)
  vim.cmd = realcmd
  record("#428", "close does not qall without --exit-on-close", not qall, "qall=" .. tostring(qall))
  done()
end

reset()
do
  -- #412 / #415: cross-file hunk navigation must stay off by default
  record("#412", "cycle_hunks_across_files defaults to false", config.options.diff.cycle_hunks_across_files == false, tostring(config.options.diff.cycle_hunks_across_files))
  record("#276", "close_on_open_in_prev_tab defaults to false", config.options.keymaps.view.close_on_open_in_prev_tab == false, tostring(config.options.keymaps.view.close_on_open_in_prev_tab))
end

do
  -- #202: hunk navigation must be reachable from the explorer panel
  local tp, repo = open_explorer({})
  local s = lifecycle.get_session(tp)
  local panel = (s.panel or {}).view.bufnr
  record("#202", "hunk navigation reachable from the explorer panel", select(2, effective(panel, "]c")), effective(panel, "]c"))
  -- #322 / #67: gf reachable from the explorer panel
  record("#322", "gf reachable from the explorer panel", select(2, effective(panel, "gf")), effective(panel, "gf"))
  -- #207: codediff mappings keep nowait
  local m = vim.api.nvim_buf_call(panel, function()
    return vim.fn.maparg("q", "n", false, true)
  end)
  record("#207", "codediff mappings are nowait", m and m.nowait == 1, "nowait=" .. tostring(m and m.nowait))
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

do
  -- #357: remapping an action onto another action's default must not lose.
  -- The user asks for toggle_explorer on <leader>e, which ships as the default
  -- for focus_explorer. The key the user chose wins; the displaced default is
  -- dropped rather than left to bind second and silently take the key.
  --
  -- The config is the reporter's, verbatim -- including `explorer.toggle_explorer`,
  -- which is not a real option. A key that binds nothing must not sway the
  -- outcome, in either direction.
  local tp, repo = open_explorer({
    keymaps = {
      view = { toggle_explorer = "<leader>e" },
      explorer = { toggle_explorer = "<leader>e" },
    },
  })
  local s = lifecycle.get_session(tp)
  local panel = (s.panel or {}).view.bufnr
  local resolve = require("codediff.keymap.resolve")
  local leader_e = vim.api.nvim_replace_termcodes("<leader>e", true, true, true)
  local leader_b = vim.api.nvim_replace_termcodes("<leader>b", true, true, true)

  record(
    "#357",
    "the user's key runs the action they asked for",
    effective(panel, leader_e) == "Toggle explorer visibility",
    effective(panel, leader_e)
  )
  record("#357", "the displaced default is not bound", effective(panel, leader_b) == "NONE", effective(panel, leader_b))
  record(
    "#357",
    "g? no longer advertises the action that lost the key",
    resolve.keymaps_for("view").focus_explorer == false,
    tostring(resolve.keymaps_for("view").focus_explorer)
  )
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

do
  -- #357, across scopes: view mappings fan out to every session buffer, so a
  -- chosen view key really does collide with an explorer default on the panel.
  local tp, repo = open_explorer({ keymaps = { view = { quit = "R" } } })
  local s = lifecycle.get_session(tp)
  local panel = (s.panel or {}).view.bufnr
  record("#357", "a chosen view key beats an explorer default on the panel", effective(panel, "R") == "Close codediff tab", effective(panel, "R"))
  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

do
  -- #357: a config key that binds nothing -- a typo, or an option from an
  -- older version -- must never take a key away from a real action.
  reset({ keymaps = { explorer = { refres = "R" } } })
  local resolve = require("codediff.keymap.resolve")
  record("#357", "a typo'd config key does not disable a real default", vim.deep_equal(resolve.keymaps_for("explorer").refresh, { "R" }), vim.inspect(resolve.keymaps_for("explorer").refresh))

  -- ...while a deprecated spelling the code still honours does take part.
  reset({ keymaps = { explorer = { toggle_stage = "q" } } })
  record("#357", "a deprecated but honoured key still wins its slot", resolve.keymaps_for("view").quit == false, tostring(resolve.keymaps_for("view").quit))
  reset({})
end

do
  -- #407: an action can answer to more than one key. A list used to bind
  -- nothing at all -- not even the first key -- leaving no way to quit.
  local tp, repo = open_explorer({ keymaps = { view = { quit = { "q", "<Esc>" } } } })
  local s = lifecycle.get_session(tp)
  local first = s.modified_bufnr

  record("#407", "the first key of a list is bound", effective(first, "q") == "Close codediff tab", effective(first, "q"))
  record("#407", "the second key of a list is bound", effective(first, "<Esc>") == "Close codediff tab", effective(first, "<Esc>"))
  record("#407", "both keys reach the explorer panel", effective((s.panel or {}).view.bufnr, "<Esc>") == "Close codediff tab", effective((s.panel or {}).view.bufnr, "<Esc>"))

  -- Switching files rebuilds the diff buffers. Codediff re-applies its own
  -- mappings, which is exactly what a hand-rolled second key cannot do.
  vim.api.nvim_set_current_tabpage(tp)
  local win = vim.fn.bufwinid(first)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("]f", true, false, true), "mx", false)
  vim.wait(3000)

  s = lifecycle.get_session(tp)
  local second = s and s.modified_bufnr
  record("#407", "a file switch really does rebuild the buffer", second ~= first, tostring(second) .. " vs " .. tostring(first))
  record("#407", "both keys survive a file switch", effective(second, "q") == "Close codediff tab" and effective(second, "<Esc>") == "Close codediff tab", effective(second, "<Esc>"))

  repo.cleanup()
  lifecycle.cleanup_all()
  h.close_extra_tabs()
end

do
  -- #407: config values are read and validated in one place, so what reaches
  -- the registry is always a list of keys, and an invalid value is reported
  -- rather than silently dropped.
  local resolve = require("codediff.keymap.resolve")

  reset({})
  record("#407", "a single key reads back as a one-item list", vim.deep_equal(resolve.keymaps_for("view").quit, { "q" }), vim.inspect(resolve.keymaps_for("view").quit))
  record("#407", "a setting among the keymaps is left alone", resolve.keymaps_for("view").close_on_open_in_prev_tab == false, tostring(resolve.keymaps_for("view").close_on_open_in_prev_tab))

  reset({ keymaps = { view = { quit = { "q", "q", "<Esc>" } } } })
  record("#407", "duplicate keys collapse", vim.deep_equal(resolve.keymaps_for("view").quit, { "q", "<Esc>" }), vim.inspect(resolve.keymaps_for("view").quit))

  reset({ keymaps = { view = { quit = {} } } })
  record("#407", "an empty list means not bound", resolve.keymaps_for("view").quit == false, tostring(resolve.keymaps_for("view").quit))

  local warned = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    table.insert(warned, msg)
  end
  reset({ keymaps = { view = { quit = 42 } } })
  resolve.forget_warnings()
  resolve.keymaps_for("view")
  vim.wait(200, function()
    return #warned > 0
  end)
  vim.notify = real_notify
  record("#407", "an invalid value is reported by config path", #warned > 0 and warned[1]:match("keymaps%.view%.quit") ~= nil, warned[1] or "no warning")

  reset({})
end

describe("keymap issue regressions", function()
  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
  end)

  it("keeps every reported keymap issue fixed", function()
    local failures = {}
    for _, r in ipairs(results) do
      if not r.ok then
        table.insert(failures, string.format("%s %s (%s)", r.issue, r.name, r.detail))
      end
    end
    assert.are.same({}, failures, "these reported issues are no longer fixed")
    assert.is_true(#results >= 15, "expected the full issue matrix, ran " .. #results)
  end)
end)
