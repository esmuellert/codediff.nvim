local supervisor = require("tests.framework.supervisor")
local h = require("tests.support")

describe("test discovery and directory boundaries", function()
  it("partitions every spec into exactly one test layer", function()
    local all, combined, seen = supervisor.discover("all"), {}, {}
    for _, layer in ipairs({ "unit", "integration", "e2e" }) do
      local specs = supervisor.discover(layer)
      assert.is_true(#specs > 0, "empty test layer: " .. layer)
      assert.same(specs, supervisor.discover("tests/" .. layer))
      for _, spec in ipairs(specs) do
        assert.is_nil(seen[spec], "spec discovered more than once: " .. spec)
        seen[spec] = true
        combined[#combined + 1] = spec
        assert.is_nil(spec:match("_e2e_spec%.lua$"), "encode the test layer in its directory, not its filename")
      end
    end
    table.sort(combined)
    assert.same(all, combined, "a spec is outside unit/, integration/ or e2e/")
    assert.same(all, supervisor.discover())
  end)

  it("keeps runnable specs out of test infrastructure and fixtures", function()
    for _, dir in ipairs({ "framework", "support", "fixtures" }) do
      assert.same({}, supervisor.discover("tests/" .. dir), "misplaced spec in " .. dir)
    end
  end)

  it("selects a feature directory without including adjacent features", function()
    assert.same({
      "tests/unit/core/watcher/manager_spec.lua",
      "tests/unit/core/watcher/protocol_spec.lua",
    }, supervisor.discover("tests/unit/core/watcher"))
  end)

  it("normalizes relative, absolute and Windows-style single-spec paths", function()
    local spec = "tests/unit/core/path_spec.lua"
    for _, target in ipairs({ spec, "./" .. spec, h.project_root .. "/" .. spec, (spec:gsub("/", "\\")) }) do
      assert.same({ spec }, supervisor.discover(target))
    end
  end)

  it("does not turn a missing target or support file into a successful selection", function()
    assert.same({}, supervisor.discover("tests/not-a-test-layer"))
    assert.same({}, supervisor.discover("tests/unit/missing_spec.lua"))
    assert.same({}, supervisor.discover("tests/support/init.lua"))
  end)
end)
