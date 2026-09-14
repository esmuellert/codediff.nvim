-- Isolated Git worktree fixtures. Seeds are immutable; each case owns its refs,
-- object database, index and worktree beneath one disposable TMP directory.
local M = {}
local uv = vim.uv or vim.loop
local seeds, owned = {}, {}
local project_root = require("tests.support").project_root

local function run(argv, opts)
  return vim.system(argv, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

local function checked(argv, expected, opts)
  local result = run(argv, opts)
  assert.equals(expected or 0, result.code, table.concat(argv, " ") .. "\n" .. (result.stderr or ""))
  return result.stdout or "", result.code
end

function M.git(dir, args)
  if type(args) == "table" then
    local argv = { "git", "-C", dir }
    vim.list_extend(argv, args)
    local result = run(argv)
    return (result.stdout or "") .. (result.stderr or ""), result.code
  end
  local root = vim.fn.has("win32") == 1 and ('"' .. dir .. '"') or vim.fn.shellescape(dir)
  local output = vim.fn.system("git -C " .. root .. " " .. args)
  return output, vim.v.shell_error
end

local function remove(root)
  if not owned[root] then
    return
  end
  local cwd = vim.fn.getcwd():gsub("\\", "/")
  if cwd == root or cwd:sub(1, #root + 1) == root .. "/" then
    vim.fn.chdir(project_root)
  end
  if vim.fn.delete(root, "rf") ~= 0 then
    assert(
      vim.wait(2000, function()
        return vim.fn.delete(root, "rf") == 0 or vim.fn.isdirectory(root) == 0
      end, 25),
      "Cannot remove fixture directory: " .. root
    )
  end
  owned[root] = nil
end

local function directory()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  root = assert(uv.fs_realpath(root)):gsub("\\", "/")
  owned[root] = true
  return root
end

local function repository(dir)
  local repo = { dir = dir }
  local commit_number = 0

  function repo.path(filename)
    return repo.dir .. "/" .. filename
  end

  function repo.git(args, expected)
    local output, code = M.git(repo.dir, args)
    if expected ~= nil then
      assert.equals(expected, code, "git " .. vim.inspect(args) .. "\n" .. output)
    end
    return output, code
  end

  function repo.command(args, expected, opts)
    local argv = { "git", "-C", repo.dir }
    vim.list_extend(argv, args)
    return checked(argv, expected, opts)
  end

  function repo.git_path(name)
    local value = vim.trim(repo.command({ "rev-parse", "--path-format=absolute", "--git-path", name }))
    return (value:gsub("\\", "/"))
  end

  function repo.write_file(filename, lines)
    local target = repo.path(filename)
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    assert.equals(0, vim.fn.writefile(lines, target), "Cannot write fixture file: " .. target)
    return target
  end

  function repo.read_file(filename)
    return vim.fn.readfile(repo.path(filename))
  end

  function repo.write_bytes(filename, value)
    vim.fn.mkdir(vim.fn.fnamemodify(repo.path(filename), ":h"), "p")
    local file = assert(uv.fs_open(repo.path(filename), "w", 420))
    assert(uv.fs_write(file, value, 0))
    assert(uv.fs_close(file))
  end

  function repo.replace(filename, row, value)
    local content = repo.read_file(filename)
    content[row] = value
    repo.write_file(filename, content)
    return content
  end

  function repo.blob(revision, filename)
    return repo.command({ "show", revision .. ":" .. filename }, 0, { text = false })
  end

  function repo.blob_lines(revision, filename)
    local value = repo.blob(revision, filename)
    return value == "" and {} or vim.split(value:gsub("\n$", ""), "\n", { plain = true })
  end

  -- Update only the index: no intermediate working-tree state or checkout is
  -- needed, including for Git paths that the host filesystem cannot represent.
  function repo.write_index(filename, content)
    if type(content) == "table" then
      content = table.concat(content, "\n") .. (#content > 0 and "\n" or "")
    end
    local oid = vim.trim(repo.command({ "hash-object", "-w", "--stdin" }, 0, { stdin = content }))
    repo.command({ "update-index", "--add", "--cacheinfo", "100644," .. oid .. "," .. filename })
    return oid
  end

  function repo.commit(message)
    commit_number = commit_number + 1
    local date = string.format("2001-01-%02dT12:00:00+00:00", commit_number)
    repo.command({ "add", "-A" })
    repo.command({ "commit", "--allow-empty", "-m", message }, 0, { env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } })
    return vim.trim(repo.command({ "rev-parse", "HEAD" }))
  end

  return repo
end

local function configure(repo)
  for key, value in pairs({
    ["user.name"] = "Test",
    ["user.email"] = "test@test.com",
    ["commit.gpgsign"] = "false",
    ["tag.gpgsign"] = "false",
    ["core.autocrlf"] = "false",
    ["core.quotePath"] = "false",
    ["core.hooksPath"] = repo.git_path("hooks"),
  }) do
    repo.command({ "config", key, value })
  end
end

local function seed_for(key, build, object_format)
  if seeds[key] then
    return seeds[key]
  end
  local root = directory()
  local ok, value = pcall(function()
    local argv = { "git", "init", "-q" }
    if object_format then
      argv[#argv + 1] = "--object-format=" .. object_format
    end
    argv[#argv + 1] = root
    checked(argv)
    local repo = repository(root)
    repo.command({ "symbolic-ref", "HEAD", "refs/heads/main" })
    configure(repo)
    local metadata = build and build(repo) or { base = repo.commit("fixture bootstrap") }
    assert.equals("", repo.command({ "status", "--porcelain" }), "fixture seed must be clean")
    return { root = root, metadata = metadata }
  end)
  if not ok then
    remove(root)
    error(value)
  end
  seeds[key] = value
  return value
end

-- build runs once per spec process. A bare clone per case prevents shared refs
-- and object-file mutations from coupling otherwise independent worktrees.
function M.new(opts)
  opts = opts or {}
  for _, name in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES" }) do
    assert(not vim.env[name] or vim.env[name] == "", "Refusing fixture creation with inherited " .. name)
  end
  local format = opts.object_format or "sha1"
  local key = (opts.key or "empty") .. ":" .. format
  local seed = seed_for(key, opts.build, format)
  local root = directory()
  local ok, value = pcall(function()
    local common, worktree = root .. "/repository.git", root .. "/worktree"
    if opts.bare then
      checked({ "git", "clone", "--bare", "--no-hardlinks", "--quiet", seed.root, common })
    elseif opts.worktree == false then
      checked({ "git", "clone", "--no-hardlinks", "--quiet", seed.root, worktree })
      common = worktree .. "/.git"
    else
      checked({ "git", "clone", "--bare", "--no-hardlinks", "--quiet", seed.root, common })
      checked({ "git", "--git-dir", common, "worktree", "add", "--quiet", worktree, "main" })
    end
    local repo = repository(opts.bare and common or worktree)
    if not opts.bare then
      repo.dir = vim.trim(repo.command({ "rev-parse", "--show-toplevel" })):gsub("\\", "/")
    end
    repo.root, repo.common_dir = root, common
    repo.seed = vim.deepcopy(seed.metadata)
    repo.command({ "remote", "remove", "origin" })
    configure(repo)
    if opts.unborn then
      if opts.bare then
        repo.command({ "update-ref", "-d", "refs/heads/main" })
      else
        repo.command({ "checkout", "--orphan", "fixture-unborn" })
        repo.command({ "rm", "-rf", "--ignore-unmatch", "." })
        repo.command({ "branch", "-D", "main" })
      end
      repo.command({ "symbolic-ref", "HEAD", "refs/heads/main" })
    end
    repo.cleanup = function()
      remove(root)
    end
    if opts.bare then
      assert.equals("true", vim.trim(repo.command({ "rev-parse", "--is-bare-repository" })))
    else
      local valid = opts.worktree == false and vim.fn.isdirectory(repo.path(".git")) or vim.fn.filereadable(repo.path(".git"))
      assert.equals(1, valid, "fixture Git layout was not created")
    end
    return repo
  end)
  if not ok then
    remove(root)
    error(value)
  end
  return value
end

-- Also collect seeds and fixtures whose setup failed before after_each ran.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("CodeDiffTestRepositories", { clear = true }),
  callback = function()
    for root in pairs(owned) do
      remove(root)
    end
  end,
})

return M
