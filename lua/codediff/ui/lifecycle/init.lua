-- Lifecycle management for diff views
-- Handles tracking, cleanup, and state restoration
--
-- STATE MODEL (Consolidated):
-- - Single source of truth for all diff sessions
-- - Immutable: mode, git_root, bufnr, win, revisions
-- - Mutable: suspended, stored_diff_result, changedtick, mtime, paths
-- - Access: Only through getters/setters
local M = {}

-- Import submodules
local session = require("codediff.ui.lifecycle.session")
local state = require("codediff.ui.lifecycle.state")
local cleanup = require("codediff.ui.lifecycle.cleanup")
local accessors = require("codediff.ui.lifecycle.accessors")

-- Wire up cross-module dependencies
session._set_state_module(state)
state._set_session_module(session)
cleanup._set_session_module(session)
cleanup._set_state_module(state)
accessors._set_session_module(session)

-- Delegate to state module
M.clear_highlights = state.clear_buffer_highlights

-- Delegate to session module
M.create_session = session.create_session

-- Delegate to cleanup module
M.setup_autocmds = cleanup.setup_autocmds
M.cleanup = cleanup.cleanup
M.cleanup_all = cleanup.cleanup_all
M.setup = cleanup.setup

-- Delegate all accessors (getters)
M.get_session = accessors.get_session
M.get_mode = accessors.get_mode
M.get_git_context = accessors.get_git_context
M.get_buffers = accessors.get_buffers
M.get_windows = accessors.get_windows
M.get_paths = accessors.get_paths
M.find_tabpage_by_buffer = accessors.find_tabpage_by_buffer
M.is_original_virtual = accessors.is_original_virtual
M.is_modified_virtual = accessors.is_modified_virtual
M.is_suspended = accessors.is_suspended
M.get_explorer = accessors.get_explorer
M.get_result_base_lines = accessors.get_result_base_lines
M.get_result = accessors.get_result
M.get_conflict_blocks = accessors.get_conflict_blocks
M.get_conflict_files = accessors.get_conflict_files
M.get_unsaved_conflict_files = accessors.get_unsaved_conflict_files

-- Delegate all accessors (setters)
M.update_suspended = accessors.update_suspended
M.update_diff_result = accessors.update_diff_result
M.update_changedtick = accessors.update_changedtick
M.update_mtime = accessors.update_mtime
M.update_paths = accessors.update_paths
M.update_buffers = accessors.update_buffers
M.update_git_root = accessors.update_git_root
M.update_revisions = accessors.update_revisions
M.set_explorer = accessors.set_explorer
M.set_result = accessors.set_result
M.set_result_base_lines = accessors.set_result_base_lines
M.set_conflict_blocks = accessors.set_conflict_blocks
M.track_conflict_file = accessors.track_conflict_file
M.confirm_close_with_unsaved = accessors.confirm_close_with_unsaved
M.set_tab_keymap = accessors.set_tab_keymap
M.clear_tab_keymaps = accessors.clear_tab_keymaps
M.setup_auto_sync_on_file_switch = accessors.setup_auto_sync_on_file_switch

return M
