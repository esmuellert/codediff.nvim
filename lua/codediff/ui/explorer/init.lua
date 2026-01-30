-- Git status explorer using nui.nvim
-- Public API for explorer module
local M = {}

-- Import submodules
local nodes = require("codediff.ui.explorer.nodes")
local tree_module = require("codediff.ui.explorer.tree")
local render = require("codediff.ui.explorer.render")
local refresh = require("codediff.ui.explorer.refresh")
local actions = require("codediff.ui.explorer.actions")
local keymaps = require("codediff.ui.explorer.keymaps")
-- filter is already standalone, no wiring needed

-- Wire up cross-module dependencies
tree_module._set_nodes_module(nodes)
render._set_nodes_module(nodes)
render._set_tree_module(tree_module)
render._set_refresh_module(refresh)
render._set_keymaps_module(keymaps)
refresh._set_tree_module(tree_module)
actions._set_refresh_module(refresh)
keymaps._set_actions_module(actions)
keymaps._set_refresh_module(refresh)
keymaps._set_render_module(render)

-- Delegate to render module
M.create = render.create

-- Delegate to refresh module
M.setup_auto_refresh = refresh.setup_auto_refresh
M.refresh = refresh.refresh

-- Delegate to actions module
M.navigate_next = actions.navigate_next
M.navigate_prev = actions.navigate_prev
M.toggle_visibility = actions.toggle_visibility
M.toggle_view_mode = actions.toggle_view_mode
M.stage_file = actions.stage_file
M.unstage_file = actions.unstage_file
M.discard_file = actions.discard_file
M.toggle_stage_entry = actions.toggle_stage_entry
M.toggle_stage_file = actions.toggle_stage_file
M.stage_all = actions.stage_all
M.unstage_all = actions.unstage_all
M.restore_entry = actions.restore_entry

return M
