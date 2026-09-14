-- Tests for lua/codediff/ui/highlights.lua color resolution.
-- Specifically guards regression #366: highlight groups that use `fg + reverse`
-- (e.g. built-in `sorbet`) must be read as bg when populating CodeDiffLineInsert
-- / CodeDiffLineDelete, because Neovim's renderer swaps fg<->bg at draw time.

local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")

local function reset_codediff()
  -- Wipe any cached CodeDiff highlights so each test starts clean
  pcall(vim.api.nvim_set_hl, 0, "CodeDiffLineInsert", {})
  pcall(vim.api.nvim_set_hl, 0, "CodeDiffLineDelete", {})
  pcall(vim.api.nvim_set_hl, 0, "CodeDiffCharInsert", {})
  pcall(vim.api.nvim_set_hl, 0, "CodeDiffCharDelete", {})
  vim.cmd("highlight clear CodeDiffGutterInsert")
  vim.cmd("highlight clear CodeDiffGutterDelete")
  vim.cmd("highlight clear CodeDiffGutterInsertNumber")
  vim.cmd("highlight clear CodeDiffGutterDeleteNumber")
  config.options = vim.deepcopy(config.defaults)
  require("codediff").setup({})
end

describe("highlights.lua color derivation", function()
  before_each(reset_codediff)

  it("defines semantic explorer stat highlights", function()
    highlights.setup()

    local files = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerStatFiles", link = true })
    local insertions = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerStatInsertions", link = true })
    local deletions = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerStatDeletions", link = true })
    local binary = vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerStatBinary", link = true })
    assert.equals("Number", files.link)
    assert.is_true(insertions.link == "Added" or insertions.link == "DiagnosticOk")
    assert.is_true(deletions.link == "Removed" or deletions.link == "DiagnosticError")
    assert.equals("NonText", binary.link)
  end)

  it("reads bg directly for colorschemes that use bg-based diff highlights", function()
    -- Mimic the default convention: DiffAdd uses bg + (optional) fg, no reverse
    vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x123456 })
    vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x654321 })
    highlights.setup()

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false })
    local delete = vim.api.nvim_get_hl(0, { name = "CodeDiffLineDelete", link = false })
    assert.are.equal(0x123456, insert.bg, "Insert bg should come from DiffAdd.bg")
    assert.are.equal(0x654321, delete.bg, "Delete bg should come from DiffDelete.bg")
  end)

  it("reads fg when colorscheme uses fg + reverse (regression: #366 sorbet)", function()
    -- Mimic sorbet's pattern: fg holds the green/red color and reverse=true
    -- means Neovim renders it as a background at draw time.
    vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x00af5f, bg = 0x000000, reverse = true })
    vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0xd70000, bg = 0x000000, reverse = true })
    highlights.setup()

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false })
    local delete = vim.api.nvim_get_hl(0, { name = "CodeDiffLineDelete", link = false })
    assert.are.equal(0x00af5f, insert.bg, "Insert bg should come from DiffAdd.fg when reverse=true")
    assert.are.equal(0xd70000, delete.bg, "Delete bg should come from DiffDelete.fg when reverse=true")
  end)

  it("honors cterm.reverse independently of gui reverse", function()
    -- Some colorschemes set the reverse flag only on the cterm side.
    vim.api.nvim_set_hl(0, "DiffAdd", {
      bg = 0x123456,
      ctermfg = 35,
      ctermbg = 16,
      cterm = { reverse = true },
    })
    highlights.setup()

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false })
    assert.are.equal(0x123456, insert.bg, "GUI bg unaffected when only cterm reverses")
    assert.are.equal(35, insert.ctermbg, "Cterm bg should come from ctermfg under cterm.reverse")
  end)

  it("preserves character highlight foreground and styles", function()
    vim.api.nvim_set_hl(0, "TestCodeDiffCharInsert", {
      fg = 0xabcdef,
      bg = 0x123456,
      sp = 0xfedcba,
      bold = true,
      italic = true,
      undercurl = true,
      nocombine = true,
    })
    require("codediff").setup({ highlights = { char_insert = "TestCodeDiffCharInsert" } })

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    assert.are.equal(0xabcdef, insert.fg)
    assert.are.equal(0x123456, insert.bg)
    assert.are.equal(0xfedcba, insert.sp)
    assert.is_true(insert.bold)
    assert.is_true(insert.italic)
    assert.is_true(insert.undercurl)
    assert.is_true(insert.nocombine)
  end)

  it("keeps line highlights background-only when configured with a group", function()
    vim.api.nvim_set_hl(0, "TestCodeDiffLineInsert", {
      fg = 0xabcdef,
      bg = 0x123456,
      bold = true,
      nocombine = true,
    })
    require("codediff").setup({ highlights = { line_insert = "TestCodeDiffLineInsert" } })

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false })
    assert.are.equal(0x123456, insert.bg)
    assert.is_nil(insert.fg)
    assert.is_nil(insert.bold)
    assert.is_nil(insert.nocombine)
  end)

  it("keeps direct character colors background-only", function()
    require("codediff").setup({
      highlights = {
        char_insert = "#123456",
        char_delete = 52,
      },
    })

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    local delete = vim.api.nvim_get_hl(0, { name = "CodeDiffCharDelete", link = false })
    assert.are.equal(0x123456, insert.bg)
    assert.are.equal(28, insert.ctermbg)
    assert.is_nil(insert.fg)
    assert.are.equal(52, delete.bg)
    assert.are.equal(52, delete.ctermbg)
    assert.is_nil(delete.fg)
  end)

  it("normalizes reverse character colors while preserving styles", function()
    vim.api.nvim_set_hl(0, "TestCodeDiffReverseChar", {
      fg = 0x00af5f,
      bg = 0x101010,
      reverse = true,
      italic = true,
      nocombine = true,
    })
    require("codediff").setup({ highlights = { char_insert = "TestCodeDiffReverseChar" } })

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    assert.are.equal(0x00af5f, insert.bg)
    assert.are.equal(0x101010, insert.fg)
    assert.is_nil(insert.reverse)
    assert.is_true(insert.italic)
    assert.is_true(insert.nocombine)
  end)

  it("normalizes cterm reverse independently and preserves cterm styles", function()
    vim.api.nvim_set_hl(0, "TestCodeDiffCtermChar", {
      fg = 0xabcdef,
      bg = 0x123456,
      ctermfg = 35,
      ctermbg = 16,
      cterm = { reverse = true, bold = true },
    })
    require("codediff").setup({ highlights = { char_insert = "TestCodeDiffCtermChar" } })

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    assert.are.equal(0x123456, insert.bg)
    assert.are.equal(0xabcdef, insert.fg)
    assert.are.equal(35, insert.ctermbg)
    assert.are.equal(16, insert.ctermfg)
    assert.is_true(insert.cterm.bold)
    assert.is_nil(insert.cterm.reverse)
  end)

  it("keeps derived character highlights background-only", function()
    vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0xabcdef, bg = 0x102030, bold = true })
    highlights.setup()

    local insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    assert.are.equal(0x162c43, insert.bg)
    assert.are.equal(28, insert.ctermbg)
    assert.is_nil(insert.fg)
    assert.is_nil(insert.bold)
  end)

  it("defines stable gutter highlight defaults", function()
    highlights.setup()

    assert.equals("CodeDiffLineInsert", vim.api.nvim_get_hl(0, { name = "CodeDiffGutterInsert", link = true }).link)
    assert.equals("CodeDiffLineDelete", vim.api.nvim_get_hl(0, { name = "CodeDiffGutterDelete", link = true }).link)

    local char_insert = vim.api.nvim_get_hl(0, { name = "CodeDiffCharInsert", link = false })
    local char_delete = vim.api.nvim_get_hl(0, { name = "CodeDiffCharDelete", link = false })
    local number_insert = vim.api.nvim_get_hl(0, { name = "CodeDiffGutterInsertNumber", link = false })
    local number_delete = vim.api.nvim_get_hl(0, { name = "CodeDiffGutterDeleteNumber", link = false })
    assert.equals(char_insert.bg, number_insert.fg)
    assert.equals(char_insert.ctermbg, number_insert.ctermfg)
    assert.is_nil(number_insert.bg)
    assert.is_nil(number_insert.ctermbg)
    assert.equals(char_delete.bg, number_delete.fg)
    assert.equals(char_delete.ctermbg, number_delete.ctermfg)
    assert.is_nil(number_delete.bg)
    assert.is_nil(number_delete.ctermbg)
  end)

  it("preserves colorscheme gutter highlight overrides", function()
    vim.api.nvim_set_hl(0, "CodeDiffGutterInsert", { fg = 0x123456, bg = 0x654321 })
    vim.api.nvim_set_hl(0, "CodeDiffGutterInsertNumber", { bg = 0xabcdef })

    highlights.setup()

    local sign = vim.api.nvim_get_hl(0, { name = "CodeDiffGutterInsert", link = false })
    local number = vim.api.nvim_get_hl(0, { name = "CodeDiffGutterInsertNumber", link = false })
    assert.equals(0x123456, sign.fg)
    assert.equals(0x654321, sign.bg)
    assert.equals(0xabcdef, number.bg)
  end)

  it("re-derives on :colorscheme change", function()
    -- First setup: bg-based DiffAdd
    vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x111111 })
    highlights.setup()
    local before = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false }).bg
    assert.are.equal(0x111111, before)

    -- Switch convention by emitting a ColorScheme event with a new DiffAdd
    vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x222222, reverse = true })
    vim.cmd("doautocmd ColorScheme")

    local after = vim.api.nvim_get_hl(0, { name = "CodeDiffLineInsert", link = false }).bg
    assert.are.equal(0x222222, after, "ColorScheme autocmd should re-derive Insert bg from new DiffAdd")
  end)

  it("re-derives character group attributes on :colorscheme change", function()
    vim.api.nvim_set_hl(0, "TestCodeDiffColorSchemeChar", {
      fg = 0x111111,
      bg = 0x222222,
      bold = true,
    })
    require("codediff").setup({ highlights = { char_delete = "TestCodeDiffColorSchemeChar" } })

    vim.api.nvim_set_hl(0, "TestCodeDiffColorSchemeChar", {
      fg = 0x333333,
      bg = 0x444444,
      italic = true,
      nocombine = true,
    })
    vim.cmd("doautocmd ColorScheme")

    local delete = vim.api.nvim_get_hl(0, { name = "CodeDiffCharDelete", link = false })
    assert.are.equal(0x333333, delete.fg)
    assert.are.equal(0x444444, delete.bg)
    assert.is_nil(delete.bold)
    assert.is_true(delete.italic)
    assert.is_true(delete.nocombine)
  end)
end)
