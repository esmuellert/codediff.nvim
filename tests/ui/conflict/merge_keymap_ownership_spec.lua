-- Which keys a merge view claims, and which it deliberately leaves alone.
--
-- In a 3-way merge codediff does NOT bind do/dp. The conflict mappings
-- (2do/3do, ]x, <leader>c*) replace them, and not claiming do/dp hands those
-- keys back to whatever the user had mapped for the duration of the merge,
-- rather than deleting the user's mapping.
--
-- That behaviour is load-bearing and had no coverage. It is also easy to break
-- from a distance: setup_all_keymaps decides via `is_conflict`, and any change
-- to how a session reports "I am a merge view" lands here first.

local h = dofile("tests/helpers.lua")
local path = require("codediff.core.path")

--- What `key` actually resolves to in `bufnr`, and whether it is buffer-local.
local function effective(bufnr, key)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "<invalid buffer>"
  end
  local m = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  if type(m) ~= "table" or next(m) == nil then
    return "NONE"
  end
  return (m.desc or "<set>") .. (m.buffer == 1 and " [buf]" or " [global]")
end

describe("merge view keymap ownership", function()
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    pcall(vim.keymap.del, "n", "do")
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  --- Leave the repo mid-merge with a conflicted file.txt, then open the
  --- 3-way view the way :CodeDiff merge does.
  local function open_merge_view()
    repo.write_file("file.txt", { "line 1", "line 2", "line 3", "line 4" })
    repo.git("add file.txt")
    repo.git("commit -m c0")

    repo.git("checkout -b feature")
    repo.write_file("file.txt", { "line 1", "line 2", "line 3 (feature)", "line 4" })
    repo.git("commit -am feature")

    repo.git("checkout main")
    repo.write_file("file.txt", { "line 1", "line 2", "line 3 (main)", "line 4" })
    repo.git("commit -am main")

    local merge_out = repo.git("merge feature --no-edit")
    assert.is_true(merge_out:find("CONFLICT", 1, true) ~= nil, "merge must conflict")

    vim.cmd("edit " .. repo.dir .. "/file.txt")
    require("codediff.ui.view").create({
      git_root = repo.dir,
      original = path.make_ref("file.txt", repo.dir),
      modified = path.make_ref("file.txt", repo.dir),
      original_revision = ":2",
      modified_revision = ":3",
      conflict = true,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local lifecycle = require("codediff.ui.lifecycle")
    local ready = vim.wait(10000, function()
      local s = lifecycle.get_session(tabpage)
      return s ~= nil and s.result_bufnr ~= nil
    end, 50)
    assert.is_true(ready, "merge view never produced a result pane")
    vim.wait(500)
    return lifecycle.get_session(tabpage)
  end

  it("leaves do and dp to the user instead of claiming them", function()
    -- A mapping the user already had. codediff must not delete or shadow it.
    vim.keymap.set("n", "do", function() end, { desc = "USER MAPPING" })

    local session = open_merge_view()

    assert.equals("USER MAPPING [global]", effective(session.original_bufnr, "do"), "merge view must hand `do` back to the user's mapping")
    assert.equals("NONE", effective(session.original_bufnr, "dp"), "merge view must not claim `dp`")
  end)

  it("still installs the conflict mappings that replace them", function()
    local session = open_merge_view()

    -- ]x is the marker for "conflict keymaps are installed"; if this fails the
    -- do/dp assertions above are meaningless (nothing was bound at all).
    assert.equals("Next conflict [buf]", effective(session.original_bufnr, "]x"), "conflict navigation must be bound on the diff panes")
  end)

  it("undoes result changes with `u` from non-result conflict panes", function()
    local session = open_merge_view()
    local tabpage = vim.api.nvim_get_current_tabpage()
    local conflict = require("codediff.ui.conflict")

    local before = vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)

    vim.api.nvim_set_current_buf(session.original_bufnr)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    assert.is_true(conflict.accept_incoming(tabpage), "accept action should modify the result buffer")

    local after_accept = vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)
    assert.not_same(before, after_accept, "accept action should change result content")

    vim.api.nvim_feedkeys("u", "x", false)

    local after_undo = vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)
    assert.are.same(before, after_undo, "`u` from a non-result pane should undo result buffer changes")
  end)

  it("claims do and dp again in an ordinary diff", function()
    -- The counterpart: outside a merge, do/dp are codediff's. Without this a
    -- change that simply never binds them would pass the assertions above.
    local left = h.get_temp_path("merge_kmap_left.txt")
    local right = h.get_temp_path("merge_kmap_right.txt")
    vim.fn.writefile({ "a", "b" }, left)
    vim.fn.writefile({ "a", "B" }, right)

    require("codediff.ui.view").create({
      original = path.make_ref(left, nil),
      modified = path.make_ref(right, nil),
    })

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    assert.is_true(
      vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s ~= nil and s.stored_diff_result ~= nil
      end, 50),
      "plain diff never became ready"
    )

    local session = lifecycle.get_session(tabpage)
    assert.equals("Get change from other buffer [buf]", effective(session.original_bufnr, "do"), "a plain diff must claim `do`")

    vim.fn.delete(left)
    vim.fn.delete(right)
  end)

  it("stops treating the session as a merge after switching to a normal file", function()
    -- view.update can retarget a session from a conflicted file to an ordinary
    -- one. The merge flag has to follow, or do/dp stay unclaimed forever.
    repo.write_file("plain.txt", { "p1", "p2" })
    repo.git("add plain.txt")
    repo.git("commit -m plain")

    local session = open_merge_view()
    local tabpage = vim.api.nvim_get_current_tabpage()
    assert.is_true(session.merge, "merge view should be flagged as a merge")

    -- Retarget the same tab at an ordinary file, the way selecting another
    -- entry in the explorer does.
    require("codediff.ui.view").update(tabpage, {
      git_root = repo.dir,
      original = path.make_ref("plain.txt", repo.dir),
      modified = path.make_ref("plain.txt", repo.dir),
      original_revision = "HEAD",
    }, false)

    local lifecycle = require("codediff.ui.lifecycle")
    assert.is_true(
      vim.wait(10000, function()
        local s = lifecycle.get_session(tabpage)
        return s ~= nil and s.stored_diff_result ~= nil
      end, 50),
      "retargeted diff never became ready"
    )

    local after = lifecycle.get_session(tabpage)
    assert.is_nil(after.merge, "merge flag must clear when leaving the conflicted file")
    assert.equals("Get change from other buffer [buf]", effective(after.original_bufnr, "do"), "`do` must be claimed again once the session is no longer a merge")
  end)
end)
