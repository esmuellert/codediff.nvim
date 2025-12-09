#!/usr/bin/env -S nvim --headless -l
-- Merge alignment CLI tool for comparison testing
-- Usage: nvim --headless -l scripts/merge_alignment_cli.lua <base> <input1> <input2>
--
-- Outputs JSON with:
-- - mapping_alignments: grouped change regions
-- - fillers: filler lines for left/right editors
-- - alignments: line alignment tuples per region

-- Add plugin to runtime path
local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
local plugin_root = script_dir:match("(.*/)[^/]+/$") or script_dir .. "../"
vim.opt.runtimepath:prepend(plugin_root)

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    io.stderr:write("Error: Cannot open file: " .. path .. "\n")
    os.exit(1)
  end
  local content = f:read("*all")
  f:close()
  -- Split into lines, handling both \n and \r\n
  local lines = {}
  for line in content:gmatch("([^\r\n]*)[\r\n]?") do
    table.insert(lines, line)
  end
  -- Remove last empty element if file ends with newline
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function main()
  local args = vim.v.argv or arg or {}
  
  -- Find our arguments (after -l script.lua)
  local file_args = {}
  local found_script = false
  for i, a in ipairs(args) do
    if found_script then
      table.insert(file_args, a)
    elseif a:match("merge_alignment_cli%.lua$") then
      found_script = true
    end
  end
  
  if #file_args < 3 then
    io.stderr:write("Usage: nvim --headless -l merge_alignment_cli.lua <base> <input1> <input2>\n")
    io.stderr:write("  base   - base version file\n")
    io.stderr:write("  input1 - left/current version file\n")
    io.stderr:write("  input2 - right/incoming version file\n")
    os.exit(1)
  end
  
  local base_path = file_args[1]
  local input1_path = file_args[2]
  local input2_path = file_args[3]
  
  -- Read files
  local base_lines = read_file(base_path)
  local input1_lines = read_file(input1_path)
  local input2_lines = read_file(input2_path)
  
  io.stderr:write(string.format("Base: %s (%d lines)\n", base_path, #base_lines))
  io.stderr:write(string.format("Input1 (current): %s (%d lines)\n", input1_path, #input1_lines))
  io.stderr:write(string.format("Input2 (incoming): %s (%d lines)\n", input2_path, #input2_lines))
  
  -- Load our diff module
  local ok, diff_module = pcall(require, "vscode-diff.diff")
  if not ok then
    io.stderr:write("Error loading diff module: " .. tostring(diff_module) .. "\n")
    os.exit(1)
  end
  
  -- Load merge alignment module
  local ok2, merge_alignment = pcall(require, "vscode-diff.render.merge_alignment")
  if not ok2 then
    io.stderr:write("Error loading merge_alignment module: " .. tostring(merge_alignment) .. "\n")
    os.exit(1)
  end
  
  -- Compute diffs: base -> input1 and base -> input2
  local diff1 = diff_module.compute_diff(base_lines, input1_lines, {})
  local diff2 = diff_module.compute_diff(base_lines, input2_lines, {})
  
  io.stderr:write(string.format("Diff base->input1: %d changes\n", #(diff1.changes or {})))
  io.stderr:write(string.format("Diff base->input2: %d changes\n", #(diff2.changes or {})))
  
  -- Compute merge fillers and conflicts
  local fillers_result, conflict_left, conflict_right = merge_alignment.compute_merge_fillers_and_conflicts(
    diff1, diff2, base_lines, input1_lines, input2_lines
  )
  
  -- Build output structure
  local output = {
    files = {
      base = { path = base_path, lines = #base_lines },
      input1 = { path = input1_path, lines = #input1_lines },
      input2 = { path = input2_path, lines = #input2_lines },
    },
    diffs = {
      base_to_input1 = {},
      base_to_input2 = {},
    },
    fillers = fillers_result,
    conflicts = {
      left_changes = {},
      right_changes = {},
    },
  }
  
  -- Convert diff changes to serializable format
  for _, c in ipairs(diff1.changes or {}) do
    local inner = {}
    for _, ic in ipairs(c.inner_changes or {}) do
      table.insert(inner, {
        original = { start_line = ic.original.start_line, start_col = ic.original.start_col, end_line = ic.original.end_line, end_col = ic.original.end_col },
        modified = { start_line = ic.modified.start_line, start_col = ic.modified.start_col, end_line = ic.modified.end_line, end_col = ic.modified.end_col },
      })
    end
    table.insert(output.diffs.base_to_input1, {
      original = { start_line = c.original.start_line, end_line = c.original.end_line },
      modified = { start_line = c.modified.start_line, end_line = c.modified.end_line },
      inner_changes = inner,
    })
  end
  
  for _, c in ipairs(diff2.changes or {}) do
    local inner = {}
    for _, ic in ipairs(c.inner_changes or {}) do
      table.insert(inner, {
        original = { start_line = ic.original.start_line, start_col = ic.original.start_col, end_line = ic.original.end_line, end_col = ic.original.end_col },
        modified = { start_line = ic.modified.start_line, start_col = ic.modified.start_col, end_line = ic.modified.end_line, end_col = ic.modified.end_col },
      })
    end
    table.insert(output.diffs.base_to_input2, {
      original = { start_line = c.original.start_line, end_line = c.original.end_line },
      modified = { start_line = c.modified.start_line, end_line = c.modified.end_line },
      inner_changes = inner,
    })
  end
  
  -- Convert conflict changes
  for _, c in ipairs(conflict_left or {}) do
    table.insert(output.conflicts.left_changes, {
      original = { start_line = c.original.start_line, end_line = c.original.end_line },
      modified = { start_line = c.modified.start_line, end_line = c.modified.end_line },
    })
  end
  
  for _, c in ipairs(conflict_right or {}) do
    table.insert(output.conflicts.right_changes, {
      original = { start_line = c.original.start_line, end_line = c.original.end_line },
      modified = { start_line = c.modified.start_line, end_line = c.modified.end_line },
    })
  end
  
  -- Output JSON
  io.stdout:write(vim.json.encode(output))
  io.stdout:write("\n")
  io.stdout:flush()
  
  vim.cmd("quit!")
end

main()
