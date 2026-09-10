-- Render precomputed conflict markers in the native signcolumn.
local M = {}

--- Render the real-line markers from one or more buffer projections.
function M.render(bufnr, projections, namespace)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, projection in ipairs(projections or {}) do
    for line, offsets in pairs(projection.markers or {}) do
      local text = offsets[0]
      if text and line >= 1 then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, {
          sign_text = text,
          sign_hl_group = projection.highlight,
          priority = 50,
        })
      end
    end
  end
end

return M
