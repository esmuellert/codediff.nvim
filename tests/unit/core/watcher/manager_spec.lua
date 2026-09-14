describe("watcher repository manager", function()
  local original_install
  local original_process
  local original_manager

  before_each(function()
    original_install = package.loaded["codediff.core.installer.watcher"]
    original_process = package.loaded["codediff.core.watcher.process"]
    original_manager = package.loaded["codediff.core.watcher"]
  end)

  after_each(function()
    package.loaded["codediff.core.installer.watcher"] = original_install
    package.loaded["codediff.core.watcher.process"] = original_process
    package.loaded["codediff.core.watcher"] = original_manager
  end)

  local function load_manager(options)
    local starts = {}
    local stops = 0
    package.loaded["codediff.core.installer.watcher"] = {
      ensure = function(callback)
        callback(options.binary, options.install_error)
      end,
    }
    package.loaded["codediff.core.watcher.process"] = {
      start = function(_, repository, handlers)
        starts[#starts + 1] = { repository = repository, handlers = handlers }
        if options.start_error then
          return nil, options.start_error
        end
        return {
          stop = function()
            stops = stops + 1
          end,
        }
      end,
    }
    package.loaded["codediff.core.watcher"] = nil
    return require("codediff.core.watcher"), starts, function()
      return stops
    end
  end

  it("shares one process between subscribers for the same repository", function()
    local manager, starts, stop_count = load_manager({ binary = "/watcher" })
    local first_refreshes = 0
    local second_refreshes = 0
    local first_ready = 0
    local second_ready = 0

    local unsubscribe_first = manager.subscribe("/repo", {
      on_ready = function()
        first_ready = first_ready + 1
      end,
      on_refresh = function()
        first_refreshes = first_refreshes + 1
      end,
    })
    local unsubscribe_second = manager.subscribe("/repo", {
      on_ready = function()
        second_ready = second_ready + 1
      end,
      on_refresh = function()
        second_refreshes = second_refreshes + 1
      end,
    })

    assert.equals(1, #starts)
    starts[1].handlers.on_ready({ type = "ready", protocol = 1 })
    starts[1].handlers.on_refresh({ type = "refresh", worktree = true })
    assert.equals(1, first_ready)
    assert.equals(1, second_ready)
    assert.equals(1, first_refreshes)
    assert.equals(1, second_refreshes)

    unsubscribe_first()
    assert.equals(0, stop_count())
    unsubscribe_second()
    assert.equals(1, stop_count())
  end)

  it("reports installation failure without retrying for each subscriber", function()
    local manager, starts = load_manager({ install_error = "download failed" })
    local errors = {}

    local unsubscribe_first = manager.subscribe("/repo", {
      on_error = function(message)
        errors[#errors + 1] = message
      end,
    })
    local unsubscribe_second = manager.subscribe("/repo", {
      on_error = function(message)
        errors[#errors + 1] = message
      end,
    })

    assert.equals(0, #starts)
    assert.same({ "download failed", "download failed" }, errors)
    unsubscribe_first()
    unsubscribe_second()
  end)

  it("stops every repository process when Neovim exits", function()
    local manager, starts, stop_count = load_manager({ binary = "/watcher" })
    manager.subscribe("/first", {})
    manager.subscribe("/second", {})

    assert.equals(2, #starts)
    manager.stop_all()
    assert.equals(2, stop_count())
  end)

  it("falls back for every subscriber when a running process fails", function()
    local manager, starts = load_manager({ binary = "/watcher" })
    local errors = 0
    local first = manager.subscribe("/repo", {
      on_error = function()
        errors = errors + 1
      end,
    })
    local second = manager.subscribe("/repo", {
      on_error = function()
        errors = errors + 1
      end,
    })

    starts[1].handlers.on_ready({ type = "ready", protocol = 1 })
    starts[1].handlers.on_error("process exited")

    assert.equals(2, errors)
    first()
    second()
  end)
end)
