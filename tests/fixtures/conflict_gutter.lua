-- Hand-authored screen rows for a six-line buffer: one, two, three, four, five, six.
-- These are visual expectations, not output from the gutter calculator.
return {
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
