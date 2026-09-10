-- Render module facade
local M = {}

local highlights = require("codediff.ui.highlights")
local view = require("codediff.ui.view")
local core = require("codediff.ui.core")
local lifecycle = require("codediff.ui.lifecycle")

-- Public functions
M.setup_highlights = highlights.setup
M.create_diff_view = view.create
M.update_diff_view = view.update
M.render_diff = core.render_diff

-- lifecycle.setup() is called on first view.create() via a once-guard,
-- so autocmds are only registered when actually needed.

return M
