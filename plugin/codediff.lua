-- Plugin entry point - auto-loaded by Neovim
if vim.g.loaded_codediff then
  return
end
vim.g.loaded_codediff = 1

local render = require("codediff.ui")
local commands = require("codediff.commands")
local virtual_file = require('codediff.core.virtual_file')
local git = require('codediff.core.git')

-- Setup virtual file scheme
virtual_file.setup()

-- Setup highlights
render.setup_highlights()

-- Re-apply highlights on ColorScheme change
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("CodeDiffHighlights", { clear = true }),
  callback = function()
    render.setup_highlights()
  end,
})

-- Cache for revision candidates (avoid repeated git calls during rapid completions)
local rev_cache = {
  candidates = nil,
  git_root = nil,
  timestamp = 0,
  ttl = 5,  -- Cache for 5 seconds
}

local function get_cached_rev_candidates(git_root)
  local now = vim.loop.now() / 1000  -- Convert to seconds
  if rev_cache.candidates
      and rev_cache.git_root == git_root
      and (now - rev_cache.timestamp) < rev_cache.ttl then
    return rev_cache.candidates
  end

  local candidates = git.get_rev_candidates(git_root)
  rev_cache.candidates = candidates
  rev_cache.git_root = git_root
  rev_cache.timestamp = now
  return candidates
end

-- Register user command with subcommand completion
local function complete_codediff(arg_lead, cmd_line, cursor_pos)
  local args = vim.split(cmd_line, "%s+", { trimempty = true })

  -- If no args or just ":CodeDiff", suggest subcommands and revisions
  if #args <= 1 then
    local candidates = vim.list_extend({}, commands.SUBCOMMANDS)
    local cwd = vim.fn.getcwd()
    local git_root = git.get_git_root_sync(cwd)
    local rev_candidates = get_cached_rev_candidates(git_root)
    return vim.list_extend(candidates, rev_candidates)
  end

  -- If first arg is "merge" or "file", complete with file paths
  local first_arg = args[2]
  if first_arg == "merge" or first_arg == "file" then
    return vim.fn.getcompletion(arg_lead, "file")
  end

  -- For revision arguments, suggest git refs filtered by arg_lead
  if #args == 2 and arg_lead ~= "" then
    local cwd = vim.fn.getcwd()
    local git_root = git.get_git_root_sync(cwd)
    local rev_candidates = get_cached_rev_candidates(git_root)
    local filtered = {}

    -- Check if user is typing a triple-dot pattern (e.g., "main...")
    local base_rev = arg_lead:match("^(.+)%.%.%.$")
    if base_rev then
      -- User typed "main...", suggest completing with refs or leave as-is
      for _, candidate in ipairs(rev_candidates) do
        table.insert(filtered, base_rev .. "..." .. candidate)
      end
      -- Also include the bare triple-dot (compares to working tree)
      table.insert(filtered, 1, arg_lead)
      return filtered
    end

    -- Normal completion: match refs and also suggest triple-dot variants
    for _, candidate in ipairs(rev_candidates) do
      if candidate:find(arg_lead, 1, true) == 1 then
        table.insert(filtered, candidate)
        -- Also suggest the merge-base variant
        table.insert(filtered, candidate .. "...")
      end
    end
    if #filtered > 0 then
      return filtered
    end
  end

  -- Otherwise default file completion
  return vim.fn.getcompletion(arg_lead, "file")
end

vim.api.nvim_create_user_command("CodeDiff", commands.vscode_diff, {
  nargs = "*",
  bang = true,
  complete = complete_codediff,
  desc = "VSCode-style diff view: :CodeDiff [<revision>] | merge <file> | file <revision> | install"
})
