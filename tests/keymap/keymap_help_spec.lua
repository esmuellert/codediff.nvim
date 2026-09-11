-- The g? help popup must describe reality.
--
-- Historically the popup was a hand-maintained list, so it drifted from the
-- mappings actually installed (see #343). These tests pin the contract in both
-- directions: everything shown is really bound, and nothing bound is missing.

local h = dofile("tests/helpers.lua")
local path = require("codediff.core.path")

h.ensure_plugin_loaded()

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local keymap_help = require("codediff.ui.keymap_help")
local commands = require("codediff.commands")

local function reset_config(opts)
  vim.g.mapleader = "\\"
  local config = require("codediff.config")
  config.options = vim.deepcopy(config.defaults)
  require("codediff").setup(opts or {})
  require("codediff.ui.highlights").setup()
end

local function temp_file(suffix, lines)
  local file = vim.fn.tempname() .. suffix
  vim.fn.writefile(lines, file)
  return file
end

local function wait_for_diff(tabpage, timeout_ms)
  return vim.wait(timeout_ms or 10000, function()
    local session = lifecycle.get_session(tabpage)
    return session ~= nil and session.stored_diff_result ~= nil
  end, 50)
end

--- Open the help popup and return its rendered lines, then close it.
--- @param tabpage number
--- @return string[] lines
local function help_lines(tabpage)
  keymap_help.toggle(tabpage)
  local session = lifecycle.get_session(tabpage)
  local win = session and session._help_win
  assert.is_true(win ~= nil and vim.api.nvim_win_is_valid(win), "help window should open")

  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  keymap_help.toggle(tabpage)
  return lines
end

--- Canonicalize a key sequence so help text ("<leader>hs") and registry keys
--- ("\hs") can be compared. Both sides go through the same expansion, which
--- also normalizes "<CR>" against a raw carriage return.
--- @param key string
--- @return string
local function canonical(key)
  local ok, expanded = pcall(vim.api.nvim_replace_termcodes, key, true, true, true)
  if ok and expanded ~= "" then
    return expanded
  end
  return key
end

--- Keys the popup advertises, as a canonical set. The popup renders
--- "<key> → <desc>", possibly two columns per line.
--- @param lines string[]
--- @return table<string, boolean>
local function advertised_keys(lines)
  local keys = {}
  for _, line in ipairs(lines) do
    for key in line:gmatch("(%S+)%s+→") do
      keys[canonical(key)] = true
    end
  end
  return keys
end

--- Keys the session registry expects the popup to document.
--- Already canonical, so these must not be expanded a second time: mouse keys
--- contain raw K_SPECIAL bytes that a second pass would mangle.
--- @param tabpage number
--- @return table<string, boolean>
local function documented_keys(tabpage)
  return lifecycle.documented_keymaps(tabpage)
end

--- Every key currently mapped on any of the session's buffers, in any mode.
--- @param tabpage number
--- @return table<string, boolean>
local function bound_keys(tabpage)
  local session = lifecycle.get_session(tabpage)
  local buffers = {
    session.original_bufnr,
    session.modified_bufnr,
    (session.panel or {}).view and (session.panel or {}).view.bufnr,
    session.result_bufnr,
  }

  local keys = {}
  for _, bufnr in ipairs(buffers) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, mode in ipairs({ "n", "o", "x", "v" }) do
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
          keys[canonical(map.lhs)] = true
          keys[map.lhs] = true
        end
      end
    end
  end
  return keys
end

local function open_standalone(opts)
  reset_config(opts)
  local left = temp_file("_help_left.txt", { "a", "b", "c" })
  local right = temp_file("_help_right.txt", { "a", "X", "c" })

  view.create({
    git_root = nil,
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  assert.is_true(wait_for_diff(tabpage), "standalone session should be ready")

  return tabpage, function()
    vim.fn.delete(left)
    vim.fn.delete(right)
  end
end

local function open_explorer(opts)
  reset_config(opts)
  local repo = h.create_temp_git_repo()
  repo.write_file("t.txt", { "a", "b", "c" })
  repo.git("add .")
  repo.git("commit -m initial")
  repo.write_file("t.txt", { "a", "X", "c" })

  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("t.txt")))
  commands.vscode_diff({ fargs = {} })

  local tabpage
  assert.is_true(vim.wait(15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and (session.panel or {}).view and (session.panel or {}).view.bufnr then
        tabpage = tp
        return true
      end
    end
    return false
  end, 50), "explorer session should be created")

  local explorer = (lifecycle.get_session(tabpage).panel or {}).view
  explorer.on_file_select({ path = "t.txt", group = "unstaged", status = "M", git_root = repo.dir })
  assert.is_true(wait_for_diff(tabpage), "explorer diff should be ready")

  return tabpage, function()
    repo.cleanup()
  end
end

local function open_history()
  reset_config()
  local repo = h.create_temp_git_repo()
  repo.write_file("t.txt", { "a" })
  repo.git("add .")
  repo.git("commit -m one")
  repo.write_file("t.txt", { "a", "b" })
  repo.git("commit -am two")

  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("t.txt")))
  commands.vscode_diff({ fargs = { "history" } })

  local tabpage
  assert.is_true(vim.wait(15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and session.panel and session.panel.name == "history" and (session.panel or {}).view and (session.panel or {}).view.bufnr then
        tabpage = tp
        return true
      end
    end
    return false
  end, 50), "history session should be created")

  return tabpage, function()
    repo.cleanup()
  end
end

