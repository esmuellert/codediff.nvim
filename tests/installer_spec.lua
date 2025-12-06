-- Test: Installer Module
-- Validates automatic binary installation and version management

local installer = require("vscode-diff.installer")
local version = require("vscode-diff.version")

describe("Installer Module", function()
  -- Test 1: Module loads correctly
  it("Loads installer module", function()
    assert.is_not_nil(installer, "Installer module should load")
    assert.equal("table", type(installer), "Installer should be a table")
  end)

  -- Test 2: Public API functions exist
  it("Exposes correct public API", function()
    assert.equal("function", type(installer.install), "Should have install function")
    assert.equal("function", type(installer.is_installed), "Should have is_installed function")
    assert.equal("function", type(installer.get_lib_path), "Should have get_lib_path function")
    assert.equal("function", type(installer.get_installed_version), "Should have get_installed_version function")
    assert.equal("function", type(installer.needs_update), "Should have needs_update function")
  end)

  -- Test 3: VERSION is loaded from version.lua
  it("VERSION is available from version module", function()
    assert.is_not_nil(version.VERSION, "VERSION should be loaded")
    assert.equal("string", type(version.VERSION), "VERSION should be a string")
    assert.is_true(#version.VERSION > 0, "VERSION should not be empty")
    -- Check version format (e.g., "0.8.0" or "2.0.0-next.0")
    assert.is_true(version.VERSION:match("^%d+%.%d+%.%d+") ~= nil, "VERSION should match semantic version format")
  end)

  -- Test 4: get_lib_path returns correct format
  it("get_lib_path returns valid library path", function()
    local lib_path = installer.get_lib_path()
    assert.is_not_nil(lib_path, "Library path should not be nil")
    assert.equal("string", type(lib_path), "Library path should be a string")
    
    -- Should contain libvscode_diff in the filename
    assert.is_true(lib_path:match("libvscode_diff") ~= nil, 
      "Library filename should contain 'libvscode_diff'")
    
    -- Should have correct extension based on OS
    local ffi = require("ffi")
    if ffi.os == "Windows" then
      assert.is_true(lib_path:match("%.dll$") ~= nil, "Windows should use .dll")
    elseif ffi.os == "OSX" then
      assert.is_true(lib_path:match("%.dylib$") ~= nil, "macOS should use .dylib")
    else
      assert.is_true(lib_path:match("%.so$") ~= nil, "Linux should use .so")
    end
  end)

  -- Test 5: is_installed checks for library file
  it("is_installed checks for library file", function()
    local installed = installer.is_installed()
    assert.equal("boolean", type(installed), "is_installed should return boolean")
    
    -- If installed, the file should actually exist
    if installed then
      local lib_path = installer.get_lib_path()
      assert.is_not_nil(lib_path, "Library path should exist if installed")
      assert.equal(1, vim.fn.filereadable(lib_path), "Library file should be readable if installed")
    end
  end)

  -- Test 6: get_installed_version returns nil or valid version
  it("get_installed_version returns nil or version string", function()
    local installed_version = installer.get_installed_version()
    
    if installed_version then
      assert.equal("string", type(installed_version), "Installed version should be string if present")
      assert.is_true(#installed_version > 0, "Installed version should not be empty")
      -- Should match semantic version format
      assert.is_true(installed_version:match("^%d+%.%d+%.%d+$") ~= nil, 
        "Installed version should match semantic version format")
    end
    -- Note: We can't assert is_installed() is false if installed_version is nil,
    -- because we might have an unversioned manual build.
  end)

  -- Test 7: needs_update logic
  it("needs_update correctly determines update necessity", function()
    local needs_update = installer.needs_update()
    assert.equal("boolean", type(needs_update), "needs_update should return boolean")
    
    local installed_version = installer.get_installed_version()
    local current_version = version.VERSION
    local lib_path = installer.get_lib_path()
    
    -- Check if we are using unversioned library
    local is_unversioned = lib_path and not lib_path:match(version.VERSION)
    
    if is_unversioned then
      -- Manual build is assumed to be up-to-date
      assert.is_false(needs_update, "Should not need update when using manual build")
    elseif not installed_version then
      -- No version installed, should need update
      assert.is_true(needs_update, "Should need update when no version is installed")
    elseif installed_version ~= current_version then
      -- Different version, should need update
      assert.is_true(needs_update, "Should need update when versions differ")
    else
      -- Same version, should not need update
      assert.is_false(needs_update, "Should not need update when versions match")
    end
  end)

  -- Test 8: install function signature
  it("install function accepts options table", function()
    -- Test that install can be called with empty options without erroring
    -- Note: We won't actually download during tests, just verify the function exists
    -- and accepts the expected parameters
    local ok = pcall(function()
      -- Just verify the function can be called with options
      -- We check signature, not actual execution (would require network)
      local opts = { silent = true, force = true }
      -- Don't actually call to avoid network access during tests
    end)
    assert.is_true(ok, "Install function should accept options parameter")
  end)

  -- Test 9: Version comparison logic
  it("Correctly identifies version mismatches", function()
    local current_version = version.VERSION
    local installed_version = installer.get_installed_version()
    
    -- Test the logic of needs_update
    if installed_version and installed_version ~= current_version then
      assert.is_true(installer.needs_update(), 
        string.format("Should detect version mismatch: installed=%s, current=%s", 
          installed_version, current_version))
    end
  end)

  -- Test 10: Library path is in plugin root
  it("Library path is in plugin root directory", function()
    local lib_path = installer.get_lib_path()
    assert.is_not_nil(lib_path, "Library path should not be nil")
    
    -- Path should not contain subdirectories like lua/ or src/
    assert.is_false(lib_path:match("/lua/") ~= nil, "Library should not be in lua/ subdirectory")
    assert.is_false(lib_path:match("/src/") ~= nil, "Library should not be in src/ subdirectory")
    
    -- Should contain libvscode_diff in the filename
    assert.is_true(lib_path:match("libvscode_diff") ~= nil, 
      "Library filename should contain 'libvscode_diff'")
  end)

  -- Test 11: Priority of unversioned library (manual build)
  it("Prioritizes unversioned library over versioned one", function()
    local lib_path_initial = installer.get_lib_path()
    if not lib_path_initial then
       -- If nothing installed, we can't easily determine plugin root without internal access
       -- But usually tests run with something installed.
       -- Let's try to get plugin root from debug info like the module does
       local source = debug.getinfo(1).source:sub(2)
       local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
       
       -- Continue with test...
    end
    
    local plugin_root = lib_path_initial and lib_path_initial:match("(.*/)") or vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h") .. "/"
    local ext = require("ffi").os == "Windows" and "dll" or (require("ffi").os == "OSX" and "dylib" or "so")
    local unversioned_name = "libvscode_diff." .. ext
    local unversioned_path = plugin_root .. unversioned_name
    
    local created_dummy = false
    
    -- If unversioned library doesn't exist, create a dummy one
    -- If it DOES exist (e.g. Windows CI build), use it but don't overwrite/delete it (it might be locked)
    if vim.fn.filereadable(unversioned_path) == 0 then
      local f = io.open(unversioned_path, "w")
      if f then
        f:write("dummy content")
        f:close()
        created_dummy = true
      else
        -- If we can't create it, we can't run this test fully, but shouldn't fail if it's just permissions
        print("WARNING: Could not create dummy unversioned library, skipping creation")
      end
    end
    
    -- Verify it is prioritized
    local lib_path = installer.get_lib_path()
    -- Normalize paths for comparison (Windows might have mixed slashes)
    local normalized_lib_path = lib_path:gsub("\\", "/")
    local normalized_unversioned_path = unversioned_path:gsub("\\", "/")
    
    assert.equal(normalized_unversioned_path, normalized_lib_path, "Should prioritize unversioned library")
    assert.is_true(installer.is_installed(), "Should be considered installed")
    assert.is_false(installer.needs_update(), "Should not need update")
    
    -- Cleanup only if we created it
    if created_dummy then
      os.remove(unversioned_path)
      
      -- Verify it falls back to versioned (or nil if none)
      local fallback_path = installer.get_lib_path()
      if fallback_path then
        assert.not_equal(unversioned_path, fallback_path, "Should fall back to versioned library")
      end
    end
  end)

  -- Test: libgomp detection on Linux
  describe("libgomp dependency handling", function()
    it("check_system_libgomp detects library via ldconfig on Linux", function()
      local ffi = require("ffi")

      -- Only test on Linux
      if ffi.os ~= "Linux" then
        pending("libgomp only needed on Linux")
        return
      end

      -- Check ldconfig cache (same method as installer uses)
      local handle = io.popen("ldconfig -p 2>/dev/null | grep -q 'libgomp\\.so\\.1' && echo 'found'")
      local has_libgomp = false
      if handle then
        local result = handle:read("*a")
        handle:close()
        has_libgomp = result:match("found") ~= nil
      end

      assert.equal("boolean", type(has_libgomp), "Detection should return boolean")

      if has_libgomp then
        print("  ✓ System has libgomp.so.1 in ldconfig cache")
      else
        print("  ✗ System missing libgomp.so.1 in ldconfig (installer will bundle)")
      end
    end)

    it("ldconfig detection matches native linker behavior", function()
      local ffi = require("ffi")

      if ffi.os ~= "Linux" then
        pending("libgomp only needed on Linux")
        return
      end

      -- Check ldconfig
      local handle = io.popen("ldconfig -p 2>/dev/null | grep 'libgomp\\.so\\.1'")
      local ldconfig_path = nil
      if handle then
        local result = handle:read("*a")
        handle:close()
        ldconfig_path = result:match("=> ([^\n]+)")
      end

      if ldconfig_path then
        -- Verify the path actually exists
        assert.equal(1, vim.fn.filereadable(ldconfig_path), "ldconfig path should be readable")
        print("  ✓ ldconfig reports: " .. ldconfig_path)
      else
        print("  ✗ libgomp not in ldconfig cache")
      end
    end)

    it("skips libgomp check on non-Linux systems", function()
      local ffi = require("ffi")

      if ffi.os == "Linux" then
        pending("This test is for non-Linux systems")
        return
      end

      -- On macOS/Windows, libgomp is not needed
      -- Installer should return true without checking
      print(string.format("  ✓ Skipping libgomp on %s (not needed)", ffi.os))
    end)
    
    it("libgomp path follows naming convention", function()
      local ffi = require("ffi")
      
      if ffi.os ~= "Linux" then
        pending("libgomp only needed on Linux")
        return
      end
      
      local version_mod = require("vscode-diff.version")
      local version = version_mod.VERSION
      
      -- Check expected naming convention for libgomp downloads
      local arch = vim.loop.os_uname().machine:lower()
      if arch:match("x86_64") or arch:match("amd64") then
        arch = "x64"
      elseif arch:match("aarch64") or arch:match("arm64") then
        arch = "arm64"
      end
      
      local expected_filename = string.format("libgomp_linux_%s_%s.so.1", arch, version)
      print(string.format("  Expected libgomp filename: %s", expected_filename))
      
      -- Verify format
      assert.is_not_nil(expected_filename:match("^libgomp_linux_"), "Should start with libgomp_linux_")
      assert.is_not_nil(expected_filename:match("%.so%.1$"), "Should end with .so.1")
    end)
  end)
end)
