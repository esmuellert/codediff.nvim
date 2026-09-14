-- tests/framework/supervisor.lua
--
-- Runs the whole spec suite from a single parent Neovim process.
--
-- Each spec file still executes in its own child `nvim --headless` process, so
-- process isolation is byte-for-byte what the old shell loop provided. What
-- changes is that the *parent* owns discovery, concurrency and output:
--
--   * Concurrency lives here, not in the shell, so `run_tests.sh` and
--     `run_tests.cmd` become identical thin wrappers and Windows gets the same
--     behavior as POSIX without needing `xargs -P` or GNU parallel.
--
--   * Output is grouped. Children never inherit this process's stdout; their
--     output is buffered in full and emitted as one contiguous block when they
--     exit (see reporter.emit_block). Letting N concurrent children share one
--     fd interleaves their output — block-wise, because stdout is fully
--     buffered when it is not a tty, and even line-wise, because Neovim writes
--     some messages without a trailing newline.
--
--   * Concurrency requires `vim.system()` (Neovim 0.10+). On older versions the
--     suite falls back to running the same children one at a time via
--     `vim.fn.system()`, which produces identical output, just slower.

local reporter = require("tests.framework.reporter")

local M = {}

-- `vim.uv` is 0.10+; `vim.loop` is the pre-0.10 spelling. Resolved here so the
-- sequential fallback below is actually reachable on the versions it targets.
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- Per-spec wall-clock budget. Deliberately generous: it exists to stop a hung
-- spec from hanging CI forever, not to police slow specs.
local DEFAULT_TIMEOUT_MS = 300000

local function env_number(name)
  local raw = vim.env[name]
  if not raw or raw == "" then
    return nil
  end
  local n = tonumber(raw)
  if not n or n < 1 then
    return nil
  end
  return math.floor(n)
end

