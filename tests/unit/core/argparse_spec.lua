-- Tests for the standalone argparse library (lua/codediff/core/argparse).
-- Covers the parser, value parsers, actions, validation, Neovim extras
-- (bang/range/end-of-options), dispatch, completion, help, and an end-to-end
-- model of the real :CodeDiff command grammar (all plugin use cases).

local ap = require("codediff.core.argparse")
local Arg = ap.Arg
local Command = ap.Command
local action = ap.action
local vp = ap.value_parser

describe("argparse.value_parser", function()
  it("string accepts anything", function()
    assert.equals("HEAD~3", vp.string.parse("HEAD~3"))
  end)

  it("int accepts integers and rejects fractions/non-numbers", function()
    assert.equals(10, vp.int.parse("10"))
    local v, err = vp.int.parse("1.5")
    assert.is_nil(v)
    assert.matches("integer", err)
    local v2, err2 = vp.int.parse("abc")
    assert.is_nil(v2)
    assert.is_not_nil(err2)
  end)

  it("boolean parses common spellings", function()
    assert.is_true(vp.boolean.parse("true"))
    assert.is_true(vp.boolean.parse("yes"))
    assert.is_false(vp.boolean.parse("0"))
    local v, err = vp.boolean.parse("maybe")
    assert.is_nil(v)
    assert.is_not_nil(err)
  end)

  it("enum validates membership and exposes choices", function()
    local p = vp.enum({ "inline", "side-by-side" })
    assert.equals("inline", p.parse("inline"))
    assert.are.same({ "inline", "side-by-side" }, p.choices)
    local v, err = p.parse("nope")
    assert.is_nil(v)
    assert.matches("expected one of", err)
  end)

  it("custom wraps a function", function()
    local p = vp.custom(function(raw)
      if raw == "ok" then
        return "OK"
      end
      return nil, "bad"
    end)
    assert.equals("OK", p.parse("ok"))
    local v, err = p.parse("x")
    assert.is_nil(v)
    assert.equals("bad", err)
  end)
end)

describe("argparse.parser: positionals and flags", function()
  local function app()
    return Command.new("prog")
      :arg(Arg.new("a"))
      :arg(Arg.new("b"))
      :arg(Arg.flag("verbose"):long("--verbose"):short("-v"))
      :arg(Arg.new("out"):long("--out"):short("-o"))
  end

  it("parses no args", function()
    local m = assert(app():parse({}))
    assert.is_nil(m:get_one("a"))
    assert.is_false(m:get_flag("verbose"))
  end)

  it("parses positionals in order", function()
    local m = assert(app():parse({ "x", "y" }))
    assert.equals("x", m:get_one("a"))
    assert.equals("y", m:get_one("b"))
  end)

  it("parses a boolean flag (long and short)", function()
    assert.is_true(assert(app():parse({ "--verbose" })):get_flag("verbose"))
    assert.is_true(assert(app():parse({ "-v" })):get_flag("verbose"))
  end)

  it("parses an option value via space form", function()
    local m = assert(app():parse({ "--out", "file.txt" }))
    assert.equals("file.txt", m:get_one("out"))
  end)

  it("parses an option value via equals form", function()
    assert.equals("file.txt", assert(app():parse({ "--out=file.txt" })):get_one("out"))
  end)

  it("parses a short option value (space, equals, attached)", function()
    assert.equals("f", assert(app():parse({ "-o", "f" })):get_one("out"))
    assert.equals("f", assert(app():parse({ "-o=f" })):get_one("out"))
    assert.equals("f", assert(app():parse({ "-of" })):get_one("out"))
  end)

  it("allows flags interleaved with positionals", function()
    local m = assert(app():parse({ "x", "--verbose", "y", "--out", "o" }))
    assert.equals("x", m:get_one("a"))
    assert.equals("y", m:get_one("b"))
    assert.is_true(m:get_flag("verbose"))
    assert.equals("o", m:get_one("out"))
  end)
end)

