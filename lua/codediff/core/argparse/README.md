# argparse

A small, dependency-free command-line argument parser for Neovim `:command`s,
modeled on Rust's [clap](https://github.com/clap-rs/clap) builder API
(`Command` / `Arg` / `ArgMatches` / `ArgAction` / `ValueParser`) and adapted to
Neovim: it consumes `opts.fargs`, exposes `bang`/`range`, **returns** errors
instead of calling `os.exit`, and drives a `:command` completion callback with
live candidate lists (including dynamic values such as git refs and files).

One declarative command tree drives **parsing, subcommand dispatch, validation,
completion, and help** — so adding a flag or subcommand is a single declaration.

## Quick start

```lua
local ap  = require("codediff.core.argparse")
local Arg = ap.Arg

local cmd = ap.Command.new("greet")
  :arg(Arg.new("name"):required(true))                         -- positional
  :arg(Arg.flag("loud"):long("--loud"))                        -- boolean flag
  :arg(Arg.new("n"):long("--times"):short("-n")                -- typed option + default
        :value_parser(ap.value_parser.int):default(1))

local m, err = cmd:parse({ "World", "--loud", "-n", "3" })
if err then return vim.notify(tostring(err), vim.log.levels.ERROR) end

m:get_one("name")  --> "World"
m:get_flag("loud") --> true
m:get_one("n")     --> 3
```

## Concepts

| Concept | What it is |
| --- | --- |
| **Command** | A (sub)command node: holds args, nested subcommands, and an optional handler. |
| **Arg** | One argument. It is a **positional** when it has neither `:long()` nor `:short()`, otherwise an option/flag. |
| **ArgAction** | What happens when an arg is seen: `SET`, `SET_TRUE`, `SET_FALSE`, `APPEND`, `COUNT`. |
| **value_parser** | Validates/coerces a raw string into a typed value (`string`, `int`, `number`, `boolean`, `enum`, `custom`). |
| **ArgMatches** | The immutable parse result, queried with typed getters. |

## API

### `ap.Command`

| Method | Description |
| --- | --- |
| `Command.new(name)` | Create a command. |
| `:about(text)` | Short description (used in help). |
| `:arg(arg)` / `:args({...})` | Add argument(s). |
| `:subcommand(cmd)` | Add a nested command. |
| `:handler(fn)` | Handler invoked for this command when it is the matched leaf. Receives `ArgMatches`. |
| `:trailing(arg)` | Describe operands after `--` (help/completion only). Give the `arg` a `:completor()` to complete them; parsed values arrive via `ArgMatches:trailing()`. |
| `:parse(tokens, ctx)` | Parse only. Returns `matches` or `nil, err`. |
| `:execute(tokens, ctx)` | Parse **and** dispatch to the matched leaf's handler. Returns `matches` or `nil, err`. |

`ctx` (optional) is `{ bang = boolean, range = { line1, line2 } }`.

### `ap.Arg`

| Method | Description |
| --- | --- |
| `Arg.new(id)` | Create an argument. `id` is the key used in `ArgMatches`. Positional unless a name is set. |
| `Arg.flag(id)` | Shortcut for a boolean flag (`action = SET_TRUE`). |
| `:long("--name")` / `:short("-n")` | Option names (leading dashes optional). |
| `:action(a)` | Set the `ArgAction` (default `SET`). |
| `:value_parser(vp)` | Set the value parser (default `value_parser.string`). |
| `:choices({...})` | Shortcut for `:value_parser(value_parser.enum({...}))`. |
| `:default(v)` | Value used when the arg is absent. |
| `:required(true)` | Error if the arg is absent. |
| `:conflicts_with(id)` / `:requires(id)` | Cross-argument constraints (by arg **id**; accepts a string or list). |
| `:global(true)` | Persistent: recognized by this command **and all descendants**. |
| `:completor(fn)` | Dynamic value completion. `fn(ctx) -> { candidate, ... }`, `ctx = { arg_lead, command }`. |
| `:help(text)` / `:value_name(name)` | Help metadata. |

### `ap.action`

