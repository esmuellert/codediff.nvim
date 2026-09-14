-- Hand-authored screen rows for a six-line buffer: one, two, three, four, five, six.
-- These are visual expectations, not output from the gutter calculator.
local M = {
  {
    name = "single real position",
    range = { start_line = 2, end_line = 3 },
    fillers = {},
    rows = { "  one", "[ two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "one real line and one trailing filler",
    range = { start_line = 2, end_line = 3 },
    fillers = { [2] = 1 },
    rows = { "  one", "╭─two", "╰─╱╱╱╱", "  three", "  four", "  five", "  six" },
  },
  {
    name = "one real line and multiple trailing fillers",
    range = { start_line = 2, end_line = 3 },
    fillers = { [2] = 2 },
    rows = { "  one", "╭─two", "│ ╱╱╱╱", "╰─╱╱╱╱", "  three", "  four", "  five", "  six" },
  },
  {
    name = "ordinary multiline range",
    range = { start_line = 2, end_line = 5 },
    fillers = {},
    rows = { "  one", "╭─two", "│ three", "╰─four", "  five", "  six" },
  },
  {
    name = "leading filler",
    range = { start_line = 2, end_line = 5 },
    fillers = { [1] = 1 },
    rows = { "  one", "╭─╱╱╱╱", "│ two", "│ three", "╰─four", "  five", "  six" },
  },
  {
    name = "interior filler",
    range = { start_line = 2, end_line = 5 },
    fillers = { [3] = 2 },
    rows = { "  one", "╭─two", "│ three", "│ ╱╱╱╱", "│ ╱╱╱╱", "╰─four", "  five", "  six" },
  },
  {
    name = "trailing filler",
    range = { start_line = 2, end_line = 5 },
    fillers = { [4] = 2 },
    rows = { "  one", "╭─two", "│ three", "│ four", "│ ╱╱╱╱", "╰─╱╱╱╱", "  five", "  six" },
  },
  {
    name = "empty without filler",
    range = { start_line = 3, end_line = 3 },
    fillers = {},
    rows = { "  one", "  two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "empty with one filler",
    range = { start_line = 3, end_line = 3 },
    fillers = { [2] = 1 },
    rows = { "  one", "  two", "[ ╱╱╱╱", "  three", "  four", "  five", "  six" },
  },
  {
    name = "empty with multiple fillers",
    range = { start_line = 3, end_line = 3 },
    fillers = { [2] = 2 },
    rows = { "  one", "  two", "╭─╱╱╱╱", "╰─╱╱╱╱", "  three", "  four", "  five", "  six" },
  },
  {
    name = "empty with filler on the fallback anchor",
    range = { start_line = 3, end_line = 3 },
    fillers = { [3] = 1 },
    rows = { "  one", "  two", "  three", "[ ╱╱╱╱", "  four", "  five", "  six" },
  },
  {
    name = "BOF leading filler",
    range = { start_line = 1, end_line = 3 },
    fillers = { [0] = 2 },
    rows = { "╭─╱╱╱╱", "│ ╱╱╱╱", "│ one", "╰─two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "fillers both before and after line one",
    range = { start_line = 1, end_line = 3 },
    fillers = { [0] = 2, [1] = 1 },
    rows = { "╭─╱╱╱╱", "│ ╱╱╱╱", "│ one", "│ ╱╱╱╱", "╰─two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "one filler-only position at BOF",
    range = { start_line = 1, end_line = 1 },
    fillers = { [0] = 1 },
    rows = { "[ ╱╱╱╱", "  one", "  two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "multiple filler-only positions at BOF",
    range = { start_line = 1, end_line = 1 },
    fillers = { [0] = 2 },
    rows = { "╭─╱╱╱╱", "╰─╱╱╱╱", "  one", "  two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "unmarked BOF fillers must not shift marked fillers after line one",
    range = { start_line = 2, end_line = 3 },
    fillers = { [0] = 2, [1] = 1 },
    rows = { "  ╱╱╱╱", "  ╱╱╱╱", "  one", "╭─╱╱╱╱", "╰─two", "  three", "  four", "  five", "  six" },
  },
  {
    name = "trailing filler at EOF",
    range = { start_line = 6, end_line = 7 },
    fillers = { [6] = 2 },
    rows = { "  one", "  two", "  three", "  four", "  five", "╭─six", "│ ╱╱╱╱", "╰─╱╱╱╱" },
  },
  {
    name = "empty projection at EOF",
    range = { start_line = 7, end_line = 7 },
    fillers = { [6] = 2 },
    rows = { "  one", "  two", "  three", "  four", "  five", "  six", "╭─╱╱╱╱", "╰─╱╱╱╱" },
  },
  {
    name = "unrelated fillers outside the block stay blank",
    range = { start_line = 3, end_line = 5 },
    fillers = { [1] = 1, [5] = 1 },
    rows = { "  one", "  ╱╱╱╱", "  two", "╭─three", "╰─four", "  five", "  ╱╱╱╱", "  six" },
  },
}

-- A real merge with an interior filler in incoming, plus a second file whose
-- filler is on the opposite side. Both use independently authored expectations.
function M.new_repo()
  local repo = require("tests.support.repository").new({ unborn = true })
  repo.write_file("conf.txt", { "before", "base1", "base2", "base3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "baseB", "afterB" })
  repo.write_file("deleted.txt", { "deleted one", "deleted two" })
  repo.commit("base")
  repo.command({ "checkout", "-b", "incoming" })
  repo.write_file("conf.txt", { "before", "base1", "THEIRS2", "THEIRS3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "THEIRS_B", "extraB", "afterB" })
  repo.commit("incoming")
  repo.command({ "checkout", "main" })
  repo.write_file("conf.txt", { "before", "OURS1", "inserted", "OURS2", "base3", "after", "tail" })
  repo.write_file("other.txt", { "beforeB", "OURS_B", "afterB" })
  repo.commit("current")
  repo.command({ "merge", "incoming", "--no-edit" }, 1)
  repo.write_file("fresh.txt", { "fresh one", "fresh two" })
  repo.write_file("plain-left.txt", { "before", "same", "keep", "after" })
  repo.write_file("plain-right.txt", { "before", "same", "keep", "inserted", "after" })
  return repo
end

M.merge_rows = {
  original = { "  before", "╭─base1", "│ THEIRS2", "│ ╱╱╱╱", "╰─THEIRS3", "  after", "  tail" },
  modified = { "  before", "╭─OURS1", "│ inserted", "│ OURS2", "╰─base3", "  after", "  tail" },
  result = { "  before", "╭─base1", "│ base2", "╰─base3", "  after", "  tail" },
}

M.other_merge_rows = {
  original = { "  beforeB", "╭─THEIRS_B", "╰─extraB", "  afterB" },
  modified = { "  beforeB", "╭─╱╱╱╱", "╰─OURS_B", "  afterB" },
  result = { "  beforeB", "[ baseB", "  afterB" },
}

return M
