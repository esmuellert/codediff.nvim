local pull_request = require("codediff.core.pull_request")
local h = dofile("tests/helpers.lua")

local function run(cwd, args)
  local command = { "git", "-C", cwd }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert.equals(0, result.code, result.stderr or result.stdout)
  return vim.trim(result.stdout or "")
end

local function fetch_pull_request(repo, number, opts)
  local done = false
  local result_error
  local result
  pull_request.fetch(number, repo.dir, opts or {}, function(err, revisions)
    result_error = err
    result = revisions
    done = true
  end)
  assert.is_true(
    vim.wait(5000, function()
      return done
    end, 10),
    "pull request fetch did not finish"
  )
  return result_error, result
end

local function list_cached_refs(repo, prefix)
  local output = run(repo.dir, { "for-each-ref", "--format=%(refname)", prefix or "refs/codediff/pull-requests/" })
  return vim.split(output, "\n", { trimempty = true })
end

local function wait_for_cleanup(start)
  local done = false
  local result_error
  local deleted
  start(function(err, count)
    result_error = err
    deleted = count
    done = true
  end)
  assert.is_true(
    vim.wait(5000, function()
      return done
    end, 10),
    "pull request cleanup did not finish"
  )
  return result_error, deleted
end

describe("pull request fetching", function()
  local repo
  local remote, remote_fixture
  local base_revision
  local head_revision
  local merge_revision
  local review_base

  before_each(function()
    repo = h.create_temp_git_repo()
    remote_fixture = require("tests.framework.repository").new({ bare = true, unborn = true })
    remote = remote_fixture.dir

    repo.write_file("review.txt", { "base" })
    repo.git("add review.txt")
    repo.git("commit -m base")

    repo.git("checkout -b feature")
    repo.write_file("review.txt", { "feature" })
    repo.write_file("ignored.txt", { "ignored" })
    repo.git("add review.txt ignored.txt")
    repo.git("commit -m feature")
    head_revision = run(repo.dir, { "rev-parse", "HEAD" })

    repo.git("checkout main")
    repo.write_file("main.txt", { "main" })
    repo.git("add main.txt")
    repo.git("commit -m main")
    base_revision = run(repo.dir, { "rev-parse", "HEAD" })

    run(repo.dir, { "remote", "add", "origin", remote })
    run(repo.dir, { "branch", "release", base_revision })
    run(repo.dir, { "push", "origin", "main", "release" })
    run(repo.dir, { "checkout", "-b", "synthetic-merge" })
    run(repo.dir, { "merge", "--no-ff", "feature", "-m", "pull request merge" })
    merge_revision = run(repo.dir, { "rev-parse", "HEAD" })
    run(repo.dir, { "push", "origin", head_revision .. ":refs/pull/7/head" })
    run(repo.dir, { "push", "origin", merge_revision .. ":refs/pull/7/merge" })
    run(repo.dir, { "push", "origin", head_revision .. ":refs/merge-requests/8/head" })
    run(repo.dir, { "push", "origin", head_revision .. ":refs/pull/9/head" })
    run(repo.dir, { "push", "origin", merge_revision .. ":refs/merge-requests/10/merge" })
    review_base = run(repo.dir, { "merge-base", base_revision, head_revision })
    repo.git("checkout main")
  end)

  after_each(function()
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
    if remote_fixture then
      remote_fixture.cleanup()
      remote_fixture = nil
    end
  end)

  it("uses GitHub and Azure DevOps merge refs", function()
    local err, revisions = fetch_pull_request(repo, 7)

    assert.is_nil(err)
    assert.equals(base_revision, revisions.base_revision)
    assert.equals(head_revision, revisions.head_revision)
    assert.equals("origin", revisions.remote)
    assert.equals(merge_revision, run(repo.dir, { "rev-parse", "refs/codediff/pull-requests/origin/7/merge" }))
  end)

  it("uses a GitLab merge ref", function()
    local err, revisions = fetch_pull_request(repo, 10)

    assert.is_nil(err)
    assert.equals(base_revision, revisions.base_revision)
    assert.equals(head_revision, revisions.head_revision)
  end)

  it("falls back to a GitLab head ref and the remote default branch", function()
    local err, revisions = fetch_pull_request(repo, 8)

    assert.is_nil(err)
    assert.equals(base_revision, revisions.base_revision)
    assert.equals(head_revision, revisions.head_revision)
    assert.equals(head_revision, run(repo.dir, { "rev-parse", "refs/codediff/pull-requests/origin/8/head" }))
  end)

  it("updates its cached ref when the pull request head moves", function()
    local first_err, first = fetch_pull_request(repo, 8)
    assert.is_nil(first_err)
    assert.equals(head_revision, first.head_revision)

    run(repo.dir, { "checkout", "-b", "rewritten", head_revision .. "^" })
    repo.write_file("review.txt", { "rewritten" })
    repo.git("add review.txt")
    repo.git("commit -m update")
    local updated_head = run(repo.dir, { "rev-parse", "HEAD" })
    run(repo.dir, { "push", "--force", "origin", updated_head .. ":refs/merge-requests/8/head" })

    local second_err, second = fetch_pull_request(repo, 8)
    assert.is_nil(second_err)
    assert.equals(updated_head, second.head_revision)
    assert.equals(updated_head, run(repo.dir, { "rev-parse", "refs/codediff/pull-requests/origin/8/head" }))
  end)

  it("uses an explicit target branch when no merge ref exists", function()
    local err, revisions = fetch_pull_request(repo, 9, { base = "release" })

    assert.is_nil(err)
    assert.equals(base_revision, revisions.base_revision)
    assert.equals(head_revision, revisions.head_revision)
  end)

  it("cleans one pull request without touching another remote or number", function()
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/7/merge", merge_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/70/head", head_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/upstream/7/head", head_revision })

    local err, deleted = wait_for_cleanup(function(callback)
      pull_request.clean(7, repo.dir, { remote = "origin" }, callback)
    end)

    assert.is_nil(err)
    assert.equals(1, deleted)
    assert.equals(0, #list_cached_refs(repo, "refs/codediff/pull-requests/origin/7/"))
    assert.equals(1, #list_cached_refs(repo, "refs/codediff/pull-requests/origin/70/"))
    assert.equals(1, #list_cached_refs(repo, "refs/codediff/pull-requests/upstream/7/"))
  end)

  it("cleans all refs with optional remote scoping", function()
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/7/merge", merge_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/8/head", head_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/8/base", base_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/upstream/9/head", head_revision })
    run(repo.dir, { "update-ref", "refs/codediff/other", head_revision })

    local origin_err, origin_deleted = wait_for_cleanup(function(callback)
      pull_request.clean_all(repo.dir, { remote = "origin" }, callback)
    end)

    assert.is_nil(origin_err)
    assert.equals(3, origin_deleted)
    assert.equals(1, #list_cached_refs(repo))

    local all_err, all_deleted = wait_for_cleanup(function(callback)
      pull_request.clean_all(repo.dir, {}, callback)
    end)

    assert.is_nil(all_err)
    assert.equals(1, all_deleted)
    assert.equals(0, #list_cached_refs(repo))
    assert.equals(head_revision, run(repo.dir, { "rev-parse", "refs/codediff/other" }))
  end)

  it("opens the review through the pr subcommand", function()
    run(repo.dir, { "remote", "rename", "origin", "upstream" })
    vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(repo.dir) .. " pr 7 --remote upstream --base release -- review.txt")

    local session
    assert.is_true(
      vim.wait(10000, function()
        local lifecycle = require("codediff.ui.lifecycle")
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
          local candidate = lifecycle.get_session(tabpage)
          if candidate and candidate.panel and candidate.panel.name == "explorer" then
            session = candidate
            return candidate.original_revision == review_base and candidate.modified_revision == head_revision
          end
        end
        return false
      end, 20),
      "pull request review did not open"
    )
    assert.is_not_nil(session)
    local files = require("codediff.ui.explorer.tree").get_all_files(session.panel.view.tree)
    assert.equals(1, #files)
    assert.equals("review.txt", files[1].data.path)
    assert.equals("main", run(repo.dir, { "branch", "--show-current" }))
    assert.equals("", run(repo.dir, { "status", "--porcelain" }))
  end)

  it("cleans cached refs through the pr clean commands", function()
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/7/merge", merge_revision })
    run(repo.dir, { "update-ref", "refs/codediff/pull-requests/origin/8/head", head_revision })

    local messages = {}
    local original_notify = vim.notify
    vim.notify = function(text)
      messages[#messages + 1] = tostring(text)
    end

    vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(repo.dir) .. " pr clean 7")
    local cleaned_one = vim.wait(5000, function()
      return #messages >= 1
    end, 10)
    assert.is_true(cleaned_one, "single-PR cleanup did not finish")
    assert.equals(0, #list_cached_refs(repo, "refs/codediff/pull-requests/origin/7/"))
    assert.equals(1, #list_cached_refs(repo, "refs/codediff/pull-requests/origin/8/"))

    vim.cmd("CodeDiff --repo " .. vim.fn.fnameescape(repo.dir) .. " pr clean --all")
    local cleaned_all = vim.wait(5000, function()
      return #messages >= 2
    end, 10)
    vim.notify = original_notify

    assert.is_true(cleaned_all, "all-PR cleanup did not finish")
    assert.equals(0, #list_cached_refs(repo))
    assert.matches("Removed 1 cached ref", messages[1])
    assert.matches("Removed 1 cached pull request ref", messages[2])
  end)

  it("rejects an invalid pull request number", function()
    local message
    local original_notify = vim.notify
    vim.notify = function(text)
      message = tostring(text)
    end
    vim.cmd("CodeDiff pr nope")
    vim.notify = original_notify

    assert.matches("Usage: :CodeDiff pr", message)
  end)

  it("rejects clean without a pull request number or --all", function()
    local message
    local original_notify = vim.notify
    vim.notify = function(text)
      message = tostring(text)
    end
    vim.cmd("CodeDiff pr clean")
    vim.notify = original_notify

    assert.matches("Usage: :CodeDiff pr clean", message)
  end)

  it("reports a missing pull request", function()
    local err, revisions = fetch_pull_request(repo, 404)

    assert.is_nil(revisions)
    assert.matches("Pull request #404 was not found", err)
  end)
end)
