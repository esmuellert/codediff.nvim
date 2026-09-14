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
local keymaps = require("codediff.ui.lifecycle.keymaps")

-- Delegate to state module
M.clear_highlights = state.clear_buffer_highlights

-- Delegate to session module
M.create_session = session.create_session

-- Delegate to cleanup module
M.setup_autocmds = cleanup.setup_autocmds
M.cleanup = cleanup.cleanup
M.close = cleanup.close
M.cleanup_all = cleanup.cleanup_all
M.setup = cleanup.setup

-- Delegate all accessors (getters)
M.get_session = accessors.get_session
M.get_panel = accessors.get_panel
M.get_panel_name = accessors.get_panel_name
M.event_mode = accessors.event_mode
M.get_layout = accessors.get_layout
M.get_git_context = accessors.get_git_context
M.get_buffers = accessors.get_buffers
M.get_windows = accessors.get_windows
M.get_paths = accessors.get_paths
M.find_tabpage_by_buffer = accessors.find_tabpage_by_buffer
M.is_buffer_shared = accessors.is_buffer_shared
M.is_original_virtual = accessors.is_original_virtual
M.is_modified_virtual = accessors.is_modified_virtual
M.is_suspended = accessors.is_suspended
M.get_panel_view = accessors.get_panel_view
M.get_result_base_lines = accessors.get_result_base_lines
M.get_merge_base_lines = accessors.get_merge_base_lines
M.get_result = accessors.get_result
M.get_conflict_blocks = accessors.get_conflict_blocks
M.get_conflict_files = accessors.get_conflict_files
M.get_unsaved_conflict_files = accessors.get_unsaved_conflict_files

-- Delegate all accessors (setters)
M.update_suspended = accessors.update_suspended
M.update_layout = accessors.update_layout
M.update_merge = accessors.update_merge
M.update_diff_result = accessors.update_diff_result
M.update_changedtick = accessors.update_changedtick
M.update_mtime = accessors.update_mtime
M.update_paths = accessors.update_paths
M.update_buffers = accessors.update_buffers
M.update_git_root = accessors.update_git_root
M.update_revisions = accessors.update_revisions
M.set_panel_view = accessors.set_panel_view
M.set_result = accessors.set_result
M.set_result_base_lines = accessors.set_result_base_lines
M.set_merge_base_lines = accessors.set_merge_base_lines
M.set_conflict_blocks = accessors.set_conflict_blocks
M.track_conflict_file = accessors.track_conflict_file
M.confirm_close_with_unsaved = accessors.confirm_close_with_unsaved
M.set_tab_keymap = keymaps.set_tab_keymap
M.set_buf_keymap = keymaps.set_buf_keymap
M.del_buf_keymap = keymaps.del_buf_keymap
M.owns_keymap = keymaps.owns_keymap
M.documented_keymaps = keymaps.documented_keymaps
M.begin_keymap_scope = keymaps.begin_keymap_scope
M.end_keymap_scope = keymaps.end_keymap_scope
M.release_keymap_scope = keymaps.release_keymap_scope
M.detach_keymap_buffer = keymaps.detach_keymap_buffer
M.clear_tab_keymaps = keymaps.clear_tab_keymaps
M.restore_tab_keymaps = keymaps.restore_tab_keymaps
M.dispose_keymaps = keymaps.dispose_keymaps

return M
