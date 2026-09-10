-- Conflict resolution actions for merge tool
-- Handles accept current/incoming/both/none actions
local M = {}

-- Import submodules
local tracking = require("codediff.ui.conflict.tracking")
local gutter = require("codediff.ui.conflict.gutter")
local resolution = require("codediff.ui.conflict.resolution")
local navigation = require("codediff.ui.conflict.navigation")
local keymaps = require("codediff.ui.conflict.keymaps")

-- Delegate to tracking module
M.run_repeatable_action = tracking.run_repeatable_action
M.initialize_tracking = tracking.initialize_tracking

-- Delegate to the conflict renderer
M.refresh = gutter.refresh
M.setup_refresh_autocmd = gutter.setup_refresh_autocmd
M.attach_gutter = gutter.attach
M.detach_gutter = gutter.detach
M.teardown_gutter = gutter.teardown

-- Delegate to resolution module
M.accept_incoming = resolution.accept_incoming
M.accept_current = resolution.accept_current
M.accept_both = resolution.accept_both
M.discard = resolution.discard
M.accept_all_incoming = resolution.accept_all_incoming
M.accept_all_current = resolution.accept_all_current
M.accept_all_both = resolution.accept_all_both
M.discard_all = resolution.discard_all
M.diffget_incoming = resolution.diffget_incoming
M.diffget_current = resolution.diffget_current

-- Delegate to navigation module
M.navigate_next_conflict = navigation.navigate_next_conflict
M.navigate_prev_conflict = navigation.navigate_prev_conflict

-- Delegate to keymaps module
M.setup_keymaps = keymaps.setup_keymaps

return M
