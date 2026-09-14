-- tests/framework/reporter.lua
--
-- Stdout reporter used by tests/framework/runner.lua. Prints one line per test
-- (with color prefix), a failure block with traceback when tests fail, and a
-- summary line per spec file.
--
-- It also owns the suite-level output used by tests/framework/supervisor.lua
-- (banner, per-spec block emission, aggregate summary) so that every byte the
-- test suite prints is formatted in exactly one place.

local M = {}

-- ---------------------------------------------------------------------------
-- Colors
-- ---------------------------------------------------------------------------

local function tty_supports_color()
  if vim.env.NO_COLOR and vim.env.NO_COLOR ~= "" then
    return false
  end
  if vim.env.CODEDIFF_TEST_NO_COLOR and vim.env.CODEDIFF_TEST_NO_COLOR ~= "" then
    return false
  end
  -- CI environments (GitHub Actions) render ANSI colors in logs.
  return true
end

local use_color = tty_supports_color()
local function color(s, code)
  if not use_color then
    return s
  end
  return "\27[" .. code .. "m" .. s .. "\27[0m"
end

local function red(s)
  return color(s, "31")
end
local function green(s)
  return color(s, "32")
end
local function yellow(s)
  return color(s, "33")
end
local function cyan(s)
  return color(s, "36")
end
local function dim(s)
  return color(s, "2")
end

-- ---------------------------------------------------------------------------
-- Output primitives
-- ---------------------------------------------------------------------------

local function write(line)
  -- Use io.write + "\n" so output is line-buffered and shows up in `nvim
  -- --headless` runs immediately (Neovim's `print` also works, but io.write
  -- integrates better with shell pipes on Windows).
  io.write(line, "\n")
end

local function indent(prefix, block)
  local out = {}
  for line in tostring(block):gmatch("([^\n]*)\n?") do
    if line ~= "" then
      table.insert(out, prefix .. line)
    end
  end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.print_header(spec_file)
  write(cyan("┌─ " .. spec_file))
end

--- Print one test's result.
-- @param names table describe-name chain (outermost first, may be empty)
-- @param test_name string
-- @param status "pass" | "fail" | "pending"
-- @param message string|nil  (failure traceback or pending reason)
-- @param duration_ms number|nil
function M.print_test(names, test_name, status, message, duration_ms)
  local prefix
  if status == "pass" then
    prefix = green("  ✓")
  elseif status == "fail" then
    prefix = red("  ✗")
  else
    prefix = yellow("  -")
  end

  local desc_str = ""
  if #names > 0 then
    desc_str = dim(table.concat(names, " › ") .. " › ")
  end

  local dur = ""
  if status == "pass" and duration_ms and duration_ms > 0 then
    dur = " " .. dim("(" .. duration_ms .. "ms)")
  end

  write(prefix .. " " .. desc_str .. test_name .. dur)

  if message and message ~= "" then
    write(indent("      " .. (status == "fail" and red("│ ") or yellow("│ ")), message))
  end
end

function M.print_summary(spec_file, pass, fail, pending, total_ms)
  local parts = {}
  table.insert(parts, green(pass .. " passed"))
  if fail > 0 then
    table.insert(parts, red(fail .. " failed"))
  else
    table.insert(parts, fail .. " failed")
  end
  if pending > 0 then
    table.insert(parts, yellow(pending .. " pending"))
  else
    table.insert(parts, pending .. " pending")
  end

  local prefix
  if fail > 0 then
    prefix = red("└─ FAIL ")
  elseif pass == 0 and pending == 0 then
    prefix = yellow("└─ EMPTY ")
  else
    prefix = green("└─ OK ")
  end

  write(prefix .. spec_file .. "  " .. table.concat(parts, ", ") .. dim("  (" .. total_ms .. "ms)"))
end

function M.print_load_error(spec_file, err)
  write(red("┌─ LOAD ERROR ") .. spec_file)
  write(indent("  " .. red("│ "), err))
  write(red("└─ FAIL ") .. spec_file)
end

-- ---------------------------------------------------------------------------
-- Suite-level output (used by tests/framework/supervisor.lua)
-- ---------------------------------------------------------------------------

local BOX_WIDTH = 62

--- Draw one `║ ... ║` row, padded to BOX_WIDTH by *display* width so that ANSI
--- color codes (which occupy zero columns) don't skew the border alignment.
local function box_row(text, plain)
  local pad = BOX_WIDTH - 1 - vim.fn.strdisplaywidth(plain or text)
  if pad < 0 then
    pad = 0
  end
  return "║ " .. text .. string.rep(" ", pad) .. "║"
