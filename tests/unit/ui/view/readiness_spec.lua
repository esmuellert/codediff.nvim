-- Waiting for both sides of a diff to arrive. This bookkeeping used to be
-- written out at three call sites, one of which keyed by buffer number and so
-- counted a single arrival twice when both sides shared a buffer.

local readiness = require("codediff.ui.view.readiness")

describe("readiness.when_all", function()
  it("waits for every side before running", function()
    local runs = 0
    local ready = readiness.when_all({ "original", "modified" }, function()
      runs = runs + 1
    end)

    assert.equals(0, runs, "must not run before any side arrives")
    assert.is_true(ready.pending())

    ready.done("original")
    assert.equals(0, runs, "must not run with one side outstanding")
    assert.is_true(ready.pending())

    ready.done("modified")
    assert.equals(1, runs, "must run once the last side arrives")
    assert.is_false(ready.pending())
  end)

  it("runs immediately when there is nothing to wait for", function()
    local runs = 0
    local ready = readiness.when_all({}, function()
      runs = runs + 1
    end)

    assert.equals(1, runs)
    assert.is_false(ready.pending())
  end)

  it("runs once even if a side is reported twice", function()
    local runs = 0
    local ready = readiness.when_all({ "original", "modified" }, function()
      runs = runs + 1
    end)

    ready.done("original")
    ready.done("original")
    ready.done("modified")
    ready.done("modified")

    assert.equals(1, runs, "a repeated arrival must not render again")
  end)

  it("ignores sides it was never asked to wait for", function()
    local runs = 0
    local ready = readiness.when_all({ "modified" }, function()
      runs = runs + 1
    end)

    ready.done("original")
    assert.equals(0, runs, "an unawaited side must not satisfy the wait")

    ready.done("modified")
    assert.equals(1, runs)
  end)

  it("counts a duplicated name once", function()
    -- Both sides of a single-file view can name the same thing. Counting it
    -- twice would leave the wait outstanding forever.
    local runs = 0
    local ready = readiness.when_all({ "original", "original" }, function()
      runs = runs + 1
    end)

    ready.done("original")
    assert.equals(1, runs)
  end)
end)
