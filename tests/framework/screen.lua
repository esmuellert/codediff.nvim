-- An embedded Neovim UI for assertions on rendered cells, not extmark metadata.
-- Uses Neovim's bundled MessagePack and libuv; no Python or external UI dependency.
local Screen = {}
Screen.__index = Screen

local uv = vim.uv or vim.loop

local function blank_row(width)
  local row = {}
  for col = 1, width do
    row[col] = { " ", 0 }
  end
  return row
end

function Screen:_redraw(events)
  for _, event in ipairs(events) do
    local name = event[1]
    for i = 2, #event do
      local args = event[i]
      if name == "grid_resize" and args[1] == 1 then
        self.width, self.height = args[2], args[3]
        self.grid = {}
        for row = 1, self.height do
          self.grid[row] = blank_row(self.width)
        end
      elseif name == "grid_clear" and args[1] == 1 then
        for row = 1, self.height do
          self.grid[row] = blank_row(self.width)
        end
      elseif name == "grid_line" and args[1] == 1 then
        local row, col, highlight = self.grid[args[2] + 1], args[3] + 1, 0
        for _, cell in ipairs(args[4]) do
          highlight = cell[2] or highlight
          for _ = 1, cell[3] or 1 do
            row[col] = { cell[1], highlight }
            col = col + 1
          end
        end
      elseif name == "grid_scroll" and args[1] == 1 then
        local top, bottom, left, right, rows, cols = unpack(args, 2)
        local old = {}
        for row = top + 1, bottom do
          old[row] = {}
          for col = left + 1, right do
            old[row][col] = self.grid[row][col]
          end
        end
        for row = top + 1, bottom do
          for col = left + 1, right do
            local source = old[row + rows]
            self.grid[row][col] = source and source[col + cols] or { " ", 0 }
          end
        end
      elseif name == "hl_attr_define" then
        self.highlights[args[1]] = args[2]
      elseif name == "flush" then
        self.flushes = self.flushes + 1
      end
    end
  end
end

function Screen.new(width, height)
  local self = setmetatable({ next_id = 0, responses = {}, grid = {}, highlights = {}, flushes = 0, stderr = "" }, Screen)
  self.stdin, self.stdout, self.errpipe = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local err
  self.process, err = uv.spawn(vim.v.progpath, {
    args = { "--embed", "--noplugin", "-u", "tests/init.lua", "-i", "NONE" },
    cwd = vim.fn.getcwd(),
    stdio = { self.stdin, self.stdout, self.errpipe },
  }, function(code)
    self.exit_code = code
  end)
  if not self.process then
    self:close()
    error("Cannot start embedded Neovim: " .. tostring(err))
  end

  local unpacker = vim.mpack.Unpacker()
  self.stdout:read_start(function(read_error, data)
    if read_error then
      self.error = read_error
    end
    if not data then
      return
    end
    local ok, decode_error = pcall(function()
      local pos = 1
      while pos <= #data do
        local message
        message, pos = unpacker(data, pos)
        if message then
          if message[1] == 1 then
            self.responses[message[2]] = message
          elseif message[1] == 2 and message[2] == "redraw" then
            self:_redraw(message[3])
          end
        end
      end
    end)
    if not ok then
      self.error = decode_error
    end
  end)
  self.errpipe:read_start(function(_, data)
    self.stderr = self.stderr .. (data or "")
  end)

  local ok, start_error = pcall(function()
    self:request("nvim_ui_attach", { width or 100, height or 30, { rgb = true, ext_linegrid = true } })
    self:exec([[
      vim.o.showtabline = 0
      vim.o.laststatus = 0
      vim.o.showmode = false
      vim.o.ruler = false
      vim.o.shortmess = 'atIF'
      vim.o.scrolloff = 0
      vim.o.sidescrolloff = 0
    ]])
    self:flush()
  end)
  if not ok then
    self:close()
    error(start_error)
  end
  return self
end

function Screen:request(method, args)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.stdin:write(vim.mpack.encode({ 0, id, method, args or {} }))
  local ready = vim.wait(10000, function()
    return self.responses[id] ~= nil or self.error ~= nil or self.exit_code ~= nil
  end, 1)
  local response = self.responses[id]
  self.responses[id] = nil
  assert(ready and response and not self.error, string.format("RPC %s failed: %s\n%s", method, tostring(self.error or self.exit_code or "timeout"), self.stderr))
  assert(response[3] == vim.NIL, string.format("RPC %s: %s", method, vim.inspect(response[3])))
  if response[4] ~= vim.NIL then
    return response[4]
  end
end

function Screen:exec(code, args)
  return self:request("nvim_exec_lua", { code, args or {} })
end

function Screen:command(command)
  return self:request("nvim_command", { command })
end

function Screen:input(keys)
  return self:request("nvim_input", { keys })
end

function Screen:flush()
  local before = self.flushes
  self:command("redraw!")
  self:request("nvim_eval", { "0" })
  assert(
    vim.wait(5000, function()
      return self.flushes > before
    end, 1),
    "No UI flush after redraw"
  )
end

function Screen:wait_for(predicate, message)
  assert(vim.wait(10000, predicate, 10), (message or "Embedded Neovim did not become ready") .. "\n" .. self.stderr)
  self:flush()
end

-- Screen coordinates here are one-based, including UI columns (not UTF-8 bytes).
function Screen:text(row, col, width)
  local text = {}
  for index = col, col + width - 1 do
    text[#text + 1] = self.grid[row][index][1]
  end
  return table.concat(text)
end

function Screen:highlight(row, col)
  return self.highlights[self.grid[row][col][2]] or {}
end

function Screen:foreground(row, col)
  return self:highlight(row, col).foreground
end

function Screen:expect_rows(row, col, expected, label)
  for index, text in ipairs(expected) do
    assert.equals(text, self:text(row + index - 1, col, vim.fn.strdisplaywidth(text)), string.format("%s, display row %d", label or "screen", index))
  end
end

function Screen:close()
  if self.process and not self.process:is_closing() then
    if self.exit_code == nil then
      self.stdin:write(vim.mpack.encode({ 0, self.next_id + 1, "nvim_command", { "qa!" } }))
      if not vim.wait(2000, function()
        return self.exit_code ~= nil
      end, 10) then
        self.process:kill("sigterm")
        vim.wait(2000, function()
          return self.exit_code ~= nil
        end, 10)
      end
    end
    self.process:close()
  end
  for _, pipe in ipairs({ self.stdin, self.stdout, self.errpipe }) do
    if not pipe:is_closing() then
      pipe:close()
    end
  end
end

return Screen