`SET` · `SET_TRUE` · `SET_FALSE` · `APPEND` (collect every occurrence) ·
`COUNT` (count occurrences).

### `ap.value_parser`

`string` · `int` · `number` · `boolean` · `enum({...})` (alias `one_of`) ·
`custom(fn, name)`.

A value parser is a table `{ name, parse, choices? }`; `parse(raw)` returns
`value` or `nil, detail`. `enum` exposes `choices` (used by completion/help).

### `ArgMatches`

| Method | Returns |
| --- | --- |
| `:get_one(id)` | Single value, or `nil`. |
| `:get_flag(id)` | `true`/`false`. |
| `:get_many(id)` | List (for `APPEND`); always a table. |
| `:get_count(id)` | Number (for `COUNT`). |
| `:contains(id)` | Whether the arg was resolved (including defaults). |
| `:subcommand()` | `name, sub_matches` or `nil`. |
| `:bang()` / `:range()` | The `!` bang and `{l1, l2}` visual range. |

Global values are shared across the whole match chain, so a global flag is
readable from any level (e.g. `sub_matches:get_one("cwd")`).

### `ap.errors`, `ap.help`, `ap.complete`

- `errors.KIND` — `UNKNOWN_ARGUMENT`, `MISSING_VALUE`, `INVALID_VALUE`,
  `MISSING_REQUIRED`, `TOO_MANY_ARGUMENTS`, `CONFLICT`, `MISSING_REQUIREMENT`.
  A returned error is an object; `tostring(err)` is the message and `err.kind`
  is one of the above.
- `help.usage(command)` / `help.render(command)` — generated usage line / full help.
- `complete.complete(command, prior_tokens, arg_lead)` — candidate list, where
  `prior_tokens` are the already-typed tokens (excluding the command name and
  the partial `arg_lead`).

## Neovim integration

```lua
local ap  = require("codediff.core.argparse")
local app = build_app()   -- your Command tree

vim.api.nvim_create_user_command("CodeDiff", function(opts)
  local ctx = {
    bang  = opts.bang,
    range = opts.range == 2 and { opts.line1, opts.line2 } or nil,
  }
  local _, err = app:execute(opts.fargs, ctx)
  if err then vim.notify("CodeDiff: " .. tostring(err), vim.log.levels.ERROR) end
end, {
  nargs = "*", bang = true, range = true, desc = ap.help.usage(app),
  complete = function(arg_lead, cmd_line)
    local toks = vim.split(cmd_line, "%s+", { trimempty = true })
    table.remove(toks, 1)                                          -- drop the command name
    if arg_lead ~= "" and toks[#toks] == arg_lead then table.remove(toks) end
    return ap.complete.complete(app, toks, arg_lead)
  end,
})
```

## Parsing semantics

- **Value forms:** `--opt value`, `--opt=value`, `-o value`, `-o=value`, `-ovalue`.
- **`--`** ends option parsing; everything after is a git-style trailing operand,
  collected in `ArgMatches:trailing()` (kept separate from positionals, so it
  never triggers too-many-arguments). Completed via `Command:trailing(arg)`.
- **Subcommand routing:** the first non-flag token equal to a subcommand name
  descends into that subcommand; otherwise tokens are the current command's
  positionals.
- **Global flags** may appear before or after the subcommand.
- **Order:** parse → apply `value_parser` → apply `ArgAction` → apply defaults →
  validate `required`, then `conflicts_with` / `requires`.
- **Errors are returned, never raised** — route them to `vim.notify`.

## Intentionally out of scope

Faithful to clap's model but trimmed for Neovim; not supported (by design):

- Combined short flags (`-rf`) and stacked counts (`-vv`) — pass repeated flags
  as separate tokens.
- Derive/macro API (a Rust compile-time feature with no Lua equivalent).
- Shell-completion **script** generation — Neovim uses the `complete` callback above.
- Env-var fallbacks, comma value delimiters, argument groups, and help styling.

Each is a small, additive extension if a future need arises.

## Tests

```sh
nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_and_exit('tests/unit/core/argparse_spec.lua')"
```
