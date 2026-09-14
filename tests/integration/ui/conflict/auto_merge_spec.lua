-- Regression test for https://github.com/esmuellert/codediff.nvim/issues/353
-- "3-way merge fails to include non-conflicting adjacent insertions in Result buffer"
--
-- Before the fix: the Result buffer was seeded with raw BASE content and any
-- one-sided insertion that lived inside the same git hunk as a true conflict
-- silently vanished from the Result.
--
-- After the fix: the Result buffer is seeded with the VSCode-style
-- auto-merged content (BASE + every non-conflicting change from both sides)
-- and only true two-sided conflicts are left as BASE for the user to resolve.

local h = require('tests.support')
local diff_module = require('codediff.core.diff')
local merge_alignment = require('codediff.ui.conflict.merge')

describe('Issue #353 regression - 3-way merge auto-merge', function()
  before_each(function()
    h.ensure_plugin_loaded()
  end)

  it('keeps both sides one-sided insertions inside the Result buffer', function()
    -- BASE: an opening brace, two items, closing brace.
    -- OURS  inserts "ours_new" after the first item.
    -- THEIRS inserts "theirs_new" after the last item.
    -- git sees this as one big hunk and would emit conflict markers covering
    -- the whole region; codediff used to wipe the Result back to BASE in that
    -- case, dropping both additions.
    local base = {
      "local M = {",
      '  "a",',
      '  "b",',
      "}",
      "return M",
    }
    local ours = {
      "local M = {",
      '  "a",',
      '  "ours_new",',
      '  "b",',
      "}",
      "return M",
    }
    local theirs = {
      "local M = {",
      '  "a",',
      '  "b",',
      '  "theirs_new",',
      "}",
      "return M",
    }

    -- Use the real diff engine — same one the plugin uses at runtime.
    local diff_opts = {
      max_computation_time_ms = 2000,
      ignore_trim_whitespace = false,
      compute_moves = false,
    }
    local base_to_ours = diff_module.compute_diff(base, ours, diff_opts)
    local base_to_theirs = diff_module.compute_diff(base, theirs, diff_opts)

    assert.is_not_nil(base_to_ours, 'base->ours diff must compute')
    assert.is_not_nil(base_to_theirs, 'base->theirs diff must compute')

    local merged, conflict_blocks = merge_alignment.compute_auto_merged_result(
      base_to_ours, base_to_theirs, base, ours, theirs
    )

    -- The user-visible failure mode of #353 is: the Result buffer shows just
    -- BASE, missing both branches' additions. The fix must:
    --   (1) include "ours_new"
    --   (2) include "theirs_new"
    --   (3) emit no conflict markers, because both additions are at disjoint
    --       base positions — there is nothing for the user to resolve.
    local merged_text = table.concat(merged, '\n')
    assert.is_true(
      merged_text:find('ours_new', 1, true) ~= nil,
      "Result must contain OURS' insertion. Got:\n" .. merged_text
    )
    assert.is_true(
      merged_text:find('theirs_new', 1, true) ~= nil,
      "Result must contain THEIRS' insertion. Got:\n" .. merged_text
    )
    assert.equal(
      0, #conflict_blocks,
      'Non-overlapping insertions at disjoint base positions must not be flagged as conflicts'
    )

    -- And the original BASE structure is preserved around them.
    assert.is_true(merged_text:find('"a"', 1, true) ~= nil)
    assert.is_true(merged_text:find('"b"', 1, true) ~= nil)
    assert.is_true(merged_text:find('return M', 1, true) ~= nil)
  end)

  it('keeps a true two-sided conflict as BASE and exposes a result_range', function()
    -- Both sides edit the same line differently -> real conflict.
    local base = { "a", "b", "c" }
    local ours = { "a", "OURS", "c" }
    local theirs = { "a", "THEIRS", "c" }

    local diff_opts = { max_computation_time_ms = 2000 }
    local base_to_ours = diff_module.compute_diff(base, ours, diff_opts)
    local base_to_theirs = diff_module.compute_diff(base, theirs, diff_opts)

    local merged, conflict_blocks = merge_alignment.compute_auto_merged_result(
      base_to_ours, base_to_theirs, base, ours, theirs
    )

    -- Conflict region must be left as BASE for the user to resolve.
    assert.are.same({ "a", "b", "c" }, merged)
    assert.equal(1, #conflict_blocks)
    local b = conflict_blocks[1]
    assert.is_table(b.result_range, 'conflict block must carry result_range')
    -- The conflict lives at line 2 of the Result.
    assert.equal(2, b.result_range.start_line)
    assert.equal(3, b.result_range.end_line)
  end)

  it('applies a one-sided insertion that lives entirely outside any conflict', function()
    -- OURS inserts a brand-new line; THEIRS does nothing.
    local base = { "x", "y" }
    local ours = { "x", "new", "y" }
    local theirs = { "x", "y" }

    local diff_opts = { max_computation_time_ms = 2000 }
    local base_to_ours = diff_module.compute_diff(base, ours, diff_opts)
    local base_to_theirs = diff_module.compute_diff(base, theirs, diff_opts)

    local merged, conflict_blocks = merge_alignment.compute_auto_merged_result(
      base_to_ours, base_to_theirs, base, ours, theirs
    )

    assert.are.same({ "x", "new", "y" }, merged)
    assert.equal(0, #conflict_blocks)
  end)
end)

-- End-to-end-ish test: stand up a real merge-conflicted git repo, mirror how
-- the conflict view seeds the Result buffer, and assert the Result content.
-- This catches wiring regressions, not just auto-merge algorithm regressions.
describe('Issue #353 regression - end-to-end with a real git merge', function()
  local repo

  before_each(function()
    h.ensure_plugin_loaded()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    if repo then repo.cleanup() end
  end)

  it('Result buffer contains both sides for the canonical #353 scenario', function()
    -- Build the exact scenario from the bug report: a list both branches
    -- extend, where git emits a conflict because the additions are adjacent.
    --
    -- Note on semantics (matching VSCode, not diffview): when both branches
    -- insert lines at the *same* base position (here: between "a" and "b"),
    -- VSCode classifies that as a true two-sided conflict and leaves the
    -- Result as BASE. The user then resolves it with accept_incoming,
    -- accept_current, or accept_both. What the bug fixes is that accept_both
    -- now actually works (it didn't before because every conflict block was
    -- tracked against pure-BASE coordinates that the Result buffer no longer
    -- matched after any earlier auto-merge).
    --
    -- The end-to-end correctness assertion here is: a one-sided change
    -- adjacent to a conflict (the case diffview shows in the bug screenshot
    -- as both sides being auto-merged) must land in Result. We construct a
    -- scenario that exercises both at once: one one-sided add and one true
    -- two-sided conflict.
    local base = {
      "local M = {",
      '  "a",',
      '  "b",',
      "}",
      "return M",
    }
    repo.write_file('deps.lua', base)
    repo.git("add deps.lua")
    repo.git("commit -m base")

    -- OURS: appends "ours_only" at end of file (no overlap with THEIRS's edit)
    --       AND replaces "  a" with "  a_modified"
    repo.git("checkout -b ours")
    local ours = {
      "local M = {",
      '  "a_modified",',
      '  "b",',
      "}",
      "return M",
      "-- ours_only",
    }
    repo.write_file('deps.lua', ours)
    repo.git("commit -am ours")

    -- THEIRS: replaces "  a" with "  a_other" (conflicts with OURS' edit)
    repo.git("checkout main")
    repo.git("checkout -b theirs")
    local theirs = {
      "local M = {",
      '  "a_other",',
      '  "b",',
      "}",
      "return M",
    }
    repo.write_file('deps.lua', theirs)
    repo.git("commit -am theirs")

    repo.git("checkout ours")
    repo.git("merge theirs --no-edit")

    -- Read the three stages directly from the index, just like
    -- the side-by-side conflict path does (via git.get_file_content :1/:2/:3).
    local function git_show(spec)
      local out = repo.git("show " .. spec .. ":deps.lua")
      local lines = {}
      for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      -- Strip trailing empty line introduced by the splitter.
      if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
      return lines
    end

    local base_lines = git_show(":1")
    local ours_lines = git_show(":2")
    local theirs_lines = git_show(":3")

    assert.is_true(#base_lines > 0, 'BASE (:1) must exist for a content conflict')
    assert.is_true(#ours_lines > 0, 'OURS (:2) must exist')
    assert.is_true(#theirs_lines > 0, 'THEIRS (:3) must exist')

    -- Sanity-check that this scenario actually produced a conflict.
    local status = repo.git("status --porcelain deps.lua")
    assert.is_true(status:find("UU", 1, true) ~= nil, 'deps.lua should be in UU state')

    -- Reproduce the conflict view's seed computation.
    local diff_opts = { max_computation_time_ms = 2000 }
    -- Stage layout matches the conflict view: original=:3 (incoming/theirs),
    -- modified=:2 (current/ours) in the default conflict_ours_position="right".
    local base_to_original = diff_module.compute_diff(base_lines, theirs_lines, diff_opts)
    local base_to_modified = diff_module.compute_diff(base_lines, ours_lines, diff_opts)
    local merged, conflict_blocks = merge_alignment.compute_auto_merged_result(
      base_to_original, base_to_modified, base_lines, theirs_lines, ours_lines
    )

    local merged_text = table.concat(merged, '\n')

    -- The one-sided "ours_only" trailing line must be in Result. Pre-fix this
    -- was the whole bug: the Result was wiped back to BASE so this kind of
    -- one-sided change vanished whenever any conflict existed in the same
    -- file.
    assert.is_true(
      merged_text:find("ours_only", 1, true) ~= nil,
      "Result must contain OURS' one-sided change. Pre-fix: Result was just BASE.\nGot:\n" .. merged_text
    )

    -- The true conflict region must still be BASE for the user to resolve.
    assert.is_true(
      merged_text:find("a_modified", 1, true) == nil,
      "Two-sided conflict must NOT be auto-resolved to one side"
    )
    assert.is_true(
      merged_text:find("a_other", 1, true) == nil,
      "Two-sided conflict must NOT be auto-resolved to the other side"
    )
    assert.is_true(
      merged_text:find('"a"', 1, true) ~= nil,
      "Two-sided conflict must be left as BASE for the user to resolve"
    )

    -- There must be exactly one conflict block (the "a" line modification).
    assert.equal(1, #conflict_blocks,
      "There should be exactly one true conflict (the modification of 'a')")

    -- The Result must never contain raw `git merge` conflict markers — those
    -- are the on-disk representation, not what the merge tool's Result pane
    -- should show.
    for _, marker in ipairs({ "<<<<<<<", "=======", ">>>>>>>" }) do
      assert.is_true(
        merged_text:find(marker, 1, true) == nil,
        "Result buffer must not contain raw conflict markers: " .. marker
      )
    end
  end)
end)
