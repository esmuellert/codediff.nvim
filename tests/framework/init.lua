-- tests/framework/init.lua
--
-- Public entry point for the codediff.nvim test framework. This module owns
-- the process-level setup: augmenting the global `assert`, installing the
-- busted-style DSL (`describe`, `it`, `before_each`, `after_each`, `pending`),
-- and exposing `run_file(spec)` / `run_and_exit(spec)` for the shell scripts.
--
-- The framework has no external test dependency. Runnable specs, including its
-- own self-tests, live in unit/, integration/ and e2e/ rather than beside the
-- runner implementation. Shared feature drivers live separately in support/.

local M = {}

local installed = false

--- Install framework globals and start collecting tests.
-- Idempotent — calling it more than once is a no-op.
function M.setup()
  if installed then
    return
  end
  installed = true

  -- Assertion library replaces `_G.assert`. It is a callable table so the
  -- stdlib form `assert(cond[, msg, ...])` continues to work with full
  -- passthrough of extra return values.
  local a = require("tests.framework.assert")
  _G.assert = a

  -- Some legacy spec files explicitly do `local assert = require("luassert")`.
  -- Route those requires to our in-tree assert module so those specs work
  -- unchanged.
  package.preload["luassert"] = function()
    return a
  end

  -- describe/it/before_each/after_each/pending globals
  require("tests.framework.busted").install()
end

--- Run a single spec file. Returns (ok, counts).
function M.run_file(spec_file)
  return require("tests.framework.runner").run_file(spec_file)
end

--- Run a single spec file and exit Neovim with the appropriate exit code.
--- Used by the child processes the supervisor spawns.
function M.run_and_exit(spec_file)
  return require("tests.framework.runner").run_and_exit(spec_file)
end

--- Run every discovered spec file. Returns (ok, results).
--- Concurrency and output grouping live in the supervisor; see its header.
function M.run_all(opts)
  return require("tests.framework.supervisor").run(opts)
end

--- Run every discovered spec file and exit with the appropriate exit code.
--- This is the single entry point used by tests/run_tests.{sh,cmd}.
function M.run_all_and_exit(opts)
  return require("tests.framework.supervisor").run_and_exit(opts)
end

return M
