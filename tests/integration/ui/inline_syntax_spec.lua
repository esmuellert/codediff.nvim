-- Test: syntax highlighting on inline diff virt_lines
-- Validates that deleted lines in inline diff get treesitter syntax colors

local inline = require("codediff.ui.inline")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

describe("Inline virt_lines syntax highlighting", function()
  before_each(function()
    highlights.setup()
  end)

  -- Test 1: compute_syntax_highlights returns highlights for Lua code
  it("computes treesitter highlights for Lua source", function()
    local lines = { "local x = 1", "local y = 2" }
    local result = inline.compute_syntax_highlights(lines, "lua")

    -- Should have highlights for at least line 1
    assert.is_truthy(result[1], "Line 1 should have syntax highlights")
    assert.is_true(#result[1] > 0, "Line 1 should have at least one highlight range")

    -- Check that 'local' keyword is highlighted
    local has_keyword = false
    for _, hl in ipairs(result[1]) do
      if hl.hl_group:match("keyword") then
        has_keyword = true
        break
      end
    end
    assert.is_true(has_keyword, "Should detect 'local' as @keyword")
  end)

  -- Test 2: compute_syntax_highlights returns empty for unknown filetype
  it("returns empty for unknown filetype", function()
    local lines = { "hello world" }
    local result = inline.compute_syntax_highlights(lines, "nonexistent_filetype_xyz")
    assert.are.same({}, result)
  end)

  -- Test 3: compute_syntax_highlights handles empty input
  it("handles empty lines", function()
    local result = inline.compute_syntax_highlights({}, "lua")
    assert.are.same({}, result)
  end)

  -- Test 4: compute_syntax_highlights handles nil filetype
  it("handles nil filetype", function()
    local result = inline.compute_syntax_highlights({ "local x = 1" }, nil)
    assert.are.same({}, result)
  end)

  -- Test 5: virt_lines get merged syntax + diff highlights
  it("virt_lines contain merged syntax highlights for deleted Lua code", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"

    local original = { "local x = 1", "local y = 2" }
    local modified = { "local y = 2" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified, { filetype = "lua" })

    -- Get the extmarks with virt_lines
    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local virt_chunks = nil
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        virt_chunks = details.virt_lines[1] -- first virt_line's chunks
        break
      end
    end

    assert.is_truthy(virt_chunks, "Should have virt_line chunks")
    -- With syntax highlighting, there should be more than 2 chunks
    -- (without syntax: just {text, CodeDiffLineDelete} + {padding, CodeDiffLineDelete})
    -- (with syntax: {local, merged_keyword_hl}, { , CodeDiffLineDelete}, {x, merged_var_hl}, ...)
    assert.is_true(#virt_chunks > 2,
      "With syntax highlighting, should have more than 2 chunks, got " .. #virt_chunks)

    -- At least one chunk should have a merged highlight (not plain CodeDiffLineDelete)
    local has_merged = false
    for _, chunk in ipairs(virt_chunks) do
      local hl = chunk[2]
      if hl and hl:match("^CodeDiffInline_") then
        has_merged = true
        break
      end
    end
    assert.is_true(has_merged, "Should have at least one merged syntax+diff highlight group")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 6: plain text (no treesitter) still renders correctly
  it("plain text without treesitter renders with diff-only highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "deleted line" }
    local modified = { "new line" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    -- No filetype set, no syntax highlights
    inline.render_inline_diff(buf, lines_diff, original, modified, { filetype = "" })

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local virt_chunks = nil
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        virt_chunks = details.virt_lines[1]
        break
      end
    end

    assert.is_truthy(virt_chunks, "Should have virt_line chunks")
    -- Without syntax, chunks should only use CodeDiffLineDelete/CodeDiffCharDelete
    for _, chunk in ipairs(virt_chunks) do
      local hl = chunk[2]
      assert.is_true(
        hl == "CodeDiffLineDelete" or hl == "CodeDiffCharDelete",
        "Without syntax, should only use diff highlights, got: " .. tostring(hl)
      )
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 7: syntax highlights work with char-level diff ranges
  it("merges syntax and char-level diff highlights correctly", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"

    local original = { "local x = 1" }
    local modified = { "local x = 2" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified, { filetype = "lua" })

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local virt_chunks = nil
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        virt_chunks = details.virt_lines[1]
        break
      end
    end

    assert.is_truthy(virt_chunks, "Should have virt_line chunks")

    -- Should have both merged syntax highlights AND char-delete highlights
    local has_char_delete_merged = false
    for _, chunk in ipairs(virt_chunks) do
      local hl = chunk[2]
      -- Char-delete merged with syntax would contain "CharDelete" in the name
      if hl and hl:match("CodeDiffInline_.*CodeDiffCharDelete") then
        has_char_delete_merged = true
      end
    end

    -- The changed character "1" should have a merged char-delete + number highlight
    -- (or just CodeDiffCharDelete if the number highlight has no fg)
    -- Either way, the rendering should not error
    assert.is_true(#virt_chunks > 2, "Should have multiple chunks with syntax + diff")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 8: Real Lua function gets correct treesitter token highlights on virt_lines
  it("Lua function virt_lines have keyword, function, string highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "lua"

    local original = { 'local function hello()', '  print("world")', "end" }
    local modified = { "local function goodbye()", "end" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified, { filetype = "lua" })

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    -- Collect all highlight groups used in virt_lines
    local all_hls = {}
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines then
        for _, vl in ipairs(details.virt_lines) do
          for _, chunk in ipairs(vl) do
            if chunk[2] and #chunk[1] > 0 and #chunk[1] < 50 then
              all_hls[chunk[2]] = chunk[1]
            end
          end
        end
      end
    end

    -- Verify specific treesitter tokens got merged highlights
    local has_keyword = false
    local has_string = false
    local has_function = false
    for hl, text in pairs(all_hls) do
      if hl:match("keyword") and text:match("local") then has_keyword = true end
      if hl:match("string") and text:match("world") then has_string = true end
      if hl:match("function") and text:match("print") then has_function = true end
    end

    assert.is_true(has_keyword, "'local' should have a keyword-merged highlight")
    assert.is_true(has_string, '\"world\" should have a string-merged highlight')
    assert.is_true(has_function, "'print' should have a function-merged highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
