-- File history panel module
-- Public API for file history feature
local M = {}

local render = require("codediff.ui.history.render")

-- Create file history panel
-- commits: array of commit objects from git.get_commit_list
-- git_root: absolute path to git repository root
-- tabpage: tabpage handle
-- width: optional width override
-- opts: { range, path, ... } original options
M.create = render.create

-- Navigation (files within expanded commits)
M.navigate_next = render.navigate_next
M.navigate_prev = render.navigate_prev

-- Navigation (commits in single-file mode)
M.navigate_next_commit = render.navigate_next_commit
M.navigate_prev_commit = render.navigate_prev_commit

-- Toggle visibility
M.toggle_visibility = render.toggle_visibility

-- Get all files (for external navigation)
M.get_all_files = render.get_all_files

return M
