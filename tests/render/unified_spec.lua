local render = require("codediff.ui.unified.render")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

describe("Unified Renderer", function()
  before_each(function()
    highlights.setup()
  end)

  it("Formats simple insertion", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"line 1", "line 2"}
    local modified = {"line 1", "line 2", "line 3"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    assert.is_true(#lines > 0, "Buffer should have lines")
    assert.is_true(lines[1]:match("^@@"), "First line should be hunk header")

    local has_insertion = false
    for _, line in ipairs(lines) do
      if line:match("^%+line 3") then
        has_insertion = true
        break
      end
    end
    assert.is_true(has_insertion, "Should have +line 3")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Formats simple deletion", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"line 1", "line 2", "line 3"}
    local modified = {"line 1", "line 2"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local has_deletion = false
    for _, line in ipairs(lines) do
      if line:match("^%-line 3") then
        has_deletion = true
        break
      end
    end
    assert.is_true(has_deletion, "Should have -line 3")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Applies line-level highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"line 1"}
    local modified = {"line 2"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {})
    assert.is_true(#marks > 0, "Should have highlight extmarks")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Applies character-level highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"The quick brown fox"}
    local modified = {"The quick red fox"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns_highlight, 0, -1, {details = true})

    local has_char_highlights = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details and (details.hl_group == "CodeDiffCharDelete" or details.hl_group == "CodeDiffCharInsert") then
        has_char_highlights = true
        break
      end
    end
    assert.is_true(has_char_highlights, "Should have character-level highlights")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Includes context lines", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"ctx1", "ctx2", "old", "ctx3", "ctx4"}
    local modified = {"ctx1", "ctx2", "new", "ctx3", "ctx4"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 2})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local has_context = false
    for _, line in ipairs(lines) do
      if line:match("^ ctx1") or line:match("^ ctx2") then
        has_context = true
        break
      end
    end
    assert.is_true(has_context, "Should have context lines with leading space")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Formats hunk header correctly", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"line 1", "line 2"}
    local modified = {"line 1", "new line", "line 2"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_true(lines[1]:match("^@@ %-"), "Hunk header should start with @@")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Handles UTF-8 multibyte characters", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"hello 世界"}
    local modified = {"hello world"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_true(#lines > 0, "Should render UTF-8 content")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Handles empty diff", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {"line 1", "line 2"}

    local diff_result = diff.compute_diff(lines, lines)
    render.render(buf, lines, lines, diff_result, {context = 3})

    local rendered_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equal(0, #rendered_lines, "Empty diff should produce no output")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)

  it("Handles multiple hunks", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local original = {"a", "b", "c", "x", "y", "z"}
    local modified = {"a", "B", "c", "x", "Y", "z"}

    local diff_result = diff.compute_diff(original, modified)
    render.render(buf, original, modified, diff_result, {context = 0})

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local hunk_count = 0
    for _, line in ipairs(lines) do
      if line:match("^@@") then
        hunk_count = hunk_count + 1
      end
    end
    assert.is_true(hunk_count >= 2, "Should have multiple hunk headers")

    vim.api.nvim_buf_delete(buf, {force = true})
  end)
end)
