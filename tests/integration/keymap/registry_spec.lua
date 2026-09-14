-- Integration tests for the keymap registry and Neovim's real buffer mappings.
-- These exercise the machinery directly on scratch buffers, independent of any
-- diff session, so ownership logic can be reviewed in isolation.

local keymap = require("codediff.keymap")
local slots = require("codediff.keymap.slots")
local normalize = require("codediff.keymap.normalize")

local function scratch()
  return vim.api.nvim_create_buf(false, true)
end

-- nvim_buf_get_keymap reports lhs in display form ("<CR>"), while claims are
-- keyed by raw bytes. Query through maparg so both sides agree.
local function map_of(bufnr, mode, lhs)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local result = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
  if type(result) ~= "table" or next(result) == nil or result.buffer ~= 1 then
    return nil
  end
  return result
end

local function noop() end

describe("keymap registry", function()
  local buffers

  before_each(function()
    slots.reset()
    buffers = {}
  end)

  after_each(function()
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    slots.reset()
  end)

  local function new_buf()
    local bufnr = scratch()
    table.insert(buffers, bufnr)
    return bufnr
  end

  describe("normalization", function()
    it("treats <Tab> and <C-i> as the same slot", function()
      assert.equals(normalize.canonical("<Tab>"), normalize.canonical("<C-i>"))
    end)

    it("expands <leader>", function()
      local canonical = normalize.canonical("<leader>x")
      assert.is_not_nil(canonical)
      assert.is_not.equal("<leader>x", canonical)
    end)

    it("treats false, nil and empty string as disabled", function()
      assert.is_nil(normalize.resolve(false))
      assert.is_nil(normalize.resolve(nil))
      assert.is_nil(normalize.resolve(""))
      assert.equals("q", normalize.resolve("q"))
    end)
  end)

  describe("claim and release", function()
    it("installs a mapping and removes it when no prior mapping existed", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      assert.is_true(r:claim(bufnr, "n", "q", noop, { desc = "codediff" }))
      assert.equals("codediff", map_of(bufnr, "n", "q").desc)

      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "q"))
      assert.equals(0, slots.count())
    end)

    it("restores a pre-existing buffer-local mapping", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = bufnr, desc = "user" })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })
      assert.equals("codediff", map_of(bufnr, "n", "q").desc)

      r:dispose()
      assert.equals("user", map_of(bufnr, "n", "q").desc)
    end)

    it("does not recreate a global mapping as buffer-local", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "<Plug>codediffGlobalProbe", noop, { desc = "global" })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "<Plug>codediffGlobalProbe", noop, { desc = "codediff" })
      r:dispose()

      assert.is_nil(map_of(bufnr, "n", "<Plug>codediffGlobalProbe"))
      pcall(vim.keymap.del, "n", "<Plug>codediffGlobalProbe")
    end)

    it("silently ignores a disabled binding", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      assert.is_false(r:claim(bufnr, "n", false, noop, {}))
      assert.is_false(r:claim(bufnr, "n", nil, noop, {}))
      assert.equals(0, r:count())
    end)

    it("claims every requested mode independently", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:claim(bufnr, { "o", "x" }, "ih", noop, { desc = "textobject" })
      assert.is_not_nil(map_of(bufnr, "o", "ih"))
      assert.is_not_nil(map_of(bufnr, "x", "ih"))

      r:dispose()
      assert.is_nil(map_of(bufnr, "o", "ih"))
      assert.is_nil(map_of(bufnr, "x", "ih"))
    end)

    it("replaces its own previous claim when re-registering", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:claim(bufnr, "n", "q", noop, { desc = "first" })
      r:claim(bufnr, "n", "q", noop, { desc = "second" })

      assert.equals("second", map_of(bufnr, "n", "q").desc)
      assert.equals(1, r:count())

      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "q"))
    end)
  end)

  describe("multiple owners", function()
    it("keeps the other session's mapping when one disposes", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = bufnr, desc = "user" })

      local a = keymap.new("a")
      local b = keymap.new("b")
      a:claim(bufnr, "n", "q", noop, { desc = "session-a" })
      b:claim(bufnr, "n", "q", noop, { desc = "session-b" })

      assert.equals("session-b", map_of(bufnr, "n", "q").desc, "newest claim wins")

      b:dispose()
      assert.equals("session-a", map_of(bufnr, "n", "q").desc, "falls back to the remaining claim")

      a:dispose()
      assert.equals("user", map_of(bufnr, "n", "q").desc, "original returns only after the last release")
    end)

    it("restores the original when sessions dispose out of order", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = bufnr, desc = "user" })

      local a = keymap.new("a")
      local b = keymap.new("b")
      a:claim(bufnr, "n", "q", noop, { desc = "session-a" })
      b:claim(bufnr, "n", "q", noop, { desc = "session-b" })

      a:dispose()
      assert.equals("session-b", map_of(bufnr, "n", "q").desc)

      b:dispose()
      assert.equals("user", map_of(bufnr, "n", "q").desc)
    end)

    it("honors priority over claim order", function()
      local bufnr = new_buf()
      local a = keymap.new("a")
      local b = keymap.new("b")

      a:claim(bufnr, "n", "q", noop, { desc = "high" }, { priority = 10 })
      b:claim(bufnr, "n", "q", noop, { desc = "low" }, { priority = 1 })

      assert.equals("high", map_of(bufnr, "n", "q").desc)

      a:dispose()
      b:dispose()
    end)
  end)

  describe("suspend and resume", function()
    it("uninstalls and reinstalls suspendable mappings", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = bufnr, desc = "user" })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })

      r:suspend()
      assert.equals("user", map_of(bufnr, "n", "q").desc, "suspend must hand the key back")

      r:resume()
      assert.equals("codediff", map_of(bufnr, "n", "q").desc, "resume must take it again")

      r:dispose()
      assert.equals("user", map_of(bufnr, "n", "q").desc)
    end)

    it("leaves non-suspendable mappings installed", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "<CR>", noop, { desc = "panel" }, { suspendable = false })

      r:suspend()
      assert.is_not_nil(map_of(bufnr, "n", "<CR>"), "panel mappings must survive a tab switch")

      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "<CR>"))
    end)

    it("is idempotent", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })

      r:suspend()
      r:suspend()
      r:resume()
      r:resume()
      assert.equals("codediff", map_of(bufnr, "n", "q").desc)

      r:dispose()
      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "q"))
    end)
  end)

  describe("buffer detach", function()
    it("releases one buffer without disturbing the others", function()
      local old_buf = new_buf()
      local new_buffer = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = old_buf, desc = "user" })

      local r = keymap.new("test")
      r:claim(old_buf, "n", "q", noop, { desc = "codediff" })
      r:claim(new_buffer, "n", "q", noop, { desc = "codediff" })

      r:detach_buffer(old_buf)
      assert.equals("user", map_of(old_buf, "n", "q").desc, "detached buffer must be restored")
      assert.equals("codediff", map_of(new_buffer, "n", "q").desc, "other buffers stay mapped")

      r:dispose()
    end)

    it("detach_buffers_except keeps only the listed buffers", function()
      local keep_buf = new_buf()
      local drop_buf = new_buf()

      local r = keymap.new("test")
      r:claim(keep_buf, "n", "q", noop, { desc = "codediff" })
      r:claim(drop_buf, "n", "q", noop, { desc = "codediff" })

      r:detach_buffers_except({ [keep_buf] = true })
      assert.is_not_nil(map_of(keep_buf, "n", "q"))
      assert.is_nil(map_of(drop_buf, "n", "q"))

      r:dispose()
    end)
  end)

  describe("foreign mappings", function()
    it("does not clobber a mapping installed by someone else", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })

      -- Another plugin takes the key while the session is live.
      vim.keymap.set("n", "q", function() end, { buffer = bufnr, desc = "other-plugin" })

      r:dispose()
      local current = map_of(bufnr, "n", "q")
      assert.is_not_nil(current, "a foreign mapping must survive codediff teardown")
      assert.equals("other-plugin", current.desc, "a foreign mapping must survive codediff teardown")
    end)

    it("does not reinstall over a foreign mapping on resume", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })

      r:suspend()
      vim.keymap.set("n", "q", function() end, { buffer = bufnr, desc = "other-plugin" })
      r:resume()

      local current = map_of(bufnr, "n", "q")
      assert.is_not_nil(current, "foreign mapping should still be installed")
      assert.equals("other-plugin", current.desc)
      r:dispose()
    end)
  end)

  describe("special keys", function()
    -- Regression: the slot identity is the canonical byte sequence, but the
    -- mapping APIs must be given the original spelling. Passing canonical
    -- bytes back to vim.keymap.set re-encodes keys such as <2-LeftMouse> and
    -- <Down>, leaving a mapping that the real key press can never reach.
    local SPECIAL = { "q", "<CR>", "<Esc>", "<Tab>", "<leader>hs", "<2-LeftMouse>", "<Down>", "<Up>", "<S-Tab>", "<C-n>", "zo", "]c", "2do" }

    it("installs a mapping the key press can actually reach", function()
      for _, key in ipairs(SPECIAL) do
        local bufnr = new_buf()
        local r = keymap.new("test")
        assert.is_true(r:claim(bufnr, "n", key, noop, { desc = "codediff" }), key .. " should be claimed")

        local found = map_of(bufnr, "n", key)
        assert.is_not_nil(found, string.format("%q is mapped but unreachable via maparg", key))
        assert.equals("codediff", found.desc, key .. " should resolve to the codediff mapping")

        r:dispose()
      end
    end)

    it("releases special keys on dispose", function()
      for _, key in ipairs(SPECIAL) do
        local bufnr = new_buf()
        local r = keymap.new("test")
        r:claim(bufnr, "n", key, noop, { desc = "codediff" })
        r:dispose()
        assert.is_nil(map_of(bufnr, "n", key), string.format("%q should be released", key))
      end
    end)

    it("restores a pre-existing mapping for special keys", function()
      for _, key in ipairs({ "<2-LeftMouse>", "<Down>", "<CR>" }) do
        local bufnr = new_buf()
        vim.keymap.set("n", key, noop, { buffer = bufnr, desc = "user" })

        local r = keymap.new("test")
        r:claim(bufnr, "n", key, noop, { desc = "codediff" })
        assert.equals("codediff", map_of(bufnr, "n", key).desc, key .. " should be taken over")

        r:dispose()
        local restored = map_of(bufnr, "n", key)
        assert.is_not_nil(restored, key .. " should be restored")
        assert.equals("user", restored.desc, key .. " should return to the user's mapping")
      end
    end)
  end)

  describe("ownership edge cases", function()
    -- Regressions found by an adversarial audit of the registry.

    it("restores the user mapping after mapleader changes mid-session", function()
      local bufnr = new_buf()
      local saved_leader = vim.g.mapleader
      vim.g.mapleader = "\\"
      vim.keymap.set("n", "\\x", noop, { buffer = bufnr, desc = "user" })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "<leader>x", noop, { desc = "codediff" })

      -- Changing the leader must not make the installed key unaddressable.
      vim.g.mapleader = ","
      r:dispose()
      vim.g.mapleader = saved_leader

      local restored = map_of(bufnr, "n", "\\x")
      assert.is_not_nil(restored, "the user's mapping should be restored")
      assert.equals("user", restored.desc)
    end)

    it("does not resurrect a mapping the user deleted while suspended", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", noop, { buffer = bufnr, desc = "user" })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })
      r:suspend()
      vim.keymap.del("n", "q", { buffer = bufnr })
      r:resume()

      assert.is_nil(map_of(bufnr, "n", "q"), "resume must not reclaim a key the user freed")
      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "q"), "dispose must not resurrect the deleted mapping")
    end)

    it("treats an options-only change as a foreign mapping", function()
      local bufnr = new_buf()
      vim.keymap.set("n", "q", "<Cmd>echo 1<CR>", { buffer = bufnr, desc = "user", silent = true })

      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })
      r:suspend()
      -- Same RHS, different options: a different mapping, and not ours.
      vim.keymap.set("n", "q", "<Cmd>echo 1<CR>", { buffer = bufnr, desc = "other", silent = false })
      r:resume()

      assert.equals("other", map_of(bufnr, "n", "q").desc, "resume must not overwrite a foreign mapping")
      r:dispose()
      assert.equals("other", map_of(bufnr, "n", "q").desc, "dispose must not restore over a foreign mapping")
    end)

    it("treats an active remap of the same RHS as foreign", function()
      -- A plugin may re-map the same right-hand side with different options.
      -- That is its mapping, not ours, and must survive teardown.
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", "<Cmd>echo 1<CR>", { desc = "codediff", silent = true })
      vim.keymap.set("n", "q", "<Cmd>echo 1<CR>", { buffer = bufnr, desc = "foreign", silent = false })

      r:dispose()
      local current = map_of(bufnr, "n", "q")
      assert.is_not_nil(current, "the foreign mapping must not be deleted")
      assert.equals("foreign", current.desc)
    end)

    it("treats an active remap reusing our callback as foreign", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })
      local installed = map_of(bufnr, "n", "q")
      vim.keymap.set("n", "q", installed.callback, { buffer = bufnr, desc = "foreign" })

      r:dispose()
      local current = map_of(bufnr, "n", "q")
      assert.is_not_nil(current, "the foreign mapping must not be deleted")
      assert.equals("foreign", current.desc)
    end)

    it("stops reporting ownership once displaced", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })
      assert.is_true(r:owns("q"), "codediff owns the key while installed")

      vim.keymap.set("n", "q", function() end, { buffer = bufnr, desc = "foreign" })

      assert.is_false(r:owns("q"), "a displaced key is not owned by codediff")
      assert.is_nil(r:documented_keys()[normalize.canonical("q")], "a displaced key must not be advertised in help")
      r:dispose()
    end)
  end)

  describe("scopes", function()
    it("releases claims a later pass no longer makes", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      r:claim(bufnr, "n", "gm", noop, { desc = "align move" })
      r:end_scope()
      assert.is_not_nil(map_of(bufnr, "n", "gm"))

      -- Second pass omits gm, as happens when switching to inline layout.
      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      r:end_scope()

      assert.is_not_nil(map_of(bufnr, "n", "q"), "renewed claims survive")
      assert.is_nil(map_of(bufnr, "n", "gm"), "claims not renewed by the pass are released")
      r:dispose()
    end)

    it("reveals the outer scope's claim when an overlapping scope is released", function()
      -- A user may configure a view key that collides with a scope-owned one,
      -- e.g. view.toggle_compact = "zo" against compact's own zo wrapper.
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:begin_scope("view")
      r:claim(bufnr, "n", "zo", noop, { desc = "toggle compact" })
      r:end_scope("view")

      r:begin_scope("compact")
      r:claim(bufnr, "n", "zo", noop, { desc = "synced fold" })
      r:end_scope("compact")
      assert.equals("synced fold", map_of(bufnr, "n", "zo").desc, "the newer scope wins while active")

      r:release_scope("compact")
      local revealed = map_of(bufnr, "n", "zo")
      assert.is_not_nil(revealed, "the view mapping must come back, not vanish")
      assert.equals("toggle compact", revealed.desc)

      r:dispose()
      assert.is_nil(map_of(bufnr, "n", "zo"), "both scopes released on dispose")
    end)

    it("releases a whole scope on demand", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      r:end_scope()
      r:begin_scope("conflict")
      r:claim(bufnr, "n", "]x", noop, { desc = "next conflict" })
      r:end_scope()

      r:release_scope("conflict")
      assert.is_nil(map_of(bufnr, "n", "]x"), "leaving conflict mode retires its mappings")
      assert.is_not_nil(map_of(bufnr, "n", "q"), "other scopes are untouched")
      r:dispose()
    end)

    it("restores the outer pass when scopes nest", function()
      local bufnr = new_buf()
      local r = keymap.new("test")

      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      -- an inner pass (compact) opening and closing inside the view pass
      r:begin_scope("compact")
      r:claim(bufnr, "n", "zo", noop, { desc = "fold" })
      r:end_scope("compact")
      -- still inside the view pass: this claim must belong to "view"
      r:claim(bufnr, "n", "gm", noop, { desc = "align" })
      r:end_scope("view")

      -- a later view pass omits gm; the inner scope's claim must be untouched
      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      r:end_scope("view")

      assert.is_nil(map_of(bufnr, "n", "gm"), "claims after a nested scope still belong to the outer pass")
      assert.is_not_nil(map_of(bufnr, "n", "zo"), "the inner scope's claims are not retired by the outer pass")
      r:dispose()
    end)

    it("does not accumulate scopes when a pass never closes", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      for _ = 1, 20 do
        r:begin_scope("view")
        r:claim(bufnr, "n", "q", noop, { desc = "quit" })
        -- deliberately no end_scope, as if the pass raised
      end
      assert.is_true(#r.scope_stack <= 1, "an aborted pass must not grow the scope stack, got " .. #r.scope_stack)
      r:dispose()
    end)

    it("keeps unscoped claims out of scope retirement", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "K", noop, { desc = "hover" })

      r:begin_scope("view")
      r:claim(bufnr, "n", "q", noop, { desc = "quit" })
      r:end_scope()

      assert.is_not_nil(map_of(bufnr, "n", "K"), "claims made outside a scope are never retired by one")
      r:dispose()
    end)
  end)

  describe("invalid buffers", function()
    it("ignores claims on an invalid buffer", function()
      local bufnr = new_buf()
      vim.api.nvim_buf_delete(bufnr, { force = true })

      local r = keymap.new("test")
      assert.is_false(r:claim(bufnr, "n", "q", noop, {}))
      assert.equals(0, r:count())
    end)

    it("disposes cleanly when a buffer was wiped mid-session", function()
      local bufnr = new_buf()
      local r = keymap.new("test")
      r:claim(bufnr, "n", "q", noop, { desc = "codediff" })

      vim.api.nvim_buf_delete(bufnr, { force = true })
      keymap.forget_buffer(bufnr)

      assert.has_no.errors(function()
        r:dispose()
      end)
      assert.equals(0, slots.count())
    end)
  end)
end)