describe("argparse.parser: subcommands and globals", function()
  local function app()
    return Command.new("root")
      :arg(Arg.flag("inline"):long("--inline"):global(true))
      :arg(Arg.new("cwd"):long("--cwd"):global(true))
      :arg(Arg.new("rev"))
      :subcommand(Command.new("sub"):arg(Arg.new("target")):arg(Arg.flag("force"):long("--force")))
  end

  it("routes to a subcommand and exposes its args", function()
    local m = assert(app():parse({ "sub", "t", "--force" }))
    local name, sub = m:subcommand()
    assert.equals("sub", name)
    assert.equals("t", sub:get_one("target"))
    assert.is_true(sub:get_flag("force"))
  end)

  it("does not treat a bare revision as a subcommand", function()
    local m = assert(app():parse({ "HEAD" }))
    assert.is_nil((m:subcommand()))
    assert.equals("HEAD", m:get_one("rev"))
  end)

  it("makes global flags visible inside the subcommand (before)", function()
    local _, sub = assert(app():parse({ "--inline", "sub", "t" })):subcommand()
    assert.is_true(sub:get_flag("inline"))
  end)

  it("makes global flags visible inside the subcommand (after)", function()
    local _, sub = assert(app():parse({ "sub", "t", "--inline", "--cwd", "/x" })):subcommand()
    assert.is_true(sub:get_flag("inline"))
    assert.equals("/x", sub:get_one("cwd"))
  end)

  it("does not recognize a subcommand-local flag at the parent", function()
    local ok, err = app():parse({ "--force", "sub" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.UNKNOWN_ARGUMENT, err.kind)
  end)
end)

describe("argparse.parser: actions and defaults", function()
  it("APPEND collects every occurrence", function()
    local c = Command.new("p"):arg(Arg.new("x"):long("--x"):action(action.APPEND))
    local m = assert(c:parse({ "--x", "a", "--x", "b", "--x", "c" }))
    assert.are.same({ "a", "b", "c" }, m:get_many("x"))
  end)

  it("APPEND positional is variadic", function()
    local c = Command.new("p"):arg(Arg.new("files"):action(action.APPEND))
    local m = assert(c:parse({ "a", "b", "c" }))
    assert.are.same({ "a", "b", "c" }, m:get_many("files"))
  end)

  it("COUNT counts repeated flags", function()
    local c = Command.new("p"):arg(Arg.new("v"):long("--verbose"):short("-v"):action(action.COUNT))
    local m = assert(c:parse({ "-v", "-v", "-v" }))
    assert.equals(3, m:get_count("v"))
  end)

  it("applies defaults when an arg is absent", function()
    local c = Command.new("p"):arg(Arg.new("mode"):long("--mode"):default("fast"))
    assert.equals("fast", assert(c:parse({})):get_one("mode"))
    assert.equals("slow", assert(c:parse({ "--mode", "slow" })):get_one("mode"))
  end)

  it("applies a global default visible from a subcommand", function()
    local c = Command.new("root")
      :arg(Arg.new("layout"):long("--layout"):global(true):default("side-by-side"))
      :subcommand(Command.new("sub"))
    local _, sub = assert(c:parse({ "sub" })):subcommand()
    assert.equals("side-by-side", sub:get_one("layout"))
  end)

  it("get_flag/get_many/get_count/contains behave for absent args", function()
    local m = assert(Command.new("p"):arg(Arg.new("x"):long("--x")):parse({}))
    assert.is_false(m:get_flag("x"))
    assert.are.same({}, m:get_many("x"))
    assert.equals(0, m:get_count("x"))
    assert.is_false(m:contains("x"))
  end)
end)

describe("argparse.parser: typed values", function()
  it("coerces int values", function()
    local m = assert(Command.new("p"):arg(Arg.new("n"):long("--n"):value_parser(vp.int)):parse({ "--n", "42" }))
    assert.equals(42, m:get_one("n"))
  end)

  it("validates enum/choices", function()
    local c = Command.new("p"):arg(Arg.new("layout"):long("--layout"):choices({ "inline", "side-by-side" }))
    assert.equals("inline", assert(c:parse({ "--layout", "inline" })):get_one("layout"))
    local ok, err = c:parse({ "--layout", "nope" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.INVALID_VALUE, err.kind)
  end)
end)

describe("argparse.parser: validation errors", function()
  local function app()
    return Command.new("p")
      :arg(Arg.new("name"):long("--name"):required(true))
      :arg(Arg.flag("a"):long("--aaa"):conflicts_with("b"))
      :arg(Arg.flag("b"):long("--bbb"))
      :arg(Arg.flag("c"):long("--ccc"):requires("name"))
  end

  it("errors on unknown flag", function()
    local ok, err = Command.new("p"):parse({ "--nope" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.UNKNOWN_ARGUMENT, err.kind)
    assert.matches("--nope", tostring(err))
  end)

  it("errors on missing option value", function()
    local ok, err = Command.new("p"):arg(Arg.new("o"):long("--o")):parse({ "--o" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.MISSING_VALUE, err.kind)
  end)

  it("errors when a boolean flag is given a value", function()
    local ok, err = Command.new("p"):arg(Arg.flag("f"):long("--flag")):parse({ "--flag=1" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.INVALID_VALUE, err.kind)
  end)

  it("errors on missing required argument", function()
    local ok, err = app():parse({})
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.MISSING_REQUIRED, err.kind)
  end)

  it("errors on conflicting arguments", function()
    local ok, err = app():parse({ "--name", "n", "--aaa", "--bbb" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.CONFLICT, err.kind)
  end)

  it("errors on unmet requirement", function()
    local ok, err = Command.new("p")
      :arg(Arg.new("name"):long("--name"))
      :arg(Arg.flag("c"):long("--ccc"):requires("name"))
      :parse({ "--ccc" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.MISSING_REQUIREMENT, err.kind)
  end)

  it("errors on too many positionals", function()
    local ok, err = Command.new("p"):arg(Arg.new("only")):parse({ "a", "b" })
    assert.is_nil(ok)
    assert.equals(ap.errors.KIND.TOO_MANY_ARGUMENTS, err.kind)
  end)
end)

describe("argparse.parser: neovim extras", function()
  it("carries bang and range through parse", function()
    local m = assert(Command.new("p"):parse({}, { bang = true, range = { 3, 9 } }))
    assert.is_true(m:bang())
    assert.are.same({ 3, 9 }, m:range())
  end)

  it("propagates bang/range into subcommand matches", function()
    local c = Command.new("root"):subcommand(Command.new("sub"))
    local _, sub = assert(c:parse({ "sub" }, { bang = true, range = { 1, 2 } })):subcommand()
    assert.is_true(sub:bang())
    assert.are.same({ 1, 2 }, sub:range())
  end)

  it("captures tokens after -- as trailing operands (not positionals or flags)", function()
    local m = assert(Command.new("p"):arg(Arg.new("x")):arg(Arg.flag("f"):long("--f")):parse({ "--", "--f" }))
    assert.is_nil(m:get_one("x"))
    assert.is_false(m:get_flag("f"))
    assert.are.same({ "--f" }, m:trailing())
  end)

  it("splits positionals (before --) from trailing operands (after --)", function()
    local m = assert(Command.new("p"):arg(Arg.new("a")):arg(Arg.new("b")):parse({ "a", "b", "--", "p1", "p2" }))
    assert.equals("a", m:get_one("a"))
    assert.equals("b", m:get_one("b"))
    assert.are.same({ "p1", "p2" }, m:trailing())
  end)

  it("trailing operands do not trigger too-many-arguments", function()
    local m, err = Command.new("p"):arg(Arg.new("only")):parse({ "x", "--", "path/one", "path/two" })
    assert.is_not_nil(m)
    assert.is_nil(err)
    assert.equals("x", m:get_one("only"))
    assert.are.same({ "path/one", "path/two" }, m:trailing())
  end)

  it("trailing() is an empty list when there is no --", function()
    assert.are.same({}, assert(Command.new("p"):arg(Arg.new("x")):parse({ "v" })):trailing())
  end)
end)

describe("argparse.command: dispatch", function()
  it("invokes the matched leaf handler with its matches", function()
    local captured
    local app = Command.new("root")
      :handler(function(m)
        captured = { where = "root", rev = m:get_one("rev") }
      end)
      :arg(Arg.new("rev"))
      :subcommand(Command.new("sub"):arg(Arg.new("t")):handler(function(m)
        captured = { where = "sub", t = m:get_one("t") }
      end))

    app:execute({ "HEAD" })
    assert.are.same({ where = "root", rev = "HEAD" }, captured)

    app:execute({ "sub", "target" })
    assert.are.same({ where = "sub", t = "target" }, captured)
  end)

  it("returns the parse error without invoking a handler", function()
    local called = false
    local app = Command.new("root"):handler(function()
      called = true
    end)
    local m, err = app:execute({ "--nope" })
    assert.is_nil(m)
    assert.is_not_nil(err)
    assert.is_false(called)
  end)
end)

describe("argparse.complete", function()
  local function app()
    return Command.new("root")
      :arg(Arg.flag("inline"):long("--inline"):global(true))
      :arg(Arg.new("layout"):long("--layout"):global(true):choices({ "inline", "side-by-side" }))
      :arg(Arg.new("rev"):completor(function()
        return { "main", "develop", "HEAD" }
      end))
      :subcommand(
        Command.new("history")
          :arg(Arg.new("range"))
          :arg(Arg.flag("reverse"):long("--reverse"):short("-r"))
          :arg(Arg.new("base"):long("--base"):short("-b"))
      )
      :subcommand(Command.new("merge"))
      :trailing(Arg.new("path"):completor(function()
        return { "src/a.txt", "src/b.txt", "README.md" }
      end))
  end

  it("suggests subcommands and root positional values at the first slot", function()
    local c = ap.complete.complete(app(), {}, "")
    assert.is_true(vim.tbl_contains(c, "history"))
    assert.is_true(vim.tbl_contains(c, "merge"))
    assert.is_true(vim.tbl_contains(c, "main"))
  end)

  it("filters candidates by the current prefix", function()
    assert.are.same({ "history" }, ap.complete.complete(app(), {}, "hi"))
    assert.are.same({ "HEAD" }, ap.complete.complete(app(), {}, "HE"))
  end)

  it("suggests flag names when the lead starts with a dash", function()
    local c = ap.complete.complete(app(), { "history" }, "--")
    assert.is_true(vim.tbl_contains(c, "--reverse"))
    assert.is_true(vim.tbl_contains(c, "--base"))
    assert.is_true(vim.tbl_contains(c, "--inline")) -- inherited global
  end)

  it("filters flags by prefix and offers short forms", function()
    assert.are.same({ "--reverse" }, ap.complete.complete(app(), { "history" }, "--r"))
    assert.is_true(vim.tbl_contains(ap.complete.complete(app(), { "history" }, "-"), "-r"))
  end)

  it("excludes an already-used non-repeatable flag", function()
    local c = ap.complete.complete(app(), { "history", "--reverse" }, "--")
    assert.is_false(vim.tbl_contains(c, "--reverse"))
    assert.is_true(vim.tbl_contains(c, "--base"))
  end)

  it("completes enum values for a pending option", function()
    local c = ap.complete.complete(app(), { "--layout" }, "")
    assert.are.same({ "inline", "side-by-side" }, c)
    assert.are.same({ "side-by-side" }, ap.complete.complete(app(), { "--layout" }, "side"))
  end)

  it("delegates positional value completion to the completor", function()
    local c = ap.complete.complete(app(), {}, "m")
    assert.is_true(vim.tbl_contains(c, "main"))
    assert.is_false(vim.tbl_contains(c, "HEAD"))
  end)

  it("completes trailing operands after -- via the trailing completor", function()
    local c = ap.complete.complete(app(), { "--" }, "")
    assert.is_true(vim.tbl_contains(c, "src/a.txt"))
    assert.is_true(vim.tbl_contains(c, "README.md"))
    -- After --, never offer subcommands, root positionals, or flags.
    assert.is_false(vim.tbl_contains(c, "history"))
    assert.is_false(vim.tbl_contains(c, "main"))
  end)

  it("filters trailing operands by prefix and works after a positional", function()
    assert.are.same({ "src/a.txt", "src/b.txt" }, ap.complete.complete(app(), { "HEAD", "--" }, "src/"))
  end)

  it("offers nothing after -- when the command has no trailing completor", function()
    assert.are.same({}, ap.complete.complete(app(), { "merge", "--" }, ""))
  end)
end)

describe("argparse.help", function()
  local function app()
    return Command.new("CodeDiff")
      :about("Live code review workspace for Neovim")
      :arg(Arg.flag("inline"):long("--inline"):help("Use inline layout"))
      :arg(Arg.new("rev"):help("Revision to compare"))
      :subcommand(Command.new("history"):about("Browse commit history"))
  end

  it("builds a usage line", function()
    local usage = ap.help.usage(app())
    assert.matches("CodeDiff", usage)
    assert.matches("%[%-%-inline%]", usage)
    assert.matches("history", usage)
  end)

  it("renders sections for commands, options, and arguments", function()
    local text = ap.help.render(app())
    assert.matches("Usage:", text)
    assert.matches("Commands:", text)
    assert.matches("Options:", text)
    assert.matches("Arguments:", text)
    assert.matches("Live code review workspace for Neovim", text)
  end)
end)

-- End-to-end: a faithful model of the real :CodeDiff grammar, proving every
-- plugin use case parses and dispatches to the right handler with the right data.
describe("argparse: CodeDiff grammar (use cases)", function()
  local last

  local function build()
    local function record(where)
      return function(m)
        last = { where = where, m = m }
      end
    end
    return Command.new("CodeDiff")
      -- global flags, valid for every mode
      :arg(Arg.flag("inline"):long("--inline"):global(true))
      :arg(Arg.flag("side_by_side"):long("--side-by-side"):global(true))
      :arg(Arg.new("repo"):long("--repo"):short("-C"):global(true))
      -- default (explorer): up to two revisions/dirs
      :arg(Arg.new("rev1"))
      :arg(Arg.new("rev2"))
      :handler(record("explorer"))
      :subcommand(Command.new("file"):arg(Arg.new("a")):arg(Arg.new("b")):handler(record("file")))
      :subcommand(Command.new("dir"):arg(Arg.new("d1")):arg(Arg.new("d2")):handler(record("dir")))
      :subcommand(
        Command.new("history")
          :arg(Arg.new("range"))
          :arg(Arg.new("file"))
          :arg(Arg.flag("reverse"):long("--reverse"):short("-r"))
          :arg(Arg.new("base"):long("--base"):short("-b"))
          :handler(record("history"))
      )
      :subcommand(Command.new("merge"):arg(Arg.new("file"):required(true)):handler(record("merge")))
      :subcommand(Command.new("install"):handler(record("install")))
  end

  before_each(function()
    last = nil
  end)

  it(":CodeDiff -> explorer", function()
    assert(build():execute({}))
    assert.equals("explorer", last.where)
    assert.is_nil(last.m:get_one("rev1"))
  end)

  it(":CodeDiff <rev> -> explorer at revision", function()
    assert(build():execute({ "HEAD" }))
    assert.equals("explorer", last.where)
    assert.equals("HEAD", last.m:get_one("rev1"))
  end)

  it(":CodeDiff <rev1> <rev2> -> explorer comparing revisions", function()
    assert(build():execute({ "main", "HEAD" }))
    assert.equals("main", last.m:get_one("rev1"))
    assert.equals("HEAD", last.m:get_one("rev2"))
  end)

  it(":CodeDiff --inline HEAD -> explorer with global layout", function()
    assert(build():execute({ "--inline", "HEAD" }))
    assert.equals("explorer", last.where)
    assert.is_true(last.m:get_flag("inline"))
    assert.equals("HEAD", last.m:get_one("rev1"))
  end)

  it(":CodeDiff file HEAD -> file diff vs revision", function()
    assert(build():execute({ "file", "HEAD" }))
    assert.equals("file", last.where)
    assert.equals("HEAD", last.m:get_one("a"))
  end)

  it(":CodeDiff file a.txt b.txt -> two-file diff", function()
    assert(build():execute({ "file", "a.txt", "b.txt" }))
    assert.equals("a.txt", last.m:get_one("a"))
    assert.equals("b.txt", last.m:get_one("b"))
  end)

  it(":CodeDiff dir d1 d2 -> directory diff", function()
    assert(build():execute({ "dir", "d1", "d2" }))
    assert.equals("dir", last.where)
    assert.equals("d1", last.m:get_one("d1"))
    assert.equals("d2", last.m:get_one("d2"))
  end)

  it(":CodeDiff history HEAD~10 % -r -> history with flags", function()
    assert(build():execute({ "history", "HEAD~10", "%", "-r" }))
    assert.equals("history", last.where)
    assert.equals("HEAD~10", last.m:get_one("range"))
    assert.equals("%", last.m:get_one("file"))
    assert.is_true(last.m:get_flag("reverse"))
  end)

  it(":CodeDiff history --base WORKING -> history with --base value", function()
    assert(build():execute({ "history", "--base", "WORKING" }))
    assert.equals("WORKING", last.m:get_one("base"))
  end)

  it(":CodeDiff merge file.txt -> merge tool", function()
    assert(build():execute({ "merge", "file.txt" }))
    assert.equals("merge", last.where)
    assert.equals("file.txt", last.m:get_one("file"))
  end)

  it(":CodeDiff merge (no file) -> required-arg error", function()
    local m, err = build():execute({ "merge" })
    assert.is_nil(m)
    assert.equals(ap.errors.KIND.MISSING_REQUIRED, err.kind)
  end)

  it(":CodeDiff! install -> install with bang", function()
    assert(build():execute({ "install" }, { bang = true }))
    assert.equals("install", last.where)
    assert.is_true(last.m:bang())
  end)

  it(":CodeDiff --repo=/repo history -> global --repo reaches the subcommand", function()
    assert(build():execute({ "--repo=/repo", "history" }))
    assert.equals("history", last.where)
    assert.equals("/repo", last.m:get_one("repo"))
  end)

  it(":CodeDiff -C /repo history -> git-style short alias reaches the subcommand", function()
    assert(build():execute({ "-C", "/repo", "history" }))
    assert.equals("history", last.where)
    assert.equals("/repo", last.m:get_one("repo"))
  end)

  it(":'<,'>CodeDiff history -> visual range reaches the handler", function()
    assert(build():execute({ "history" }, { range = { 5, 12 } }))
    assert.equals("history", last.where)
    assert.are.same({ 5, 12 }, last.m:range())
  end)

  it(":CodeDiff v1 v2 -- <path> -> revisions as positionals, path as trailing", function()
    assert(build():execute({ "v1", "v2", "--", "modules/network" }))
    assert.equals("explorer", last.where)
    assert.equals("v1", last.m:get_one("rev1"))
    assert.equals("v2", last.m:get_one("rev2"))
    assert.are.same({ "modules/network" }, last.m:trailing())
  end)
end)
