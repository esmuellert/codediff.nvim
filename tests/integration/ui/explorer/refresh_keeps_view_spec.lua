-- What a refresh must not disturb: a collapsed group stays collapsed, and the
-- cursor stays on the file it was on.
--
-- The explorer refreshes on every write and every stage, so losing either
-- means the panel reshuffles under the user. Both were uncovered -- stubbing
-- the collapse capture or the cursor capture left the whole suite green.

local h = require("tests.support")
h.ensure_plugin_loaded()

describe("explorer refresh keeps the user's view", function()
  local repo, saved_cwd

  before_each(function()
    require("codediff").setup({})
    saved_cwd = vim.fn.getcwd()
    repo = h.create_temp_git_repo()
    repo.write_file("a.txt", { "a1" })
    repo.write_file("b.txt", { "b1" })
    repo.write_file("c.txt", { "c1" })
    repo.git("add -A")
    repo.git("commit -qm base")
    repo.write_file("a.txt", { "A1 CHANGED" })
    repo.write_file("b.txt", { "B1 CHANGED" })
    repo.write_file("c.txt", { "C1 CHANGED" })
    vim.cmd("cd " .. vim.fn.fnameescape(repo.dir))
  end)

  after_each(function()
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

  local function open()
    local lifecycle = require("codediff.ui.lifecycle")
    lifecycle.cleanup_all()
    vim.cmd("CodeDiff")
    local explorer
    assert.is_true(
      vim.wait(15000, function()
        for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
          local e = lifecycle.get_panel_view(tp)
          if e and e.winid and vim.api.nvim_win_is_valid(e.winid) and e.tree then
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

  --- Nodes of a given type, top level first.
  local function nodes_of_type(explorer, want)
    local out = {}
    for _, node in ipairs(explorer.tree:get_nodes()) do
      if node.data and node.data.type == want then
        out[#out + 1] = node
      end
    end
    return out
  end

  it("leaves a collapsed group collapsed", function()
    local explorer = open()

    local groups = nodes_of_type(explorer, "group")
    assert.is_true(#groups > 0, "explorer should have group nodes")

    local target = groups[1]
    local key = target.data.path or target.data.name
    target:collapse()
    explorer.tree:render()
    vim.wait(300)
    assert.is_false(target:is_expanded(), "the group should start out collapsed")

    -- The refresh skips everything when git status is unchanged, so the tree
    -- would never be rebuilt and the collapse would survive for the wrong
    -- reason. Make a real change first.
    vim.fn.writefile({ "d1 new file" }, repo.dir .. "/d.txt")
    require("codediff.ui.refresh").request(explorer.tabpage, { full = true })
    vim.wait(4000)

    local after
    for _, node in ipairs(explorer.tree:get_nodes()) do
      if node.data and (node.data.path or node.data.name) == key then
        after = node
      end
    end
    assert.is_not_nil(after, "the group should still be there after a refresh")
    assert.is_false(after:is_expanded(), "a refresh must not expand a collapsed group")
  end)

  it("advances to the file that takes its place after staging (#347)", function()
    local explorer = open()

    -- Review a.txt, the first file in the unstaged group.
    explorer.on_file_select({ path = "a.txt", status = "M", group = "unstaged", git_root = repo.dir }, {})
    vim.wait(2000)

    -- Staging it moves it out of that group. Rather than chasing it into the
    -- staged group, the refresh keeps the reviewer where they were: on
    -- whatever file now occupies that slot.
    repo.git("add a.txt")
    require("codediff.ui.refresh").request(explorer.tabpage, { full = true })
    vim.wait(4000)

    assert.equals("b.txt", explorer.data.current_file_path, "should advance to the file taking a.txt's slot")

    local lifecycle = require("codediff.ui.lifecycle")
    local session = lifecycle.get_session(explorer.tabpage)
    local shown = table.concat(vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    h.assert_contains(shown, "B1 CHANGED", "the diff should follow to b.txt")
  end)
end)
