-- Re-selecting the file already on screen must not rebuild the diff: the
-- rebuild repaints, the repaint fires another refresh. That is #317 and #401.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("explorer re-selection", function()
  local repo, saved_cwd, restore_update, updates

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    repo.write_file("a.txt", { "a1", "a2" })
    repo.write_file("b.txt", { "b1", "b2" })
    repo.git("add -A")
    repo.git("commit -qm base")
    repo.write_file("a.txt", { "a1", "A2 CHANGED" })
    repo.write_file("b.txt", { "b1", "B2 CHANGED" })

    local view = require("codediff.ui.view")
    local original = view.update
    updates = 0
    view.update = function(...)
      updates = updates + 1
      return original(...)
    end
    restore_update = function()
      view.update = original
    end
  end)

  after_each(function()
    if restore_update then
      restore_update()
    end
    if saved_cwd and vim.fn.isdirectory(saved_cwd) == 1 then
      pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end
    require("codediff.ui.lifecycle").cleanup_all()
    if repo then
      repo.cleanup()
    end
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
  end)

  local function open_explorer()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
    vim.cmd("CodeDiff")
    local explorer
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local e = lifecycle.get_panel_view(tp)
          if e and e.winid and vim.api.nvim_win_is_valid(e.winid) then
            explorer = e
            return true
          end
        end
        return false
      end, 50),
      "explorer should open"
    )
    vim.wait(2000)
    return explorer
  end

  local function select(explorer, file)
    explorer.on_file_select({ path = file, status = "M", group = "unstaged", git_root = repo.dir }, {})
    vim.wait(250)
  end

  it("does not rebuild the diff for the file already shown", function()
    local explorer = open_explorer()

    local before = updates
    for _ = 1, 10 do
      select(explorer, "a.txt")
    end
    vim.wait(1000)

    assert.equals(before, updates, "re-selecting the same file must not rebuild the diff")
  end)

  it("still rebuilds when the file changes", function()
    local explorer = open_explorer()

    select(explorer, "a.txt")
    vim.wait(1500)
    local before = updates

    select(explorer, "b.txt")
    vim.wait(1500)

    assert.is_true(updates > before, "selecting a different file must rebuild the diff")
  end)

  it("rebuilds when the same file moves between staged and unstaged", function()
    -- The two views compare against different things -- :0 for staged, HEAD
    -- for unstaged -- so the same path is not the same diff.
    local explorer = open_explorer()

    select(explorer, "a.txt")
    vim.wait(1500)
    local before = updates

    repo.git("add a.txt")
    explorer.on_file_select({ path = "a.txt", status = "M", group = "staged", git_root = repo.dir }, {})
    vim.wait(1500)

    assert.is_true(updates > before, "moving to the staged view must rebuild the diff")
  end)

  it("rebuilds an unstaged view once the file gains staged content", function()
    -- Staging moves the comparison base from HEAD to :0, so the diff changes
    -- even though file, group and type do not. Staged on the explorer's own
    -- status: a real `git add` wakes the watcher, which rebuilds by itself.
    local explorer = open_explorer()

    select(explorer, "a.txt")
    vim.wait(1500)
    local before = updates

    explorer.data.status_result = {
      staged = { { path = "a.txt" } },
      unstaged = { { path = "a.txt" } },
      conflicts = {},
    }
    select(explorer, "a.txt")
    vim.wait(1500)

    assert.is_true(updates > before, "staging moves the comparison base, so the diff must rebuild")
  end)

  it("rebuilds when asked to force", function()
    local explorer = open_explorer()

    select(explorer, "a.txt")
    vim.wait(1500)
    local before = updates

    explorer.on_file_select({ path = "a.txt", status = "M", group = "unstaged", git_root = repo.dir }, { force = true })
    vim.wait(1500)

    assert.is_true(updates > before, "force must rebuild even for the same file")
  end)
end)
