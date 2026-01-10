-- Shared deprecation warning utility for vscode-diff compatibility shims
local M = {}

local warned = {}

--- Show deprecation warning (once per module)
---@param old_module string The old module path
---@param new_module string The new module path
function M.warn(old_module, new_module)
  if warned[old_module] then
    return
  end
  warned[old_module] = true

  vim.schedule(function()
    vim.notify(string.format("[CodeDiff] '%s' is deprecated. Please use '%s' instead.", old_module, new_module), vim.log.levels.WARN, { title = "CodeDiff" })
  end)
end

return M
