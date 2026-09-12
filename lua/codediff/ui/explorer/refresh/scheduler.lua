-- Explorer is a panel of the session refresh controller, not a second scheduler.
local M = {}

function M.setup(explorer, tabpage, refresh_once)
  local refresh = require("codediff.ui.refresh")
  local unbind = refresh.bind_panel(tabpage, explorer, function(done)
    refresh_once(explorer, done)
  end)
  explorer._request_refresh = function(event, done)
    refresh.request(tabpage, event, done)
  end
  explorer._request_auto_refresh = function(message)
    refresh.request(tabpage, message)
  end
  local function cleanup()
    unbind()
    explorer._request_refresh = nil
    explorer._request_auto_refresh = nil
    explorer._native_watcher_ready = nil
  end
  explorer._cleanup_auto_refresh = cleanup
  return cleanup
end

return M
