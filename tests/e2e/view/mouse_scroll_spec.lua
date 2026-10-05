local h = require("tests.support.e2e")

-- Neovim syncs 'scrollbind' only from the current window, while the mouse
-- wheel scrolls the window under the pointer. CodeDiff replays the sync so a
-- pane scrolled without focus still moves its peers.
describe("mouse wheel scrolling E2E", function()
  local repo, screen
  before_each(function()
    repo = h.repo()
    local lines = {}
    for i = 1, 120 do
      lines[i] = string.format("line-%03d", i)
    end
    repo.write_file("long.txt", lines)
    repo.commit("add long file")
    repo.replace("long.txt", 3, "working-003")
    screen = h.screen("polling", "side-by-side")
    h.open(screen, repo, "CodeDiff -- long.txt", "long.txt", "long.txt")
  end)
  after_each(function()
    h.close(screen, repo)
    screen, repo = nil, nil
  end)

  local function focus(target)
    screen:exec(
      [[
      local s, target = refresh_session(), ...
      local win = target == "panel" and s.panel.view.winid or s[target .. "_win"]
      vim.api.nvim_set_current_win(win)
    ]],
      { target }
    )
  end

  local function wheel(side, count)
    local p = screen:exec(
      [[
      local pos = vim.api.nvim_win_get_position(refresh_session()[(...) .. "_win"])
      return { pos[1] + 2, pos[2] + 2 }
    ]],
      { side }
    )
    for _ = 1, count do
      screen:request("nvim_input_mouse", { "wheel", "down", "", 0, p[1], p[2] })
    end
    h.idle(screen)
  end

  local function toplines()
    local panes = h.panes(screen)
    return { panes.original.view[1], panes.modified.view[1] }
  end

  local function expect_toplines(expected)
    screen:await(function()
      return vim.deep_equal(toplines(), expected)
    end, "expected toplines " .. vim.inspect(expected) .. ", got " .. vim.inspect(toplines()))
  end

  it("[M01] scrolls both panes when the wheel is used over a pane while the explorer has focus", function()
    focus("panel")
    expect_toplines({ 1, 1 })
    wheel("modified", 2)
    expect_toplines({ 7, 7 })
    wheel("original", 1)
    expect_toplines({ 10, 10 })
  end)

  it("[M02] keeps panes aligned when the focused pane scrolls after an unfocused one", function()
    focus("original")
    wheel("modified", 2)
    expect_toplines({ 7, 7 })
    -- Neovim tracks each pane's bound position; a stale one would snap back.
    wheel("original", 1)
    expect_toplines({ 10, 10 })
  end)
end)