--- Default worker count.
--
-- The suite is dominated by specs blocked in `vim.wait` on async git/render
-- work rather than by CPU, so oversubscribing cores measurably helps. Capped
-- so a many-core machine doesn't spawn dozens of Neovim processes.
local function default_jobs()
  local ok, cpus = pcall(function()
    return uv.available_parallelism()
  end)
  if not ok or type(cpus) ~= "number" or cpus < 1 then
    cpus = 2
  end
  return math.max(2, math.min(cpus * 2, 16))
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- Discover a test layer, directory or single spec as sorted repo-relative paths.
-- `nosuf = true` prevents 'wildignore' from silently hiding coverage.
function M.discover(target)
  local layers = { all = "tests", unit = "tests/unit", integration = "tests/integration", e2e = "tests/e2e" }
  if not target or target == "" then
    target = "all"
  end
  local dir = (layers[target] or target):gsub("\\", "/")
  local root = vim.fn.getcwd():gsub("\\", "/")
  local matches
  if vim.fn.filereadable(dir) == 1 then
    matches = dir:match("_spec%.lua$") and { dir } or {}
  else
    matches = vim.fn.globpath(dir, "**/*_spec.lua", true, true)
  end

  local specs = {}
  for _, path in ipairs(matches) do
    local norm = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
    -- Make absolute paths relative to the repo root so the log is readable and
    -- the child's loader resolves them from cwd.
    if norm:sub(1, #root + 1) == root .. "/" then
      norm = norm:sub(#root + 2)
    end
    table.insert(specs, norm)
  end

  table.sort(specs)
  return specs
end

-- ---------------------------------------------------------------------------
-- Child process
-- ---------------------------------------------------------------------------

--- Argument vector for the child that runs exactly one spec file.
-- Mirrors the invocation the shell loop used, so a spec sees the same
-- environment it always has.
local function child_argv(spec)
  return {
    vim.v.progpath,
    "--headless",
    "--noplugin",
    "-u",
    "tests/init.lua",
    "-c",
    string.format("lua require('tests.framework').run_and_exit(%q)", spec),
  }
end

-- `vim.system` reports a timed-out child as exit code 124 (it sends SIGTERM).
local TIMEOUT_EXIT_CODE = 124

-- ---------------------------------------------------------------------------
-- Execution strategies
-- ---------------------------------------------------------------------------

--- Parallel execution via a fixed-size worker pool (Neovim 0.10+).
--
-- A pull-based queue rather than a static split: whenever a worker finishes it
-- takes the next spec, so a slow spec never strands the remaining work and no
-- hand-maintained ordering is required.
local function run_parallel(specs, opts)
  local results = {}
  local next_index, emitted = 1, 0

  local function spawn_next()
    if next_index > #specs then
      return
    end
    local spec = specs[next_index]
    next_index = next_index + 1

    vim.system(child_argv(spec), { text = true, timeout = opts.timeout }, function(obj)
      -- Keep the pool saturated before doing anything else.
      spawn_next()
      -- Emission is deferred to the main loop: the whole block is written by a
      -- single writer, so blocks cannot interleave with each other.
      vim.schedule(function()
        reporter.emit_block(spec, obj.stdout, obj.stderr)
        table.insert(results, {
          spec = spec,
          ok = obj.code == 0,
          timed_out = obj.code == TIMEOUT_EXIT_CODE,
        })
        emitted = emitted + 1
      end)
    end)
  end

  for _ = 1, math.min(opts.jobs, #specs) do
    spawn_next()
  end

  -- Every child is bounded by `opts.timeout`, so this is a true upper bound.
  local cap = opts.timeout * math.ceil(#specs / opts.jobs) + 60000
  vim.wait(cap, function()
    return emitted >= #specs
  end, 20)

  return results
end

--- Sequential fallback for Neovim without `vim.system()` (pre-0.10).
--
-- Same child processes and the same grouped output, just one at a time.
-- `vim.fn.system()` is blocking and captures the child's output in full, so
-- interleaving is impossible here by construction.
local function run_sequential(specs)
  local results = {}
  for _, spec in ipairs(specs) do
    local out = vim.fn.system(child_argv(spec))
    local code = vim.v.shell_error
    reporter.emit_block(spec, out, nil)
    table.insert(results, { spec = spec, ok = code == 0, timed_out = false })
  end
  return results
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run every discovered spec file. Returns (ok, results).
-- @param opts table|nil { dir = layer|directory|spec, jobs, timeout }
function M.run(opts)
  opts = opts or {}
  local specs = M.discover(opts.dir or vim.env.CODEDIFF_TEST_TARGET)

  local timeout = opts.timeout or env_number("CODEDIFF_TEST_TIMEOUT") or DEFAULT_TIMEOUT_MS
  local jobs = opts.jobs or env_number("CODEDIFF_TEST_JOBS") or default_jobs()

  -- Concurrency needs vim.system(); without it we still run every spec, just
  -- serially, so an older Neovim loses speed but never coverage.
  local parallel = vim.system ~= nil and jobs > 1
  local reason
  if not parallel then
    reason = vim.system == nil and "vim.system() unavailable" or nil
  end

  reporter.print_suite_header(#specs, parallel and "parallel" or "sequential", jobs, reason)

  if #specs == 0 then
    -- Never report success for an empty run: it almost certainly means
    -- discovery broke, which would silently disable the suite in CI.
    reporter.print_suite_summary({}, 0)
    return false, {}
  end

  local started = uv.hrtime()
  local results
  if parallel then
    results = run_parallel(specs, { jobs = jobs, timeout = timeout })
  else
    results = run_sequential(specs)
  end
  local total_ms = math.floor((uv.hrtime() - started) / 1e6)

  -- A spec with no result never reported back (parent wait cap hit). Treat it
  -- as a failure rather than silently dropping it from the totals.
  local seen = {}
  for _, r in ipairs(results) do
    seen[r.spec] = true
  end
  for _, spec in ipairs(specs) do
    if not seen[spec] then
      table.insert(results, { spec = spec, ok = false, timed_out = true })
    end
  end

  reporter.print_suite_summary(results, total_ms)

  for _, r in ipairs(results) do
    if not r.ok then
      return false, results
    end
  end
  return true, results
end

--- Run every spec file and exit Neovim with the appropriate exit code.
--- Used by tests/run_tests.{sh,cmd}.
function M.run_and_exit(opts)
  local ok = M.run(opts)
  if ok then
    vim.cmd("qa!")
  else
    vim.cmd("cq 1")
  end
end

return M
