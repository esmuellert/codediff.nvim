-- Buffer-edit entry points for the session refresh controller.
local M = {}

function M.trigger(bufnr)
  require("codediff.ui.refresh").buffer_changed(bufnr)
end

-- Resolution commands need their Result highlights updated synchronously.
function M.refresh_result_now(bufnr)
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = lifecycle.find_tabpage_by_buffer(bufnr)
  local session = tabpage and lifecycle.get_session(tabpage)
  if session and session.result_bufnr == bufnr then
    require("codediff.ui.refresh.apply").result(session)
  end
end

function M.sync_mutable_buffers(tabpage, done)
  require("codediff.ui.refresh").request(tabpage, { index = true }, done)
end

function M.cleanup_all()
  local refresh = require("codediff.ui.refresh")
  for tabpage in pairs(require("codediff.ui.lifecycle.session").get_active_diffs()) do
    refresh.dispose(tabpage)
  end
end

return M
