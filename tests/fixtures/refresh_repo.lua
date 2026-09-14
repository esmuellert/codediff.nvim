-- A deterministic Git graph shared by refresh and UI-operation E2Es.
-- Every invocation returns a separate TMP repository and linked worktree.
local M = {}
local repositories = require("tests.framework.repository")

M.files = {
  ["a.txt"] = { "start", "base-A", "context", "end", "tail" },
  ["b.txt"] = { "start", "base-B", "end" },
  ["background.txt"] = { "unchanged" },
  ["hunks.txt"] = {
    "base-one",
    "context-02",
    "context-03",
    "context-04",
    "context-05",
    "context-06",
    "context-07",
    "context-08",
    "context-09",
    "context-10",
    "context-11",
    "base-two",
    "tail",
  },
  ["moves.txt"] = { "alpha_1", "alpha_2", "alpha_3", "alpha_4", "alpha_5", "unchanged_1", "unchanged_2", "unchanged_3", "beta_1", "beta_2", "beta_3", "beta_4", "beta_5" },
  ["nested/alpha.txt"] = { "alpha", "base-alpha", "end" },
  ["nested/deep/beta.txt"] = { "beta", "base-beta", "end" },
  ["rename/source file.txt"] = { "rename header", "rename body 1", "rename body 2", "rename body 3", "rename tail" },
  ["gone.txt"] = { "delete header", "delete body", "delete tail" },
  ["empty.txt"] = {},
  ["utf8/文件 name.txt"] = { "开始", "原始内容", "结束" },
  ["sample.lua"] = { "local value = 'base'", "return value" },
  ["merge.txt"] = {
    "merge start",
    "context-02",
    "context-03",
    "base-one",
    "context-05",
    "context-06",
    "context-07",
    "base-incoming-only",
    "context-09",
    "context-10",
    "context-11",
    "base-current-only",
    "context-13",
    "context-14",
    "context-15",
    "base-two",
    "context-17",
    "context-18",
    "merge end",
  },
}

local function build(repo)
  for filename, content in pairs(M.files) do
    repo.write_file(filename, vim.deepcopy(content))
  end
  local refs = { base = repo.commit("fixture base") }
  repo.command({ "tag", "fixture/base", refs.base })

  repo.replace("a.txt", 2, "history-one")
  repo.write_file("history/added.txt", { "added in history" })
  refs.first = repo.commit("history one")
  repo.replace("a.txt", 2, "history-two")
  repo.replace("b.txt", 2, "history-two-B")
  repo.command({ "mv", "rename/source file.txt", "rename/renamed file.txt" })
  repo.command({ "rm", "gone.txt" })
  refs.second = repo.commit("history two")
  repo.command({ "tag", "fixture/one", refs.first })
  repo.command({ "tag", "fixture/two", refs.second })

  repo.command({ "reset", "--hard", refs.base })
  repo.command({ "checkout", "-b", "seed-incoming" })
  repo.replace("a.txt", 2, "incoming-A")
  repo.replace("b.txt", 2, "incoming-B")
  repo.replace("merge.txt", 4, "incoming-one")
  repo.replace("merge.txt", 8, "incoming-only")
  repo.replace("merge.txt", 16, "incoming-two")
  refs.incoming = repo.commit("incoming changes")
  repo.command({ "tag", "fixture/incoming", refs.incoming })
  repo.command({ "checkout", "main" })
  repo.replace("a.txt", 2, "current-A")
  repo.replace("b.txt", 2, "current-B")
  repo.replace("merge.txt", 4, "current-one")
  repo.replace("merge.txt", 12, "current-only")
  repo.replace("merge.txt", 16, "current-two")
  refs.current = repo.commit("current changes")
  repo.command({ "tag", "fixture/current", refs.current })
  repo.command({ "reset", "--hard", refs.base })
  repo.command({ "branch", "-D", "seed-incoming" })
  return refs
end

function M.new(profile, options)
  local repo = repositories.new(vim.tbl_extend("force", { key = "refresh", build = build }, options or {}))
  for name, revision in pairs(repo.seed) do
    repo[name] = revision
  end
  local git = repo.git
  repo.git = function(args, expected)
    return git(args, expected or 0)
  end
  local ok, err = pcall(function()
    if profile == "hunks" then
      repo.replace("hunks.txt", 1, "working-one")
      repo.replace("hunks.txt", 12, "working-two")
    elseif profile == "workspace" then
      repo.replace("a.txt", 2, "index-A")
      repo.command({ "add", "a.txt" })
      repo.replace("a.txt", 2, "working-A")
      repo.replace("b.txt", 2, "working-B")
      repo.replace("nested/alpha.txt", 2, "working-alpha")
      repo.replace("nested/deep/beta.txt", 2, "working-beta")
      repo.write_file("fresh.txt", { "new header", "new body", "new tail" })
      assert.equals(0, vim.fn.delete(repo.path("gone.txt")))
      repo.command({ "mv", "rename/source file.txt", "rename/renamed file.txt" })
    elseif profile == "history" then
      repo.command({ "reset", "--hard", repo.second })
      repo.command({ "branch", "review/left", repo.first })
      repo.command({ "branch", "review/right", repo.second })
    elseif profile == "merge" then
      repo.command({ "reset", "--hard", repo.current })
      repo.command({ "branch", "incoming", repo.incoming })
      repo.command({ "merge", "incoming", "--no-edit" }, 1)
      assert.is_true(repo.command({ "ls-files", "--unmerged" }) ~= "", "merge fixture must contain real index conflicts")
    else
      assert(profile == nil or profile == "basic", "unknown fixture profile: " .. tostring(profile))
      assert.equals("", repo.command({ "status", "--porcelain" }), "base fixture must be clean")
    end
  end)
  if not ok then
    repo.cleanup()
    error(err)
  end
  return repo
end

return M
