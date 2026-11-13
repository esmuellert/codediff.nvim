-- vscode-diff main API
local M = {}

-- Configuration setup
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local highlights = require("codediff.ui.highlights")
  highlights.setup()
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_hunk()
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_hunk()
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_file()
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_file()
end

return M
