-- tests/framework/runner.lua
--
-- Executes tests collected by tests/framework/busted.lua and dispatches them
-- through tests/framework/reporter.lua.

local busted = require("tests.framework.busted")
local reporter = require("tests.framework.reporter")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function hrtime_ms()
  -- `vim.uv` is 0.10+; `vim.loop` is the pre-0.10 spelling.
  return math.floor((vim.uv or vim.loop).hrtime() / 1e6)
end

local function traceback(e)
  -- Preserve pending sentinel intact so the runner can detect it.
  if e == busted.PENDING_SENTINEL then return e end
  return debug.traceback(tostring(e), 2)
end

--- Run a function with xpcall + traceback; returns ok, err.
local function guarded(fn)
  return xpcall(fn, traceback)
end

-- ---------------------------------------------------------------------------
-- Test execution
-- ---------------------------------------------------------------------------

local function run_test(test)
  local desc = busted.describe_chain(test)
  local test_start = hrtime_ms()

  -- Registered as pending — via `pending("name", fn)` or body-less
  -- `pending("msg")` at describe level. Skip hooks and body entirely.
  -- (Mid-test `pending()` toggles this flag from inside the body, but we've
  -- already dispatched by then so this branch is only for pre-registered
  -- pending tests.)
  if test.pending then
    reporter.print_test(desc, test.name, "pending", test.pending_msg)
    return "pending"
  end

  -- Run before_each hooks (outer -> inner)
  busted.set_current(test)
  local before_err
  for _, hook in ipairs(busted.hooks_for(test, "before_each")) do
    local ok, err = guarded(hook)
    if not ok then
      if err ~= busted.PENDING_SENTINEL then
        before_err = err
      end
      break
    end
  end

  -- Run the test body
  local test_err
  if not before_err and not test.pending then
    local ok, err = guarded(test.fn)
    if not ok and err ~= busted.PENDING_SENTINEL then
      test_err = err
    end
  end

  -- Run after_each hooks (inner -> outer). Always run, even on failure.
  local after_errs = {}
  for _, hook in ipairs(busted.hooks_for(test, "after_each")) do
    local ok, err = guarded(hook)
    if not ok then
      table.insert(after_errs, err)
    end
  end
  busted.set_current(nil)

  local duration_ms = hrtime_ms() - test_start

  -- Compose result
  if before_err then
    local msg = "[before_each] " .. tostring(before_err)
    if #after_errs > 0 then
      msg = msg .. "\n[after_each] " .. table.concat(after_errs, "\n[after_each] ")
    end
    reporter.print_test(desc, test.name, "fail", msg, duration_ms)
    return "fail"
  end

  if test.pending and #after_errs == 0 then
    -- pending() was called during setup or inside the running body
    reporter.print_test(desc, test.name, "pending", test.pending_msg)
    return "pending"
  end

  if test_err then
    local msg = tostring(test_err)
    if #after_errs > 0 then
      msg = msg .. "\n[after_each] " .. table.concat(after_errs, "\n[after_each] ")
    end
    reporter.print_test(desc, test.name, "fail", msg, duration_ms)
    return "fail"
  end

  if #after_errs > 0 then
    reporter.print_test(desc, test.name, "fail",
      "[after_each] " .. table.concat(after_errs, "\n[after_each] "), duration_ms)
    return "fail"
  end

  reporter.print_test(desc, test.name, "pass", nil, duration_ms)
  return "pass"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run a single spec file. Returns (ok, counts) where counts is a table with
-- `pass`, `fail`, `pending`.
function M.run_file(spec_file)
  busted.reset()

  reporter.print_header(spec_file)

  local total_start = hrtime_ms()

  -- Load the spec; this triggers describe/it registration.
  local load_ok, load_err = xpcall(function()
    return dofile(spec_file)
  end, function(e)
    return debug.traceback(tostring(e), 2)
  end)

  if not load_ok then
    reporter.print_load_error(spec_file, load_err)
    return false, { pass = 0, fail = 1, pending = 0 }
  end

  local counts = { pass = 0, fail = 0, pending = 0 }
  for _, test in ipairs(busted.get_tests()) do
    local status = run_test(test)
    counts[status] = counts[status] + 1
  end

  local total_ms = hrtime_ms() - total_start
  reporter.print_summary(spec_file, counts.pass, counts.fail, counts.pending, total_ms)

  return counts.fail == 0, counts
end

--- Convenience entry point used by the shell scripts:
--- runs the file and exits Neovim with the appropriate exit code.
function M.run_and_exit(spec_file)
  local ok = M.run_file(spec_file)
  if ok then
    vim.cmd("qa!")
  else
    vim.cmd("cq 1")
  end
end

return M
