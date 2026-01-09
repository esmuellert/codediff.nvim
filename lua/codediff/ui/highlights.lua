-- Highlight setup for diff rendering
local M = {}
local config = require('codediff.config')

-- Namespaces for highlights and fillers
M.ns_highlight = vim.api.nvim_create_namespace("codediff-highlight")
M.ns_filler = vim.api.nvim_create_namespace("codediff-filler")
M.ns_conflict = vim.api.nvim_create_namespace("codediff-conflict")

-- Helper function to adjust color brightness
local function adjust_brightness(color, factor)
  if not color then return nil end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256

  -- Apply factor and clamp to 0-255
  r = math.min(255, math.floor(r * factor))
  g = math.min(255, math.floor(g * factor))
  b = math.min(255, math.floor(b * factor))

  return r * 65536 + g * 256 + b
end

-- Resolve color from config value (supports highlight group name or direct color)
-- Returns a table suitable for nvim_set_hl (e.g., { bg = 0x2ea043 })
local function resolve_color(value, default_fallback)
  if not value then
    return { bg = default_fallback }
  end

  -- If it's a string, check if it's a hex color or highlight group name
  if type(value) == "string" then
    -- Check if it's a hex color (#RRGGBB or #RGB)
    if value:match("^#%x%x%x%x%x%x$") then
      -- #RRGGBB format
      local r = tonumber(value:sub(2, 3), 16)
      local g = tonumber(value:sub(4, 5), 16)
      local b = tonumber(value:sub(6, 7), 16)
      return { bg = r * 65536 + g * 256 + b }
    elseif value:match("^#%x%x%x$") then
      -- #RGB format - expand to #RRGGBB
      local r = tonumber(value:sub(2, 2), 16) * 17
      local g = tonumber(value:sub(3, 3), 16) * 17
      local b = tonumber(value:sub(4, 4), 16) * 17
      return { bg = r * 65536 + g * 256 + b }
    else
      -- Assume it's a highlight group name
      local hl = vim.api.nvim_get_hl(0, { name = value, link = false })
      return { bg = hl.bg or default_fallback }
    end
  elseif type(value) == "number" then
    -- Direct color number (e.g., 0x2ea043)
    return { bg = value }
  end

  return { bg = default_fallback }
end

-- Setup VSCode-style highlight groups
function M.setup()
  local opts = config.options.highlights

  -- Line-level highlights
  local line_insert_color = resolve_color(opts.line_insert, 0x1d3042)
  local line_delete_color = resolve_color(opts.line_delete, 0x351d2b)

  vim.api.nvim_set_hl(0, "CodeDiffLineInsert", {
    bg = line_insert_color.bg,
    default = true,
  })

  vim.api.nvim_set_hl(0, "CodeDiffLineDelete", {
    bg = line_delete_color.bg,
    default = true,
  })

  -- Character-level highlights: use explicit values if provided, otherwise derive from line highlights
  local char_insert_bg
  local char_delete_bg
  
  -- Auto-detect brightness based on background if not explicitly set
  local brightness = opts.char_brightness or (vim.o.background == "light" and 0.92 or 1.4)

  if opts.char_insert then
    -- Explicit char_insert provided - use it directly
    char_insert_bg = resolve_color(opts.char_insert, 0x2a4556).bg
  else
    -- Derive from line_insert with brightness adjustment
    char_insert_bg = adjust_brightness(line_insert_color.bg, brightness) or 0x2a4556
  end

  if opts.char_delete then
    -- Explicit char_delete provided - use it directly
    char_delete_bg = resolve_color(opts.char_delete, 0x4b2a3d).bg
  else
    -- Derive from line_delete with brightness adjustment
    char_delete_bg = adjust_brightness(line_delete_color.bg, brightness) or 0x4b2a3d
  end

  vim.api.nvim_set_hl(0, "CodeDiffCharInsert", {
    bg = char_insert_bg,
    default = true,
  })

  vim.api.nvim_set_hl(0, "CodeDiffCharDelete", {
    bg = char_delete_bg,
    default = true,
  })

  -- Filler lines (no highlight, inherits editor default background)
  vim.api.nvim_set_hl(0, "CodeDiffFiller", {
    fg = "#444444",  -- Subtle gray for the slash character
    default = true,
  })
  
  -- Explorer directory text (smaller and dimmed)
  vim.api.nvim_set_hl(0, "ExplorerDirectorySmall", {
    link = "Comment",
    default = true,
  })

  -- Explorer selected file
  vim.api.nvim_set_hl(0, "CodeDiffExplorerSelected", {
    link = "Visual",
    default = true,
  })

  -- Explorer indent markers (tree view)
  vim.api.nvim_set_hl(0, "NeoTreeIndentMarker", {
    link = "Comment",
    default = true,
  })

  -- Helper to check if a highlight group exists and has foreground color
  local function hl_exists(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl and (hl.fg or hl.foreground)
  end

  -- Helper to set conflict sign highlight with user config as priority 0
  -- @param hl_name string The highlight group name to set
  -- @param user_value string|nil User config value (highlight group or hex color)
  -- @param fallbacks table List of fallback highlight groups to try
  -- @param default_hex string Default hex color if all fallbacks fail
  local function set_conflict_sign_hl(hl_name, user_value, fallbacks, default_hex)
    -- Priority 0: User config
    if user_value then
      if user_value:match("^#%x%x%x%x%x%x$") then
        -- Hex color
        vim.api.nvim_set_hl(0, hl_name, { fg = user_value, default = true })
      else
        -- Highlight group name
        vim.api.nvim_set_hl(0, hl_name, { link = user_value, default = true })
      end
      return
    end

    -- Try fallback chain
    for _, fallback in ipairs(fallbacks) do
      if hl_exists(fallback) then
        vim.api.nvim_set_hl(0, hl_name, { link = fallback, default = true })
        return
      end
    end

    -- Final fallback: hardcoded hex
    vim.api.nvim_set_hl(0, hl_name, { fg = default_hex, default = true })
  end

  local hl_config = config.options.highlights

  -- Conflict sign in gutter (for merge view) - unresolved conflicts
  -- Fallback chain: user config -> DiagnosticSignWarn -> hardcoded orange
  set_conflict_sign_hl(
    "CodeDiffConflictSign",
    hl_config.conflict_sign,
    { "DiagnosticSignWarn" },
    "#f0883e"
  )

  -- Conflict sign in gutter (for merge view) - resolved conflicts (generic)
  -- Fallback chain: user config -> Comment -> hardcoded gray
  set_conflict_sign_hl(
    "CodeDiffConflictSignResolved",
    hl_config.conflict_sign_resolved,
    { "Comment" },
    "#6e7681"
  )

  -- Conflict sign for accepted side (green - this content was chosen)
  -- Fallback chain: user config -> GitSignsAdd -> DiagnosticSignOk -> hardcoded green
  set_conflict_sign_hl(
    "CodeDiffConflictSignAccepted",
    hl_config.conflict_sign_accepted,
    { "GitSignsAdd", "DiagnosticSignOk" },
    "#3fb950"
  )

  -- Conflict sign for rejected side (red - this content was not chosen)
  -- Fallback chain: user config -> GitSignsDelete -> DiagnosticSignError -> hardcoded red
  set_conflict_sign_hl(
    "CodeDiffConflictSignRejected",
    hl_config.conflict_sign_rejected,
    { "GitSignsDelete", "DiagnosticSignError" },
    "#f85149"
  )
end

return M
