local install = require("codediff.core.installer.common")

describe("shared native installer", function()
  local original_notify
  local original_download_file
  local original_command_exists
  local original_run

  before_each(function()
    original_notify = vim.notify
    original_download_file = install.download_file
    original_command_exists = install.command_exists
    original_run = install.run
  end)

  after_each(function()
    vim.notify = original_notify
    install.download_file = original_download_file
    install.command_exists = original_command_exists
    install.run = original_run
  end)

  it("uses curl with the established download arguments", function()
    local command
    install.command_exists = function(candidate)
      return candidate == "curl"
    end
    install.run = function(candidate)
      command = candidate
      return true
    end

    local ok = install.download_file("https://example.test/asset", "/tmp/asset")

    assert.is_true(ok)
    assert.same({ "curl", "-fsSL", "-o", "/tmp/asset", "https://example.test/asset" }, command)
  end)

  it("provides the same install notifications to every native asset", function()
    local messages = {}
    local downloaded
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    install.download_file = function(url, destination)
      downloaded = { url, destination }
      return true
    end

    local ok = install.download({
      name = "native-tool",
      version = "1.2.3",
      os = "macos",
      arch = "arm64",
      url = "https://example.test/native-tool",
      destination = "/tmp/native-tool",
    })
    install.notify_success("native-tool")

    assert.is_true(ok)
    assert.same({ "https://example.test/native-tool", "/tmp/native-tool" }, downloaded)
    assert.same({
      "Installing native-tool v1.2.3 for macos arm64...",
      "Downloading from: https://example.test/native-tool",
      "Successfully installed native-tool!",
    }, messages)
  end)

  it("keeps silent installs silent", function()
    local notifications = 0
    vim.notify = function()
      notifications = notifications + 1
    end
    install.download_file = function()
      return true
    end

    install.download({
      name = "native-tool",
      version = "1.2.3",
      os = "linux",
      arch = "x64",
      url = "https://example.test/native-tool",
      destination = "/tmp/native-tool",
      silent = true,
    })
    install.notify_success("native-tool", true)

    assert.equals(0, notifications)
  end)
end)
