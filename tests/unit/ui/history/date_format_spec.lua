-- Tests for history.date_format (#340).
-- The formatting itself is a small local dispatch in nodes.lua; we exercise it
-- through M.prepare_node on a synthetic commit node so we cover the real render
-- path a user sees, not a private helper.

local nodes = require("codediff.ui.history.nodes")
local config = require("codediff.config")

-- Fixed timestamp: 2025-01-16 00:00:00 UTC.
local FIXED_TS = 1737000000

local function make_commit_node(overrides)
  local data = {
    type = "commit",
    hash = "abcdef0123456789",
    short_hash = "abcdef01",
    author = "Jane Dev",
    date = FIXED_TS,
    date_relative = "6 months ago",
    subject = "fix: something",
    file_count = 1,
    insertions = 1,
    deletions = 0,
  }
  for k, v in pairs(overrides or {}) do
    data[k] = v
  end
  return {
    data = data,
    is_expanded = function()
      return false
    end,
  }
end

local function render_line(fmt, overrides)
  config.options.history.date_format = fmt
  local line = nodes.prepare_node(make_commit_node(overrides), 200, nil, nil, true)
  return line:content()
end

describe("history.date_format (#340)", function()
  local saved

  before_each(function()
    saved = config.options.history.date_format
  end)

  after_each(function()
    config.options.history.date_format = saved
  end)

  it("defaults to '%ar' (git's relative string)", function()
    assert.equals("%ar", config.defaults.history.date_format)
  end)

  it("'%ar' uses the pre-formatted relative string from git", function()
    local content = render_line("%ar")
    assert.is_not_nil(content:find("6 months ago", 1, true))
  end)

  it("'%ai' formats as ISO 8601", function()
    local content = render_line("%ai")
    assert.is_not_nil(content:find(os.date("%Y-%m-%d %H:%M:%S", FIXED_TS), 1, true))
  end)

  it("'%ad' formats as git's default author-date shape", function()
    local content = render_line("%ad")
    -- e.g. "Wed Jan 15 19:00:00 2025 -0500" — check the year is present.
    assert.is_not_nil(content:find(os.date("%Y", FIXED_TS), 1, true))
  end)

  it("arbitrary strftime string is passed through to os.date", function()
    local content = render_line("%Y/%m/%d")
    assert.is_not_nil(content:find(os.date("%Y/%m/%d", FIXED_TS), 1, true))
  end)

  it("falls back to the relative string when timestamp is missing", function()
    -- pairs() skips nil overrides; assign after the merge to actually clear it.
    config.options.history.date_format = "%ai"
    local node = make_commit_node()
    node.data.date = nil
    local content = nodes.prepare_node(node, 200, nil, nil, true)
    assert.is_not_nil(content:content():find("6 months ago", 1, true))
  end)
end)
