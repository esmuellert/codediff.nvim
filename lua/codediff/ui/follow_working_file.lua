-- Follow file navigation in a bare revision/worktree comparison. Content
-- invalidations belong to ui.refresh; this changes the comparison itself.
local M = {}

function M.enable(tabpage, original_is_virtual, modified_is_virtual)
  if original_is_virtual == modified_is_virtual then
    return
  end
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(tabpage)
  if not session or session.panel then
    return
  end

  local working_side = original_is_virtual and "modified" or "original"
  local virtual_side = original_is_virtual and "original" or "modified"
  local pending_path
  local group = vim.api.nvim_create_augroup("codediff_working_sync_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(event)
      if lifecycle.get_session(tabpage) ~= session or session.refresh and session.refresh.applying then
        return
      end
      local win = session[working_side .. "_win"]
      if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= event.buf then
        return
      end
      if vim.bo[event.buf].buftype ~= "" then
        return
      end
      local path = require("codediff.core.path")
      local name = vim.api.nvim_buf_get_name(event.buf)
      local new_path = name ~= "" and path.make_ref(name, nil).absolute or ""
      if new_path == "" or new_path == pending_path or new_path == session[working_side].absolute then
        return
      end
      pending_path = new_path

      local refresh = require("codediff.ui.refresh")
      local generation = refresh.begin(tabpage)
      local requested = vim.deepcopy(session.source_revisions or {})
      requested[virtual_side] = requested[virtual_side] or session[virtual_side .. "_revision"]
      requested[working_side] = "WORKING"
      local revision = requested[virtual_side]
      local function current()
        return refresh.is_current(tabpage, session, generation) and pending_path == new_path
      end
      local function update(root, resolved)
        vim.schedule(function()
          if not current() then
            return
          end
          local target = path.make_ref(new_path, root)
          local options = {
            git_root = root,
            original = root and target or path.empty(),
            modified = root and target or path.empty(),
            source_revisions = requested,
          }
          options[working_side] = target
          options[virtual_side .. "_revision"] = resolved
          require("codediff.ui.view").update(tabpage, options)
        end)
      end

      local git = require("codediff.core.git")
      git.get_git_root(new_path, function(err, root)
        vim.schedule(function()
          if not current() then
            return
          end
          if err then
            update(nil, nil)
          elseif revision:match("^:[0-3]:?$") then
            update(root, revision)
          else
            -- A requested HEAD/branch is resolved in the destination repository,
            -- not replaced by the SHA from the file we just left.
            git.resolve_revision(revision, root, function(resolve_error, hash)
              vim.schedule(function()
                if not current() then
                  return
                end
                if resolve_error then
                  vim.notify(resolve_error, vim.log.levels.WARN)
                  refresh.ready(tabpage)
                else
                  update(root, hash)
                end
              end)
            end)
          end
        end)
      end)
    end,
  })
end

return M
