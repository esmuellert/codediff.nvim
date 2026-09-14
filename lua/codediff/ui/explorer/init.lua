-- Git status explorer
-- Public API for explorer module
local M = {}

-- Import submodules
local render = require("codediff.ui.explorer.render")
local actions = require("codediff.ui.explorer.actions")

-- Delegate to render module
M.create = render.create
M.get_all_files = require("codediff.ui.explorer.tree").get_all_files

-- Delegate to actions module
M.navigate_next = actions.navigate_next
M.navigate_prev = actions.navigate_prev
M.toggle_visibility = actions.toggle_visibility
M.toggle_view_mode = actions.toggle_view_mode
M.toggle_stage_entry = actions.toggle_stage_entry
M.toggle_stage_file = actions.toggle_stage_file
M.toggle_staged_view = actions.toggle_staged_view
M.stage_all = actions.stage_all
M.unstage_all = actions.unstage_all
M.restore_entry = actions.restore_entry

return M
