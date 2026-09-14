-- Golden keymap matrix: locks which mappings land on which session buffers.
--
-- This is the safety net for the keymap registry refactor. It captures the
-- role x mode x lhs x desc matrix for every session shape and compares it
-- against a committed fixture. A refactor that preserves behavior produces an
-- identical fixture; an intended change produces a small, reviewable diff.
--
-- Regenerate after an intentional change:
--   CODEDIFF_WRITE_KEYMAP_GOLDEN=1 ./tests/run_tests.sh tests/integration/keymap/golden_matrix_spec.lua

local h = require("tests.support")
local matrix = require("tests.support.keymaps")
local path = require("codediff.core.path")

h.ensure_plugin_loaded()

-- Load every module the scenarios need up front. Scenario setup runs git in
-- temp directories, and resolving modules lazily from there is fragile.
local commands = require("codediff.commands")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local compact = require("codediff.ui.view.compact")

local FIXTURE = h.project_root .. "/tests/fixtures/keymap_matrix.txt"
local WRITE_MODE = vim.env.CODEDIFF_WRITE_KEYMAP_GOLDEN == "1"

-- Mappings capture <leader> at creation time, so the fixture would otherwise
-- depend on whoever ran it. Pin the leader for every scenario.
local LEADER = "\\"

-- config.setup() merges into the *current* options, so it accumulates across
-- calls. Reset to defaults first so every scenario starts from a known state.
local function reset_config(opts)
  vim.g.mapleader = LEADER
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

local ORIGINAL_LINES = { "line 1", "line 2", "line 3", "line 4", "line 5" }
local MODIFIED_LINES = { "line 1", "CHANGED 2", "line 3", "line 4", "CHANGED 5" }

--- Wait until a session on `tabpage` has a computed diff.
local function wait_for_diff(tabpage, timeout_ms)
  return vim.wait(timeout_ms or 10000, function()
    local session = lifecycle.get_session(tabpage)
    return session ~= nil and session.stored_diff_result ~= nil
  end, 50)
end

-- ---------------------------------------------------------------------------
-- Scenario builders. Each returns the tabpage holding the session plus a
-- teardown function.
-- ---------------------------------------------------------------------------

local function scenario_standalone(layout)
  reset_config({ diff = { layout = layout } })

  local left = temp_file("_golden_left.txt", ORIGINAL_LINES)
  local right = temp_file("_golden_right.txt", MODIFIED_LINES)

  view.create({
    git_root = nil,
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
    original_revision = nil,
    modified_revision = nil,
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  assert.is_true(wait_for_diff(tabpage), "standalone " .. layout .. " session should be ready")

  return tabpage, function()
    vim.fn.delete(left)
    vim.fn.delete(right)
  end
end

local function scenario_explorer(layout)
  reset_config({ diff = { layout = layout } })

  local repo = h.create_temp_git_repo()
  repo.write_file("test.txt", ORIGINAL_LINES)
  repo.git("add .")
  repo.git("commit -m initial")
  repo.write_file("test.txt", MODIFIED_LINES)

  vim.cmd("edit " .. vim.fn.fnameescape(repo.path("test.txt")))
  commands.vscode_diff({ fargs = {} })

  local tabpage
  local ready = vim.wait(15000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local session = lifecycle.get_session(tp)
      if session and (session.panel or {}).view and (session.panel or {}).view.bufnr then
        tabpage = tp
        return true
      end
    end
    return false
  end, 50)
  assert.is_true(ready, "explorer session should be created")

  -- Select the changed file so the diff panes hold real buffers.
  local explorer = (lifecycle.get_session(tabpage).panel or {}).view
  explorer.on_file_select({ path = "test.txt", group = "unstaged", status = "M", git_root = repo.dir })
  assert.is_true(wait_for_diff(tabpage), "explorer diff should be ready")

  return tabpage, function()
    repo.cleanup()
  end
end

local function scenario_conflict()
  reset_config({ diff = { layout = "side-by-side" } })

  local repo = h.create_temp_git_repo()
  repo.write_file("conf.txt", ORIGINAL_LINES)
  repo.git("add -A")
  repo.git("commit -m base")
  repo.git("checkout -b feature")
  repo.write_file("conf.txt", { "FEATURE", "line 2", "line 3", "line 4", "line 5" })
  repo.git("commit -am feature")
  repo.git("checkout main")
  repo.write_file("conf.txt", { "MAIN", "line 2", "line 3", "line 4", "line 5" })
  repo.git("commit -am main")
  local merge_out = repo.git("merge feature --no-edit")
  assert.is_true(merge_out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")

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

local function scenario_compact()
  reset_config({ diff = { layout = "side-by-side" } })

  local left = temp_file("_golden_compact_left.txt", ORIGINAL_LINES)
  local right = temp_file("_golden_compact_right.txt", MODIFIED_LINES)

  view.create({
    git_root = nil,
    original = path.make_ref(left, nil),
    modified = path.make_ref(right, nil),
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  assert.is_true(wait_for_diff(tabpage), "compact base session should be ready")
  assert.is_true(compact.enable(tabpage), "compact mode should enable")

  return tabpage, function()
    vim.fn.delete(left)
    vim.fn.delete(right)
  end
end

-- ---------------------------------------------------------------------------

describe("keymap golden matrix", function()
  after_each(function()
    lifecycle.cleanup_all()
    h.close_extra_tabs()
  end)

  it("matches the committed fixture for every session shape", function()
    local scenarios = {
      { "standalone side-by-side", function() return scenario_standalone("side-by-side") end },
      { "standalone inline", function() return scenario_standalone("inline") end },
      { "explorer side-by-side", function() return scenario_explorer("side-by-side") end },
      { "explorer inline", function() return scenario_explorer("inline") end },
      { "conflict", scenario_conflict },
      { "compact side-by-side", scenario_compact },
    }

    local lines = {
      "# codediff keymap golden matrix",
      "# role x mode x lhs x desc for each session shape.",
      "# Regenerate with CODEDIFF_WRITE_KEYMAP_GOLDEN=1 after an intended change.",
    }

    for _, scenario in ipairs(scenarios) do
      local label, build = scenario[1], scenario[2]
      local tabpage, teardown = build()

      table.insert(lines, "")
      vim.list_extend(lines, matrix.snapshot(label, tabpage))

      lifecycle.cleanup_all()
      h.close_extra_tabs()
      teardown()
    end

    local rendered = lines

    if WRITE_MODE then
      vim.fn.mkdir(vim.fn.fnamemodify(FIXTURE, ":h"), "p")
      vim.fn.writefile(rendered, FIXTURE)
      print("wrote golden fixture: " .. FIXTURE)
      return
    end

    assert.is_true(vim.fn.filereadable(FIXTURE) == 1, "missing fixture " .. FIXTURE .. "; regenerate with CODEDIFF_WRITE_KEYMAP_GOLDEN=1")

    local expected = vim.fn.readfile(FIXTURE)
    for i = 1, math.max(#expected, #rendered) do
      if expected[i] ~= rendered[i] then
        assert.is_true(
          false,
          string.format(
            "keymap matrix drifted from %s\nfirst difference at line %d:\n  expected: %s\n  actual:   %s",
            FIXTURE,
            i,
            expected[i] or "<eof>",
            rendered[i] or "<eof>"
          )
        )
      end
    end
    assert.equals(#expected, #rendered, "keymap matrix line count drifted from " .. FIXTURE)
  end)
end)
