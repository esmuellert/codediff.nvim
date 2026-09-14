local protocol = require("codediff.core.watcher.protocol")

describe("watcher JSONL protocol", function()
  it("reassembles fragmented ready and refresh messages", function()
    local ready
    local refreshes = {}
    local errors = {}
    local decoder = protocol.new({
      on_ready = function(message)
        ready = message
      end,
      on_refresh = function(message)
        refreshes[#refreshes + 1] = message
      end,
      on_error = function(message)
        errors[#errors + 1] = message
      end,
    })

    decoder.feed('{"type":"rea')
    decoder.feed('dy","protocol":1,"binary_version":"0.23.2"}\r\n{"type":"refresh","worktree":true,')
    decoder.feed('"index":false,"head":false,"refs":false}\n')

    assert.equals("0.23.2", ready.binary_version)
    assert.equals(1, #refreshes)
    assert.is_true(refreshes[1].worktree)
    assert.equals(0, #errors)
    assert.is_true(decoder.is_ready())
  end)

  it("rejects a refresh before ready", function()
    local err
    local decoder = protocol.new({
      on_error = function(message)
        err = message
      end,
    })

    decoder.feed('{"type":"refresh","worktree":true,"index":false,"head":false,"refs":false}\n')

    assert.equals("watcher did not start with a protocol 1 ready message", err)
    assert.is_true(decoder.has_failed())
  end)

  it("rejects non-boolean refresh fields", function()
    local err
    local decoder = protocol.new({
      on_error = function(message)
        err = message
      end,
    })

    decoder.feed('{"type":"ready","protocol":1,"binary_version":"0.23.2"}\n')
    decoder.feed('{"type":"refresh","worktree":1,"index":false,"head":false,"refs":false}\n')

    assert.equals("watcher refresh fields must be boolean", err)
  end)

  it("rejects logs mixed into stdout", function()
    local err
    local decoder = protocol.new({
      on_error = function(message)
        err = message
      end,
    })

    decoder.feed("watcher started\n")

    assert.equals("watcher wrote invalid JSON", err)
  end)

  it("rejects an oversized complete line", function()
    local err
    local decoder = protocol.new({
      on_error = function(message)
        err = message
      end,
    })

    decoder.feed(string.rep("x", 64 * 1024 + 1) .. "\n")

    assert.equals("watcher protocol line exceeded 64 KiB", err)
  end)

  it("rejects an incomplete final line", function()
    local err
    local decoder = protocol.new({
      on_error = function(message)
        err = message
      end,
    })

    decoder.feed('{"type":"ready"')
    decoder.finish()

    assert.equals("watcher stdout ended with an incomplete protocol line", err)
  end)
end)
