-- UI rendering for explorer (create split, tree, keymaps)
local M = {}

local Tree = require("codediff.ui.lib.tree")
local Split = require("codediff.ui.lib.split")
local config = require("codediff.config")
local path = require("codediff.core.path")
local lifecycle = require("codediff.ui.lifecycle")
local nodes_module = require("codediff.ui.explorer.nodes")
local tree_module = require("codediff.ui.explorer.tree")
local keymaps_module = require("codediff.ui.explorer.keymaps")
local refresh_module = require("codediff.ui.explorer.refresh")
local welcome = require("codediff.ui.welcome")

local function should_show_welcome(explorer)
  if not explorer or not explorer.git_root or explorer.dir1 or explorer.dir2 then
    return false
  end

  local status = explorer.status_result or {}
  local total_files = #(status.unstaged or {}) + #(status.staged or {}) + #(status.conflicts or {})
  return total_files == 0
end

local function show_welcome_page(explorer)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(explorer.tabpage)
  if not session then
    return false
  end

  local mod_win = session.modified_win
  if not mod_win or not vim.api.nvim_win_is_valid(mod_win) then
    return false
  end

  if session.layout == "inline" then
    local welcome_buf = welcome.create_buffer(vim.api.nvim_win_get_width(mod_win), vim.api.nvim_win_get_height(mod_win))
    require("codediff.ui.view.inline_view").show_welcome(explorer.tabpage, welcome_buf)
    return true
  end

  local orig_win = session.original_win
  local width = vim.api.nvim_win_get_width(mod_win)
  local height = vim.api.nvim_win_get_height(mod_win)
  if orig_win and vim.api.nvim_win_is_valid(orig_win) then
    width = vim.api.nvim_win_get_width(orig_win) + width + 1
    height = vim.api.nvim_win_get_height(orig_win)
  end

  local welcome_buf = welcome.create_buffer(width, height)
  require("codediff.ui.view.side_by_side").show_welcome(explorer.tabpage, welcome_buf)
  return true
end

--- Open a two-sided diff on the next tick, unless the user has moved on.
--- view.update on a stale target swaps buffers under the newer one, destroys
--- codediff:// buffers mid-load (bufhidden=wipe), and resets single_pane.
local function open_diff_when_still_selected(ctx, sides)
  vim.schedule(function()
    if ctx.explorer.current_file_path ~= ctx.file_path then
      return
    end
    ---@type SessionConfig
    local session_config = {
      git_root = ctx.git_root,
      original = sides.original,
      modified = sides.modified,
      original_revision = sides.original_revision,
      modified_revision = sides.modified_revision,
      conflict = sides.conflict,
    }
    require("codediff.ui.view").update(ctx.tabpage, session_config, ctx.jump)
  end)
end

--- conflict_ours_position names where OURS sits on screen; original_win is on
--- the left after the conflict view's win_splitmove(rightbelow=false).
--- @return string original_rev, string modified_rev
local function conflict_revisions()
  if (config.options.diff.conflict_ours_position or "right") == "right" then
    return ":3", ":2" -- THEIRS left, OURS right
  end
  return ":2", ":3" -- OURS left, THEIRS right
end

--- Whether `file_path` is staged, per the explorer's last status.
--- nil when there is no status to consult.
--- @return boolean|nil
local function has_staged_changes(explorer, file_path)
  local status = explorer.status_result
  if not status then
    return nil
  end
  for _, staged_file in ipairs(status.staged or {}) do
    if staged_file.path == file_path then
      return true
    end
  end
  return false
end

--- True when the session already shows exactly this comparison. Opening it
--- again only repaints, and the repaint fires the next refresh: #317, #401.
--- @param group string "staged" | "unstaged" | "conflicts"
--- @return boolean
local function already_showing(session, explorer, file_path, abs_path, group)
  local same_file = (session.modified and session.modified.absolute == abs_path) or (session.original and session.original.absolute == abs_path)
  if not same_file then
    return false
  end

  -- :2/:3 are mutable, so the staged-base check below would see a change on
  -- every refresh and rebuild forever.
  if group == "conflicts" then
    return session.result_win ~= nil and vim.api.nvim_win_is_valid(session.result_win)
  end

  -- The two views compare against different things, so the same path is not
  -- the same diff.
  if (group == "staged") ~= (session.modified_revision == ":0") then
    return false
  end

  if group == "staged" then
    return true
  end

  -- Unstaged compares against :0 once the file has staged content, HEAD before
  -- that. No status to consult means nothing says the base moved.
  local staged = has_staged_changes(explorer, file_path)
  if staged == nil then
    return true
  end
  local base_is_index = session.original_revision ~= nil and session.original_revision:match("^:[0-3]$") ~= nil
  return staged == base_is_index
end

