-- Test: Verify virtual buffers don't fire FileType autocmd (prevents LSP attachment)
-- This test simulates what LSP plugins like eslint/terraform-ls do:
-- they listen for FileType events and call vim.lsp.start() to attach.
-- Setting filetype on virtual buffers causes these plugins to attach,
-- sending textDocument/didOpen with codediff:// URI which crashes servers.
--
-- This test should FAIL if vim.bo[buf].filetype is set on virtual buffers
-- and PASS when TreeSitter is started directly without setting filetype.

local virtual_file = require("codediff.core.virtual_file")
local h = require('tests.support')

describe("Virtual buffer LSP prevention", function()
  it("prevents LSP attachment while keeping TreeSitter active", function()
    -- Ensure virtual file autocmds are registered (plugin file may not be sourced in test subprocess)
    virtual_file.setup()
    -- Create a temp git repo
    local repo = h.create_temp_git_repo()
    local temp_dir = repo.dir

    local f = io.open(temp_dir .. "/app.js", "w")
    f:write("const x = 1;\nconsole.log(x);\n")
    f:close()
    repo.git("add .")
    repo.git('commit -m "initial"')

    -- Setup a mock LSP that mimics eslint/terraform-ls behavior:
    -- Listen for FileType and call vim.lsp.start() to attach.
    -- Before the fix: FileType fires → LSP attaches to virtual buffer.
    -- After the fix: FileType never fires → LSP never sees the buffer.
    local mock_lsp_attach_attempts = {}
    local mock_autocmd_id = vim.api.nvim_create_autocmd("FileType", {
      pattern = { "javascript" },
      callback = function(args)
        local bufname = vim.api.nvim_buf_get_name(args.buf)
        table.insert(mock_lsp_attach_attempts, {
          buf = args.buf,
          bufname = bufname,
          is_virtual = bufname:match("^codediff://") ~= nil,
        })
        -- Mimic what real LSP plugins do: call vim.lsp.start()
        -- Use 'cat' as a trivial LSP server (accepts stdin, does nothing)
        pcall(vim.lsp.start, {
          name = "mock-eslint",
          cmd = { "cat" },
          root_dir = temp_dir,
        })
      end,
    })

    -- Create a virtual buffer (this is what CodeDiff does internally)
    local commit = vim.trim(repo.git("rev-parse HEAD"))
    local url = "codediff:///" .. temp_dir .. "///" .. commit .. "/app.js"
    vim.cmd("edit " .. vim.fn.fnameescape(url))
    local buf = vim.api.nvim_get_current_buf()

    -- Wait for async content loading
    vim.wait(3000, function()
      if not vim.api.nvim_buf_is_valid(buf) then return false end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return #lines > 0 and lines[1] ~= ""
    end)

    -- 1. Mock LSP should NOT have been triggered for virtual buffers
    local virtual_attempts = vim.tbl_filter(
      function(a) return a.is_virtual end,
      mock_lsp_attach_attempts
    )
    assert.are.equal(0, #virtual_attempts,
      "Mock LSP should NOT have been triggered for virtual buffers (FileType should not fire)")

    -- 2. No LSP clients should be attached to the virtual buffer
    local clients = vim.lsp.get_clients({ bufnr = buf })
    assert.are.equal(0, #clients,
      "No LSP clients should be attached to virtual buffer")

    -- 3. filetype should be empty (prevents FileType autocmd)
    assert.are.equal("", vim.bo[buf].filetype,
      "filetype should be empty on virtual buffer")

    -- 4. TreeSitter should be active if parser is available
    -- (CI environments may not have all TreeSitter parsers installed)
    local has_parser = pcall(vim.treesitter.language.inspect, "javascript")
    if has_parser then
      local ok, parser = pcall(vim.treesitter.get_parser, buf)
      assert.is_true(ok and parser ~= nil,
        "TreeSitter parser should be active on virtual buffer")
    end

    -- 5. buftype should be nowrite
    assert.are.equal("nowrite", vim.bo[buf].buftype,
      "buftype should be nowrite")

    -- Cleanup: stop any mock LSP clients that might have started
    for _, client in ipairs(vim.lsp.get_clients({ name = "mock-eslint" })) do
      pcall(client.stop, client)
    end
    vim.api.nvim_del_autocmd(mock_autocmd_id)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    repo.cleanup()
  end)

  it("does not fire FileType for added/deleted files (regression: #323)", function()
    -- Regression for issue #323: when opening a diff for a file that does not
    -- exist at the requested revision (added or deleted), virtual_file used to
    -- set `vim.bo[buf].filetype = ""` directly. That assignment fires a
    -- FileType autocmd with an empty filetype, which crashes user/plugin code
    -- that keys memoize caches on the filetype string. The fix suppresses the
    -- event via `noautocmd setlocal filetype=` (matching the populated branch).
    virtual_file.setup()
    local repo = h.create_temp_git_repo()
    local f = io.open(repo.dir .. "/kept.lua", "w")
    f:write("kept\n")
    f:close()
    repo.git("add .")
    repo.git('commit -m "initial"')

    -- Listen for FileType events on codediff:// buffers. Any event with an
    -- empty filetype is the regression we are guarding against.
    local empty_ft_events = {}
    local autocmd_id = vim.api.nvim_create_autocmd("FileType", {
      callback = function(args)
        local name = vim.api.nvim_buf_get_name(args.buf)
        if name:match("^codediff://") then
          table.insert(empty_ft_events, {
            buf = args.buf,
            ft = vim.bo[args.buf].filetype,
            name = name,
          })
        end
      end,
    })

    -- Open a codediff:// URL for a file that does NOT exist at HEAD.
    -- This is the path through virtual_file.load_virtual_buffer_content's
    -- error branch where filetype gets cleared.
    local url = "codediff:///" .. repo.dir .. "///HEAD/does_not_exist.lua"
    vim.cmd("edit " .. vim.fn.fnameescape(url))
    local buf = vim.api.nvim_get_current_buf()

    -- Wait for async load_virtual_buffer_content to complete; we know it
    -- completed when the "missing file" placeholder is in place.
    vim.wait(2000, function()
      if not vim.api.nvim_buf_is_valid(buf) then return false end
      return vim.bo[buf].modifiable == false
    end)

    -- No FileType event should have fired on the codediff:// buffer with an
    -- empty filetype (that's the crash trigger).
    local empty_ones = vim.tbl_filter(function(e) return e.ft == "" end, empty_ft_events)
    assert.are.equal(0, #empty_ones,
      "FileType autocmd fired with empty filetype on virtual buffer (issue #323): " ..
      vim.inspect(empty_ones))

    -- The filetype is still empty (still preventing LSP attachment), the event
    -- just wasn't broadcast.
    assert.are.equal("", vim.bo[buf].filetype,
      "filetype should still be empty on the missing-file virtual buffer")

    vim.api.nvim_del_autocmd(autocmd_id)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    repo.cleanup()
  end)
end)
