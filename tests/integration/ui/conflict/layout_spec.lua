local h = require("tests.support")
local path = require("codediff.core.path")

describe("conflict editor layout", function()
  local repo
  local saved_layout
  local saved_result_position

  before_each(function()
    h.ensure_plugin_loaded()
    local config = require("codediff.config")
    saved_layout = config.options.diff.layout
    saved_result_position = config.options.diff.conflict_result_position
    config.options.diff.layout = "side-by-side"

    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", { "base" })
    repo.git("add file.txt")
    repo.git("commit -m base")
    repo.git("checkout -b feature")
    repo.write_file("file.txt", { "feature" })
    repo.git("commit -am feature")
    repo.git("checkout main")
    repo.write_file("file.txt", { "main" })
    repo.git("commit -am main")
    local merge_output = repo.git("merge feature --no-edit")
    assert.is_true(merge_output:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
  end)

  after_each(function()
    local config = require("codediff.config")
    config.options.diff.layout = saved_layout
    config.options.diff.conflict_result_position = saved_result_position
    require("codediff.ui.lifecycle").cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
    end
  end)

  it("places Result between the two inputs in center mode", function()
    require("codediff.config").options.diff.conflict_result_position = "center"
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
      "center conflict editor never became ready"
    )

    local original_position = vim.api.nvim_win_get_position(session.original_win)
    local modified_position = vim.api.nvim_win_get_position(session.modified_win)
    local result_position = vim.api.nvim_win_get_position(session.result_win)
    assert.equals(original_position[1], result_position[1])
    assert.equals(modified_position[1], result_position[1])
    assert.is_true(result_position[2] > math.min(original_position[2], modified_position[2]))
    assert.is_true(result_position[2] < math.max(original_position[2], modified_position[2]))
  end)
end)