--- Expand every directory node beneath `node`, recursively.
local function expand_directories(tree, node)
  if not node:has_children() then
    return
  end
  for _, child_id in ipairs(node:get_child_ids()) do
    local child = tree:get_node(child_id)
    if child and child.data and child.data.type == "directory" then
      child:expand()
      expand_directories(tree, child)
    end
  end
end

--- Run `show` on the next tick, unless the user has moved on. The explorer
--- fires a selection per cursor movement, so a slow open must not paint over
--- a newer one.
--- @param show fun(is_inline: boolean)
local function show_when_still_selected(explorer, file_path, show)
  vim.schedule(function()
    if explorer.current_file_path ~= file_path then
      return
    end
    local session = lifecycle.get_session(explorer.tabpage)
    show(session ~= nil and session.layout == "inline")
  end)
end

function M.create(status_result, git_root, tabpage, width, base_revision, target_revision, opts)
  opts = opts or {}
  local is_dir_mode = not git_root -- nil git_root signals directory comparison mode

  -- Get explorer position and size from config
  local explorer_config = config.options.explorer or {}
  local position = explorer_config.position or "left"
  local size
  local text_width -- Width for text rendering (always horizontal width)

  if position == "bottom" or position == "top" then
    size = explorer_config.height or 15
    -- For bottom/top position, use full window width for text
    text_width = vim.o.columns
  else
    -- Use provided width or config width or default to 40 columns
    size = width or explorer_config.width or 40
    text_width = size
  end

  -- Create split window for explorer
  local split = Split({
    relative = "editor",
    position = position,
    size = size,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "codediff-explorer",
    },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
      signcolumn = "no",
      foldcolumn = "0",
      statuscolumn = "",
      spell = false,
      winfixwidth = true,
      winfixheight = true,
    },
  })

  -- Mount split first to get bufnr
  split:mount()
  pcall(vim.api.nvim_buf_set_name, split.bufnr, "CodeDiff Explorer [" .. tabpage .. "]")

  -- Honor the initial-visibility config: hide the split immediately if requested.
  -- toggle_explorer (actions.lua) uses split:hide/show to flip this at runtime;
  -- using split:hide() here matches that lifecycle so the user's toggle keymap
  -- continues to work correctly.
  if explorer_config.hidden then
    split:hide()
  end

  -- Track selected path and group for highlighting
  local selected_path = nil
  local selected_group = nil

  -- Create tree with buffer number
  local tree_data = tree_module.create_tree_data(status_result, git_root, base_revision, is_dir_mode, explorer_config.visible_groups)
  local tree = Tree({
    bufnr = split.bufnr,
    nodes = tree_data,
    prepare_node = function(node)
      -- Dynamically get current window width for responsive layout
      local current_width = text_width
      if split.winid and vim.api.nvim_win_is_valid(split.winid) then
        current_width = vim.api.nvim_win_get_width(split.winid)
      end
      return nodes_module.prepare_node(node, current_width, selected_path, selected_group)
    end,
  })

  -- Expand all groups by default before first render
  -- In tree mode, also expand all directories
  -- get_child_ids returns IDs, need to get actual nodes
  for _, node in ipairs(tree_data) do
    if node.data and node.data.type == "group" then
      node:expand()
    end
  end

  -- For tree mode, expand directories after initial render when we have node IDs
  if explorer_config.view_mode == "tree" then
    -- Directory nodes hang off the group nodes expanded above.
    for _, node in ipairs(tree_data) do
      expand_directories(tree, node)
    end
  end

  -- Render tree
  tree:render()

  -- Create explorer object early so we can reference it in keymaps
  local explorer = {
    split = split,
    tree = tree,
    bufnr = split.bufnr,
    winid = split.winid,
    git_root = git_root,
    tabpage = tabpage,
    dir1 = opts.dir1,
    dir2 = opts.dir2,
    base_revision = base_revision,
    target_revision = target_revision,
    pathspec = opts.pathspec, -- Scope (#74): re-applied on every auto-refresh
    status_result = status_result, -- Store initial status result
    on_file_select = nil, -- Will be set below
    current_file_path = nil, -- Track currently selected file
    current_file_group = nil, -- Track currently selected file's group (staged/unstaged)
    current_selection = nil, -- Full file selection used to replay current state
    is_hidden = explorer_config.hidden, -- Track visibility state
    visible_groups = vim.deepcopy(explorer_config.visible_groups or { staged = true, unstaged = true, conflicts = true }),
  }

  -- File selection callback - manages its own lifecycle
  local function on_file_select(file_data, opts)
    opts = opts or {}
    local git = require("codediff.core.git")
    local view = require("codediff.ui.view")
    local lifecycle = require("codediff.ui.lifecycle")

    local file_path = file_data.path
    local old_path = file_data.old_path -- For renames: path in original revision
    local group = file_data.group or "unstaged"
    local jump = not opts.no_jump and config.options.diff.jump_to_first_change

    -- Emit CodeDiffFileSelect User autocmd
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeDiffFileSelect",
      modeline = false,
      data = {
        tabpage = tabpage,
        path = file_path,
        status = file_data.status,
      },
    })

    -- Dir mode: Compare files from dir1 vs dir2 (no git)
    if is_dir_mode then
      local original = path.make_ref(file_path, explorer.dir1)
      local modified = path.make_ref(file_path, explorer.dir2)

      local session = lifecycle.get_session(tabpage)
      local showing_already = session
        and session.original
        and session.modified
        and session.original.absolute == original.absolute
        and session.modified.absolute == modified.absolute
      if showing_already and not opts.force then
        return
      end

      open_diff_when_still_selected({
        explorer = explorer,
        tabpage = tabpage,
        git_root = nil,
        file_path = file_path,
        jump = jump,
      }, { original = original, modified = modified })
      return
    end

    local abs_path = path.make_ref(file_path, git_root).absolute

    -- Handle untracked files: show file without diff
    if file_data.status == "??" then
      show_when_still_selected(explorer, file_data.path, function(is_inline)
        if is_inline then
          require("codediff.ui.view.inline_view").show_single_file(tabpage, abs_path, { side = "modified" })
        else
          require("codediff.ui.view.side_by_side").show_untracked_file(tabpage, abs_path)
        end
      end)
      return
    end

    -- Handle added files: only one side has the file
    if file_data.status == "A" then
      -- Which revision holds an added file depends on where it was added.
      local revision
      if base_revision and target_revision and target_revision ~= "WORKING" then
        revision = target_revision
      elseif group == "staged" then
        revision = ":0"
      end

      show_when_still_selected(explorer, file_data.path, function(is_inline)
        if not revision then
          -- Added in the working tree: read it off disk.
          if is_inline then
            require("codediff.ui.view.inline_view").show_single_file(tabpage, abs_path, { side = "modified" })
          else
            require("codediff.ui.view.side_by_side").show_untracked_file(tabpage, abs_path)
          end
          return
        end
        if is_inline then
          require("codediff.ui.view.inline_view").show_single_file(tabpage, file_path, {
            revision = revision,
            git_root = git_root,
            rel_path = file_path,
            side = "modified",
          })
        else
          require("codediff.ui.view.side_by_side").show_added_virtual_file(tabpage, git_root, file_path, revision)
        end
      end)
      return
    end

    -- Handle deleted files: show old content without diff
    if file_data.status == "D" then
      -- With a base_revision (`:CodeDiff HEAD~5` or `:CodeDiff A B`) the
      -- content lives there; HEAD and :0 yield nothing, the file is already
      -- gone. HEAD/:0 is only right for a plain explorer. Fixes #390.
      local revision = base_revision or ((group == "staged") and "HEAD" or ":0")

      show_when_still_selected(explorer, file_data.path, function(is_inline)
        if is_inline then
          require("codediff.ui.view.inline_view").show_single_file(tabpage, file_path, {
            revision = revision,
            git_root = git_root,
            rel_path = file_path,
            side = "original",
          })
        elseif base_revision then
          require("codediff.ui.view.side_by_side").show_deleted_virtual_file(tabpage, git_root, file_path, base_revision)
        else
          require("codediff.ui.view.side_by_side").show_deleted_file(tabpage, git_root, file_path, abs_path, group)
        end
      end)
      return
    end

    -- Check if this exact diff is already being displayed
    -- Same file can have different diffs (staged vs HEAD, working vs staged)
    local session = lifecycle.get_session(tabpage)
    if session and not opts.force and already_showing(session, explorer, file_path, abs_path, group) then
      return
    end

    if base_revision and target_revision and target_revision ~= "WORKING" then
      -- Two revision mode: Compare base vs target
      vim.schedule(function()
        -- Ignore stale async: see comment on the base_revision branch below.
        if explorer.current_file_path ~= file_path then
          return
        end
        ---@type SessionConfig
        local session_config = {
          git_root = git_root,
          original = path.make_ref(old_path or file_path, git_root),
          modified = path.make_ref(file_path, git_root),
          original_revision = base_revision,
          modified_revision = target_revision,
        }
        view.update(tabpage, session_config, jump)
      end)
      return
    end

    -- Use base_revision if provided, otherwise default to HEAD
    local ctx = {
      explorer = explorer,
      tabpage = tabpage,
      git_root = git_root,
      file_path = file_path,
      jump = jump,
    }

    local target_revision_single = base_revision or "HEAD"
    git.resolve_revision(target_revision_single, git_root, function(err_resolve, commit_hash)
      if err_resolve then
        vim.schedule(function()
          vim.notify(err_resolve, vim.log.levels.ERROR)
        end)
        return
      end

      if base_revision then
        -- A renamed file is read from its old name, which is what it was
        -- called at that revision.
        open_diff_when_still_selected(ctx, {
          original = path.make_ref(old_path or file_path, git_root),
          modified = path.make_ref(abs_path, git_root),
          original_revision = commit_hash,
        })
      elseif group == "conflicts" then
        local original_rev, modified_rev = conflict_revisions()
        open_diff_when_still_selected(ctx, {
          original = path.make_ref(file_path, git_root),
          modified = path.make_ref(file_path, git_root),
          original_revision = original_rev,
          modified_revision = modified_rev,
          conflict = true,
        })
      elseif group == "staged" then
        -- Index against HEAD. On a rename the two sides have different names.
        open_diff_when_still_selected(ctx, {
          original = path.make_ref(old_path or file_path, git_root),
          modified = path.make_ref(file_path, git_root),
          original_revision = commit_hash,
          modified_revision = ":0",
        })
      else
        -- Working tree against the index when the file has staged content,
        -- against HEAD when it does not.
        local is_staged = false
        for _, staged_file in ipairs((explorer.status_result or status_result).staged) do
          if staged_file.path == file_path then
            is_staged = true
            break
          end
        end

        open_diff_when_still_selected(ctx, {
          original = path.make_ref(file_path, git_root),
          modified = path.make_ref(abs_path, git_root),
          original_revision = is_staged and ":0" or commit_hash,
        })
      end
    end)
  end

  -- Wrap on_file_select to track current file and group
  explorer.on_file_select = function(file_data, opts)
    explorer.current_file_path = file_data.path
    explorer.current_file_group = file_data.group
    explorer.current_selection = vim.deepcopy(file_data)
    selected_path = file_data.path
    selected_group = file_data.group
    tree:render()
    on_file_select(file_data, opts)
  end

  -- Clear selection highlight (used when showing welcome page)
  explorer.clear_selection = function()
    selected_path = nil
    selected_group = nil
    tree:render()
  end

  -- Setup keymaps (delegated to keymaps module)
  keymaps_module.setup(explorer)

  -- Auto-open diff for the node under cursor after j/k (or arrow keys).
  -- Hooks j/k/<Down>/<Up> instead of CursorMoved so mouse clicks, :N jumps,
  -- and scrolls don't trigger an open. Buffer-local keymaps die with the
  -- buffer, so no manual cleanup needed.
  if explorer_config.auto_open_on_cursor then
    local function open_under_cursor()
      if not vim.api.nvim_buf_is_valid(split.bufnr) then
        return
      end
      local node = tree:get_node()
      if not node or not node.data then
        return
      end
      local node_type = node.data.type
      if node_type == "group" or node_type == "directory" then
        return
      end
      if explorer.current_file_path == node.data.path and explorer.current_file_group == node.data.group then
        return
      end
      explorer.on_file_select(node.data)
    end
    local lifecycle = require("codediff.ui.lifecycle")
    for _, key in ipairs({ "j", "k", "<Down>", "<Up>" }) do
      lifecycle.set_buf_keymap(explorer.tabpage, split.bufnr, "n", key, function()
        local motion = key == "<Down>" and "j" or key == "<Up>" and "k" or key
        vim.cmd("normal! " .. motion)
        open_under_cursor()
      end, { silent = true, desc = "codediff: move and auto-open file" }, { suspendable = false })
    end
  end

  local visible_files = refresh_module.get_all_files(tree)
  local initial_file
  if opts.focus_file then
    for _, file in ipairs(visible_files) do
      if file.data.path == opts.focus_file then
        initial_file = file
        break
      end
    end
  end
  initial_file = initial_file or visible_files[1]

  if initial_file then
    vim.schedule(function()
      if explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) and initial_file.node._line then
        vim.api.nvim_win_set_cursor(explorer.winid, { initial_file.node._line, 0 })
      end
      explorer.on_file_select(initial_file.data)
    end)
  end

  -- Setup auto-refresh
  refresh_module.setup_auto_refresh(explorer, tabpage)

  -- Re-render on window resize for dynamic width
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      -- Check if explorer window was resized
      local resized_wins = vim.v.event.windows or {}
      for _, win in ipairs(resized_wins) do
        if win == explorer.winid and vim.api.nvim_win_is_valid(win) then
          explorer.tree:render()
          break
        end
      end
    end,
  })

  return explorer
end

function M.rerender_current(explorer)
  if not explorer then
    return false
  end

  if explorer.current_selection then
    explorer.on_file_select(vim.deepcopy(explorer.current_selection), { force = true })
    return true
  end

  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(explorer.tabpage)
  if not session then
    return false
  end

  if should_show_welcome(explorer) and show_welcome_page(explorer) then
    return true
  end

  return false
end

M.show_welcome_page = show_welcome_page

-- Setup auto-refresh on file save and focus

return M
