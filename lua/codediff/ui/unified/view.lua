local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local render = require("codediff.ui.unified.render")
local keymaps = require("codediff.ui.unified.keymaps")
local git = require("codediff.core.git")
local diff_module = require("codediff.core.diff")
local config = require("codediff.config")

---@param session_config SessionConfig
---@param filetype? string
---@param on_ready? function
function M.create(session_config, filetype, on_ready)
  vim.cmd("tabnew")

  local tabpage = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  if filetype and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end

  keymaps.setup(buf)

  local function load_and_render()
    local original_path = session_config.original_path
    local modified_path = session_config.modified_path
    local git_root = session_config.git_root
    local original_revision = session_config.original_revision
    local modified_revision = session_config.modified_revision

    local function render_content(original_lines, modified_lines)
      local diff_options = {
        max_computation_time_ms = config.options.diff.max_computation_time_ms,
      }
      local diff_result = diff_module.compute_diff(original_lines, modified_lines, diff_options)

      if not diff_result then
        vim.notify("Failed to compute diff", vim.log.levels.ERROR)
        return
      end

      local render_opts = {
        context = config.options.diff.unified_context or 3,
      }
      render.render(buf, original_lines, modified_lines, diff_result, render_opts)

      lifecycle.create_session(
        tabpage,
        "unified",
        git_root,
        original_path,
        modified_path,
        original_revision,
        modified_revision,
        buf,
        buf,
        win,
        win,
        diff_result,
        nil
      )

      if on_ready then
        on_ready(diff_result)
      end
    end

    local relative_path = original_path
    if git_root then
      relative_path = git.get_relative_path(original_path, git_root)
    end

    if original_revision == "WORKING" then
      local original_lines = vim.fn.readfile(original_path)
      if modified_revision == "WORKING" then
        local modified_lines = vim.fn.readfile(modified_path)
        render_content(original_lines, modified_lines)
      else
        git.get_file_content(modified_revision, git_root, relative_path, function(err, modified_lines)
          if err then
            vim.schedule(function()
              vim.notify(err, vim.log.levels.ERROR)
            end)
            return
          end
          vim.schedule(function()
            render_content(original_lines, modified_lines)
          end)
        end)
      end
    else
      git.get_file_content(original_revision, git_root, relative_path, function(err_orig, original_lines)
        if err_orig then
          vim.schedule(function()
            vim.notify(err_orig, vim.log.levels.ERROR)
          end)
          return
        end

        if modified_revision == "WORKING" then
          vim.schedule(function()
            local modified_lines = vim.fn.readfile(modified_path)
            render_content(original_lines, modified_lines)
          end)
        else
          git.get_file_content(modified_revision, git_root, relative_path, function(err_mod, modified_lines)
            if err_mod then
              vim.schedule(function()
                vim.notify(err_mod, vim.log.levels.ERROR)
              end)
              return
            end
            vim.schedule(function()
              render_content(original_lines, modified_lines)
            end)
          end)
        end
      end)
    end
  end

  load_and_render()
end

return M
