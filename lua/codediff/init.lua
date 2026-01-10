-- vscode-diff main API
local M = {}

-- Configuration setup - the ONLY public API users need
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local render = require("codediff.ui")
  render.setup_highlights()
end

return M
