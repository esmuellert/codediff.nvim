describe("refresh dependency policy", function()
  local policy
  before_each(function()
    policy = require("codediff.ui.refresh.policy")
  end)

  it("checks everything when the source of a change is unknown", function()
    assert.same({ full = true }, policy.normalize())
    assert.is_true(policy.needs_read("HEAD", { full = true }))
    assert.is_true(policy.needs_read(":1", { full = true }))
    assert.is_true(policy.needs_read(nil, { full = true }))
  end)

  it("never loses a change category while merging pending events", function()
    assert.same({ worktree = true, index = true, refs = true }, policy.merge({ worktree = true, refs = true }, { index = true, refs = false }))
  end)

  it("selects dependencies for all sixteen watcher flag combinations", function()
    for mask = 0, 15 do
      local event = {
        worktree = mask % 2 == 1,
        index = math.floor(mask / 2) % 2 == 1,
        head = math.floor(mask / 4) % 2 == 1,
        refs = math.floor(mask / 8) % 2 == 1,
      }
      assert.equals(event.worktree, policy.needs_read("WORKING", event))
      for stage = 0, 3 do
        assert.equals(event.index, policy.needs_read(":" .. stage, event))
      end
      assert.equals(event.head or event.refs, policy.needs_read("HEAD", event))
      assert.equals(event.head or event.refs, policy.needs_read("topic", event))
      assert.is_false(policy.needs_read(string.rep("a", 40), event))
      assert.is_false(policy.needs_read(string.rep("a", 40) .. "^", event))
    end
  end)

  it("treats buffer edits independently of filesystem events", function()
    assert.is_true(policy.needs_read(nil, { buffer = true }))
    assert.is_false(policy.needs_read(":0", { buffer = true }))
    assert.is_false(policy.needs_read("HEAD", { buffer = true }))
  end)

  it("does not refresh fixed revision or history lists for worktree-only events", function()
    assert.is_false(policy.panel_needed({ name = "history" }, { worktree = true }))
    assert.is_true(policy.panel_needed({ name = "history" }, { refs = true }))
    assert.is_false(policy.panel_needed({ name = "explorer", data = { base_revision = string.rep("a", 40), target_revision = string.rep("b", 40) } }, { worktree = true }))
    assert.is_false(policy.panel_needed({ name = "explorer", data = { base_revision = "HEAD", target_revision = ":0" } }, { worktree = true }))
    assert.is_true(policy.panel_needed({ name = "explorer", data = {} }, { index = true }))
  end)
end)
