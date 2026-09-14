# Repository fixtures

Git-backed tests share `tests/framework/repository.lua`. The UI E2Es use the
small deterministic graph in `refresh_repo.lua`; older tests obtain an empty
worktree through `tests/helpers.lua:create_temp_git_repo()`.

## Isolation and lifecycle

The factory builds each seed once per spec process, entirely in Neovim's TMP
area. Each test receives:

```text
TMP/case/
├── repository.git/       independent bare clone of the seed
└── worktree/             git worktree add ... main
    └── .git              Git's link to this case's metadata
```

The clone uses `--no-hardlinks`. Refs, indexes, Git config and loose objects are
not shared between cases. Tests can commit, reset, merge, stage, move refs and
temporarily remove an object without affecting another test or the plugin's
repository. `repo.git_path("index")` locates metadata correctly for both linked
worktrees and ordinary repositories; tests must not assume `.git` is a directory.

`repo.cleanup()` removes the whole case, including its Git metadata, and restores
a valid current directory when necessary. Call it after closing the embedded UI.
A `VimLeavePre` fallback also removes seeds and abandoned cases. No fixture lives
in the checked-out source tree. If an unavailable backend skips a case during
setup, its cleanup hooks still run; cleanup failures are reported rather than
hidden by the skip.

`tests/init.lua` removes inherited repository/index environment overrides and
isolates global/system Git configuration. The factory also rejects inherited
repository overrides, disables hooks and signing, sets a local test identity,
and defaults to SHA-1. Explicit SHA-256 cases use the same factory.

## Refresh graph

The seed contains 13 small text files: ordinary files, two distant hunks, a moved
block, nested paths, spaces/Unicode, an empty file, a Lua file and a merge file.
Its five commits have fixed authors and dates:

```text
fixture/base
├── history one ── history two
├── incoming changes
└── current changes
```

Tags `fixture/one`, `fixture/two`, `fixture/incoming` and `fixture/current` retain
the corresponding commits. The seed's `main` stays at `fixture/base`.

| Profile | Initial state of the test worktree |
| --- | --- |
| `basic` / omitted | Clean base commit and named fixture tags |
| `hunks` | Two separated working-tree changes in `hunks.txt` |
| `workspace` | Mixed staged/unstaged content, nested changes, rename, deletion, untracked file |
| `history` | Two subsequent commits, added/deleted/renamed files, two review branches |
| `merge` | Real in-progress merge with two separated conflicts and automatic one-sided edits |

Golden contents are declared in `refresh_repo.files`; assertions do not ask the
production diff/merge calculator to construct their expectations.

## API

```lua
local fixture = require("tests.fixtures.refresh_repo")
local repo = fixture.new("workspace")

repo.command({ "add", "a.txt" })                 -- assert exit code 0
repo.command({ "diff", "--quiet" }, 1)          -- explicit expected nonzero status
repo.write_file("a.txt", { "one", "two" })
repo.write_bytes("a.txt", "one\r\ntwo")
repo.replace("a.txt", 2, "changed")
local index = repo.blob_lines(":0", "a.txt")
local index_path = repo.git_path("index")
repo.cleanup()
```

Prefer argv-form `command` for new cases. `git` also accepts existing string-form
commands; the refresh fixture checks their exit status, including merge failures
that must explicitly expect code 1.

The lower-level factory supports special states through the same lifecycle:

```lua
local repositories = require("tests.framework.repository")
local unborn = repositories.new({ unborn = true })
local ordinary = repositories.new({ worktree = false, unborn = true })
local remote = repositories.new({ bare = true, unborn = true })
local sha256 = fixture.new("history", { object_format = "sha256" })
```

An unborn worktree really has no `HEAD` commit. Its first commit is parentless;
it is not a test repo with a hidden extra initial commit. Bare fixtures serve as
local remotes. Ordinary `.git`-directory cases ensure the tests do not cover only
linked worktrees.

## Interactive reproduction

From the plugin checkout, start Neovim with `nvim --noplugin -u tests/init.lua`,
then run:

```vim
:lua fixture_repo = require('tests.fixtures.refresh_repo').new('workspace')
:lua vim.cmd('cd ' .. vim.fn.fnameescape(fixture_repo.dir))
:CodeDiff
```

Use the same profile to reproduce a failing operation. Print `fixture_repo.dir`
to inspect it from another shell while Neovim is running. The worktree is removed
when this Neovim exits. The full scenario map is in
[`ui/refresh/COVERAGE.md`](../ui/refresh/COVERAGE.md).
