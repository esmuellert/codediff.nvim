describe("watcher installation location", function()
  local original_install
  local original_path
  local original_override
  local original_no_auto_install
  local plugin_root
  local extension

  before_each(function()
    original_install = package.loaded["codediff.core.installer.watcher"]
    original_path = package.loaded["codediff.core.path"]
    original_override = vim.env.CODEDIFF_WATCHER_PATH
    original_no_auto_install = vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL
    vim.env.CODEDIFF_WATCHER_PATH = nil
    vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"

    plugin_root = vim.fn.tempname()
    vim.fn.mkdir(plugin_root, "p")
    extension = require("ffi").os == "Windows" and ".exe" or ""
    package.loaded["codediff.core.path"] = {
      get_plugin_root = function()
        return plugin_root
      end,
    }
    package.loaded["codediff.core.installer.watcher"] = nil
  end)

  after_each(function()
    package.loaded["codediff.core.installer.watcher"] = original_install
    package.loaded["codediff.core.path"] = original_path
    vim.env.CODEDIFF_WATCHER_PATH = original_override
    vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = original_no_auto_install
    vim.fn.delete(plugin_root, "rf")
  end)

  it("uses the versioned executable from the plugin root", function()
    local expected = plugin_root .. "/codediff-watcher_0.23.2" .. extension
    vim.fn.writefile({ "stub" }, expected)
    local resolved

    require("codediff.core.installer.watcher").ensure(function(path)
      resolved = path
    end)

    assert.equals(expected, resolved)
  end)

  it("prefers an unversioned manual build in the plugin root", function()
    local manual = plugin_root .. "/codediff-watcher" .. extension
    local versioned = plugin_root .. "/codediff-watcher_0.23.2" .. extension
    vim.fn.writefile({ "manual" }, manual)
    vim.fn.writefile({ "downloaded" }, versioned)
    local resolved

    require("codediff.core.installer.watcher").ensure(function(path)
      resolved = path
    end)

    assert.equals(manual, resolved)
  end)
end)
