-- History list updates share the session controller with the selected diff.
local M = {}
local git = require("codediff.core.git")
local render = require("codediff.ui.history.render")

function M.setup_auto_refresh(history, tabpage)
  local refresh = require("codediff.ui.refresh")
  history.tabpage = tabpage
  local unbind = refresh.bind_panel(tabpage, history, function(done)
    M._refresh_once(history, done)
  end)
  history._cleanup_auto_refresh = unbind
  return unbind
end

function M._refresh_once(history, done)
  done = done or function() end
  local lifecycle = require("codediff.ui.lifecycle")
  local function valid()
    return lifecycle.get_panel_view(history.tabpage) == history and vim.api.nvim_buf_is_valid(history.bufnr)
  end
  if not valid() then
    done()
    return
  end
  local expanded = {}
  for _, node in ipairs(history.tree:get_nodes() or {}) do
    if node.data and node.data.type == "commit" and node:is_expanded() then
      expanded[node.data.hash] = true
    end
  end
  local opts = { no_merges = true, path = history.opts.file_path }
  local range = history.opts.range or ""
  if range == "" then
    opts.limit = 100
  end
  git.get_commit_list(range, history.git_root, opts, function(err, commits)
    vim.schedule(function()
      if not valid() then
        done()
        return
      end
      if err then
        done(err)
        return
      end
      if vim.deep_equal(commits, history.commits) then
        done()
        return
      end
      history.commits = commits
      history.tree:set_nodes(render.build_tree_nodes(commits, history.git_root, history.opts))
      local remaining = 1
      local function loaded()
        remaining = remaining - 1
        if remaining ~= 0 then
          return
        end
        if valid() and not history.is_hidden then
          history.tree:render()
          if history.winid and vim.api.nvim_win_is_valid(history.winid) then
            for _, node in ipairs(history.tree:get_nodes()) do
              if node.data and node.data.hash == history.current_commit and node._line then
                vim.api.nvim_win_set_cursor(history.winid, { node._line, 0 })
                break
              end
            end
          end
        end
        done()
      end
      for _, node in ipairs(history.tree:get_nodes()) do
        if node.data and node.data.type == "commit" and expanded[node.data.hash] and history._load_commit_files then
          remaining = remaining + 1
          history._load_commit_files(node, loaded)
        end
      end
      loaded()
    end)
  end)
end

function M.refresh(history)
  require("codediff.ui.refresh").request(history.tabpage, { full = true })
end

return M
