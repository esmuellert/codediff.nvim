-- Version management - single source of truth for VERSION
local M = {}

-- Load VERSION once at module load time
-- Navigate from lua/vscode-diff/version.lua -> lua/vscode-diff/ -> lua/ -> plugin root
do
  local source = debug.getinfo(1).source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
  local version_file = plugin_root .. "/VERSION"
  local f = io.open(version_file, "r")
  if f then
    -- Read only the first line and trim whitespace
    local line = f:read("*line")
    f:close()
    if line then
      M.VERSION = line:match("^%s*(.-)%s*$")
    end
  end
end

return M
