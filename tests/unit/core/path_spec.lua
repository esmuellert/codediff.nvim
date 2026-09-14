-- Tests for path reference resolution (core/path.lua make_ref)
local helpers = require("tests.support")

describe("core.path Path", function()
  local path

  before_each(function()
    helpers.ensure_plugin_loaded()
    path = require("codediff.core.path")
  end)

  describe("make_ref", function()
    it("derives relative from an absolute path under root (POSIX)", function()
      local ref = path.make_ref("/home/u/repo/nvim/init.lua", "/home/u/repo")
      assert.equals("/home/u/repo/nvim/init.lua", ref.absolute)
      assert.equals("nvim/init.lua", ref.relative)
    end)

    it("derives absolute from a relative path + root (POSIX)", function()
      local ref = path.make_ref("nvim/init.lua", "/home/u/repo")
      assert.equals("/home/u/repo/nvim/init.lua", ref.absolute)
      assert.equals("nvim/init.lua", ref.relative)
    end)

    it("leaves relative empty when absolute is not under root", function()
      local ref = path.make_ref("/etc/hosts", "/home/u/repo")
      assert.equals("/etc/hosts", ref.absolute)
      assert.equals("", ref.relative)
    end)

    it("tolerates a trailing slash on root", function()
      local ref = path.make_ref("nvim/init.lua", "/home/u/repo/")
      assert.equals("/home/u/repo/nvim/init.lua", ref.absolute)
      assert.equals("nvim/init.lua", ref.relative)
    end)

    it("normalizes backslashes to forward slashes", function()
      local ref = path.make_ref("nvim\\init.lua", "C:\\repo")
      assert.equals("C:/repo/nvim/init.lua", ref.absolute)
      assert.equals("nvim/init.lua", ref.relative)
    end)

    it("handles a Windows drive-letter absolute path", function()
      local ref = path.make_ref("C:/repo/src/a.lua", "C:/repo")
      assert.equals("C:/repo/src/a.lua", ref.absolute)
      assert.equals("src/a.lua", ref.relative)
    end)

    it("handles a UNC absolute path", function()
      local ref = path.make_ref("//server/share/file.txt", "//server/share")
      assert.equals("//server/share/file.txt", ref.absolute)
      assert.equals("file.txt", ref.relative)
    end)

    it('returns empty ref for "" and nil', function()
      for _, input in ipairs({ "", nil }) do
        local ref = path.make_ref(input, "/home/u/repo")
        assert.equals("", ref.absolute)
        assert.equals("", ref.relative)
      end
    end)

    it("resolves absolute against cwd when no root is given (relative stays empty)", function()
      local ref = path.make_ref("relative/file.lua", nil)
      assert.equals("", ref.relative)
      -- absolute should be absolute (cwd-resolved)
      assert.is_true(ref.absolute:sub(1, 1) == "/" or ref.absolute:match("^%a:/") ~= nil)
      assert.is_true(ref.absolute:match("relative/file%.lua$") ~= nil)
    end)

    it("keeps an absolute path when no root is given", function()
      local ref = path.make_ref("/abs/only/file.lua", nil)
      assert.equals("/abs/only/file.lua", ref.absolute)
      assert.equals("", ref.relative)
    end)

    it("round-trips: absolute input reproduces absolute; relative input reproduces relative", function()
      local root = "/home/u/repo"
      assert.equals("/home/u/repo/a/b.lua", path.make_ref("/home/u/repo/a/b.lua", root).absolute)
      assert.equals("a/b.lua", path.make_ref("a/b.lua", root).relative)
    end)

    it("treats absolute == root as empty relative (root itself)", function()
      local ref = path.make_ref("/home/u/repo", "/home/u/repo")
      assert.equals("/home/u/repo", ref.absolute)
      assert.equals("", ref.relative)
    end)

    it("does not strip a sibling dir that shares a name prefix with root", function()
      -- Guards the dedup false-positive class: root "/a/repo" must NOT treat
      -- "/a/repo-other/x" as living under it (a naive substring check would).
      local ref = path.make_ref("/a/repo-other/x.lua", "/a/repo")
      assert.equals("/a/repo-other/x.lua", ref.absolute)
      assert.equals("", ref.relative)
    end)

    it("resolves a deeply nested path and recomposes to the same absolute", function()
      local root = "/home/u/repo"
      local abs = "/home/u/repo/a/b/c/d/e.lua"
      local ref = path.make_ref(abs, root)
      assert.equals("a/b/c/d/e.lua", ref.relative)
      assert.equals(abs, ref.absolute)
      -- Feeding the derived relative back in reproduces the same absolute.
      assert.equals(abs, path.make_ref(ref.relative, root).absolute)
    end)
  end)

  describe("is_empty / empty", function()
    it("empty() is empty", function()
      assert.is_true(path.is_empty(path.empty()))
    end)

    it("is_empty is true for nil and blank refs", function()
      assert.is_true(path.is_empty(nil))
      assert.is_true(path.is_empty({ relative = "", absolute = "" }))
    end)

    it("is_empty is false when either form is set", function()
      assert.is_false(path.is_empty({ relative = "a", absolute = "" }))
      assert.is_false(path.is_empty({ relative = "", absolute = "/a" }))
    end)
  end)
end)