local function open_conflict()
  reset_config()
  local repo = h.create_temp_git_repo()
  repo.write_file("conf.txt", { "l1", "l2", "l3" })
  repo.git("add -A")
  repo.git("commit -m base")
  repo.git("checkout -b feature")
  repo.write_file("conf.txt", { "FEATURE", "l2", "l3" })
  repo.git("commit -am feature")
  repo.git("checkout main")
  repo.write_file("conf.txt", { "MAIN", "l2", "l3" })
  repo.git("commit -am main")
  assert.is_truthy(repo.git("merge feature --no-edit"):find("CONFLICT", 1, true), "merge must conflict")

  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("conf.txt")))

  local ready = false
  view.create({
    git_root = repo.dir,
    original = path.make_ref("conf.txt", repo.dir),
    modified = path.make_ref("conf.txt", repo.dir),
    original_revision = ":3",
    modified_revision = ":2",
    conflict = true,
  }, "", function()
    ready = true
  end)
  assert.is_true(vim.wait(15000, function()
    return ready
  end, 50), "conflict view should become ready")

  local tabpage
  for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
    local session = lifecycle.get_session(tp)
    if session and session.result_bufnr then
      tabpage = tp
      break
    end
  end
  assert.is_not_nil(tabpage, "conflict session should exist")

  return tabpage, function()
    repo.cleanup()
  end
end

describe("keymap help popup", function()
  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
  end)

  it("advertises only keys that are actually bound", function()
    local tabpage, cleanup = open_standalone()

    local advertised = advertised_keys(help_lines(tabpage))
    local bound = bound_keys(tabpage)

    assert.is_true(next(advertised) ~= nil, "help should list something")
    for key in pairs(advertised) do
      assert.is_true(bound[key] == true, string.format("help advertises %q but nothing is mapped to it", key))
    end

    cleanup()
  end)

  it("uses NormalFloat for the help window body highlight", function()
    local tabpage, cleanup = open_standalone()

    keymap_help.toggle(tabpage)
    local session = lifecycle.get_session(tabpage)
    local win = session and session._help_win
    assert.is_true(win ~= nil and vim.api.nvim_win_is_valid(win), "help window should open")
    assert.are.same("NormalFloat:NormalFloat", vim.wo[win].winhighlight)
    keymap_help.toggle(tabpage)

    cleanup()
  end)

  it("does not advertise a key disabled in config", function()
    local tabpage, cleanup = open_standalone({ keymaps = { view = { quit = false, toggle_compact = false } } })

    local advertised = advertised_keys(help_lines(tabpage))
    assert.is_nil(advertised[canonical("q")], "quit=false must not appear in help")
    assert.is_nil(advertised[canonical("gc")], "toggle_compact=false must not appear in help")

    cleanup()
  end)

  it("does not advertise gm when move detection is off", function()
    -- compute_moves defaults to false, so align_move is never bound.
    local tabpage, cleanup = open_standalone()

    local advertised = advertised_keys(help_lines(tabpage))
    assert.is_nil(advertised[canonical("gm")], "gm is only bound when diff.compute_moves is enabled")

    cleanup()
  end)

  it("advertises gm when move detection is on", function()
    local tabpage, cleanup = open_standalone({ diff = { compute_moves = true } })

    local advertised = advertised_keys(help_lines(tabpage))
    assert.is_true(advertised[canonical("gm")] == true, "gm should be listed when compute_moves is enabled")

    cleanup()
  end)

  it("does not advertise do/dp in conflict mode", function()
    local tabpage, cleanup = open_conflict()

    local advertised = advertised_keys(help_lines(tabpage))
    assert.is_nil(advertised[canonical("do")], "conflict mode replaces do with 2do/3do")
    assert.is_nil(advertised[canonical("dp")], "conflict mode has no dp")
    assert.is_true(advertised[canonical("2do")] == true, "conflict help should list 2do")
    assert.is_true(advertised[canonical("]x")] == true, "conflict help should list conflict navigation")

    cleanup()
  end)

  it("documents every mapping the session installs, in every session shape", function()
    -- The registry is the source of truth: any mapping claimed with
    -- help ~= false must be discoverable through g?. This covers every buffer
    -- role and every mode, in each shape codediff can produce.
    local shapes = {
      { "standalone side-by-side", function() return open_standalone({ diff = { layout = "side-by-side" } }) end },
      { "standalone inline", function() return open_standalone({ diff = { layout = "inline" } }) end },
      { "standalone + compute_moves", function() return open_standalone({ diff = { compute_moves = true } }) end },
      { "standalone + compact", function()
        local tabpage, cleanup = open_standalone({ diff = { layout = "side-by-side" } })
        require("codediff.ui.view.compact").enable(tabpage)
        return tabpage, cleanup
      end },
      { "explorer", function() return open_explorer({}) end },
      { "explorer + auto_open_on_cursor", function() return open_explorer({ explorer = { auto_open_on_cursor = true } }) end },
      { "history", open_history },
      { "conflict", open_conflict },
    }

    for _, shape in ipairs(shapes) do
      local label, build = shape[1], shape[2]
      local tabpage, cleanup = build()

      local advertised = advertised_keys(help_lines(tabpage))
      local missing = {}
      for key in pairs(documented_keys(tabpage)) do
        if not advertised[key] then
          table.insert(missing, vim.inspect(key))
        end
      end
      table.sort(missing)
      assert.are.same({}, missing, label .. ": these mappings are installed but missing from g?")

      lifecycle.cleanup_all()
      h.close_extra_tabs()
      cleanup()
    end
  end)
end)