end

local function box_top()
  return "╔" .. string.rep("═", BOX_WIDTH) .. "╗"
end
local function box_bottom()
  return "╚" .. string.rep("═", BOX_WIDTH) .. "╝"
end

--- Banner printed once, before any spec runs.
-- @param spec_count number
-- @param mode "parallel"|"sequential"
-- @param jobs number  concurrent workers (1 in sequential mode)
-- @param reason string|nil  why sequential mode was chosen
function M.print_suite_header(spec_count, mode, jobs, reason)
  write("")
  write(box_top())
  write(box_row("codediff.nvim Test Suite", "codediff.nvim Test Suite"))
  local detail
  if mode == "parallel" then
    detail = string.format("%d spec files, %d parallel workers", spec_count, jobs)
  else
    detail = string.format("%d spec files, sequential", spec_count)
    if reason then
      detail = detail .. " (" .. reason .. ")"
    end
  end
  write(box_row(dim(detail), detail))
  write(box_bottom())
  write("")
end

function M.print_spec_start(spec)
  write(cyan("▶ RUN ") .. spec)
  io.stdout:flush()
end

function M.print_running(active, now)
  local names = {}
  for spec, started in pairs(active) do
    names[#names + 1] = string.format("%s (%.0fs)", spec, (now - started) / 1e9)
  end
  if #names > 0 then
    table.sort(names)
    write(dim("… running: " .. table.concat(names, ", ")))
    io.stdout:flush()
  end
end

--- Emit one spec's captured output as a single contiguous block.
--
-- This is the whole anti-interleaving mechanism: a child's stdout is buffered
-- in full by the supervisor and handed here, so no other spec's output can
-- land in the middle of it. Child processes must therefore never share this
-- process's stdout.
--
-- Trailing newlines are normalized to exactly one: Neovim writes some messages
-- (e.g. `E211: File ... no longer available`) without a trailing newline, which
-- would otherwise glue the next block's header onto the last line.
--
-- stderr is appended after stdout because the two streams are captured
-- separately, so it lands after the block's `└─` footer. It is labelled with
-- the spec name, otherwise those incidental Neovim messages read as
-- unattributed noise sitting between two blocks.
-- @param spec string  spec path, used to label the stderr section
-- @param stdout string  captured child stdout (framework output)
-- @param stderr string|nil  captured child stderr (incidental Neovim messages)
function M.emit_block(spec, stdout, stderr)
  local chunk = stdout or ""
  if stderr and stderr ~= "" then
    local label = "── stderr from " .. spec .. " ──"
    chunk = chunk:gsub("\n*$", "\n") .. dim(label) .. "\n" .. stderr
  end
  chunk = chunk:gsub("\n*$", "")
  if chunk == "" then
    return
  end
  write(chunk)
end

--- Aggregate summary printed once, after every spec has finished.
-- @param results table  list of { spec, ok, timed_out }
-- @param total_ms number  wall-clock time for the whole suite
function M.print_suite_summary(results, total_ms)
  local failures = {}
  for _, r in ipairs(results) do
    if not r.ok then
      table.insert(failures, r)
    end
  end

  -- Deterministic regardless of completion order, so CI logs stay diffable.
  table.sort(failures, function(a, b)
    return a.spec < b.spec
  end)

  write("")
  if #failures > 0 then
    write(red("Failed spec files:"))
    for _, r in ipairs(failures) do
      write(red("  ✗ ") .. r.spec .. (r.timed_out and dim(" (timed out)") or ""))
    end
    write("")
  end

  local seconds = string.format("%.1fs", total_ms / 1000)
  write(box_top())
  if #results == 0 then
    -- An empty run is a failure, never a pass: it means discovery broke, which
    -- would otherwise silently disable the whole suite in CI.
    local plain = "✗ NO SPEC FILES FOUND"
    write(box_row(red(plain), plain))
  elseif #failures == 0 then
    local plain = string.format("✓ ALL TESTS PASSED  (%d spec files, %s)", #results, seconds)
    write(box_row(green(plain), plain))
  else
    local plain = string.format("✗ %d OF %d SPEC FILE(S) FAILED  (%s)", #failures, #results, seconds)
    write(box_row(red(plain), plain))
  end
  write(box_bottom())
  write("")
end

return M
