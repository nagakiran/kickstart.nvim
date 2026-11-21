-- Microsoft Teams chats as a liveq source, backed by backends/teams.lua (`nvim -l`, Microsoft Graph through curl).
--
--   require('liveq.sources.teams') { commands = {...}, keymaps = {...} }
--
-- The picker lists chats (newest activity first, ● unread); `enter` opens a chat buffer, `alt-r` replies straight from
-- the picker. In a chat buffer (`teams://NAME`, oldest message at the top, cursor on the newest):
--   r / o   reply: a compose split below; `:w` sends it (after a confirmation), `:q!` drops it
--   R       reload          gx   the link under the cursor, else the chat in Teams          ctrl-o   the chat in Teams          q   close
-- Opening a chat marks it read, as opening it in Teams does. Auth: see the backend (o365_auth.py token-graph).

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'teams.lua'))
local util = require 'liveq.util'

local function syntax()
  vim.cmd [[
    syntax match teamsQueryPrefix /\(^\|\s\)\zs-\?\(with\|type\|is\|since\|on\):/
    syntax region teamsQueryString start=/"/ end=/"/ oneline
    highlight default link teamsQueryPrefix Identifier
    highlight default link teamsQueryString String
  ]]
end

local M = {}

--- Runs a backend subcommand asynchronously; `done(stdout)` on success, a notification on failure.
local function run_async(source, args, done, env)
  local cmd = util.cmd(source)
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, env = env }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify(vim.trim((result.stderr or '') .. (result.stdout or '')), vim.log.levels.ERROR, { title = 'Teams' })
      elseif done then
        done(result.stdout or '')
      end
    end)
  end)
end

local function chat_buffer(id)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].teams_chat == id and not vim.b[b].teams_reply then
      return b
    end
  end
end

--- (Re)loads a chat buffer from Graph (never from the message cache, which can lag a new message by a refresh).
function M.load(source, buf)
  local id = vim.b[buf].teams_chat
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or 100
  vim.b[buf].teams_loading = true
  run_async(source, { 'show', '--plain', '--chronological', '--fresh', '--count', '100', '--', id }, function(text)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.b[buf].teams_loading = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(vim.trim(text), '\n', { plain = true }))
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    local w = vim.fn.bufwinid(buf)
    if w ~= -1 then
      vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(buf), 0 })
    end
    -- seen now, as in Teams; a failure is only a warning (the chat still reads fine)
    local cmd = util.cmd(source)
    vim.list_extend(cmd, { 'read', '--', id })
    vim.system(cmd, { text = true }, function(result)
      if result.code ~= 0 then
        vim.schedule(function()
          vim.notify('Could not mark the chat read: ' .. vim.trim(result.stderr or ''), vim.log.levels.WARN, { title = 'Teams' })
        end)
      end
    end)
  end, { LIVEQ_WIDTH = tostring(width) })
end

local OUTGOING = vim.fs.joinpath(vim.fn.stdpath 'cache', 'liveq', 'teams', 'outgoing')

--- Saves the image on the clipboard as a PNG file and returns its path; nil and why not.
local function clipboard_image()
  vim.fn.mkdir(OUTGOING, 'p')
  local path = vim.fs.joinpath(OUTGOING, ('%s-%03d.png'):format(os.date '%Y%m%d-%H%M%S', math.floor(vim.uv.hrtime() / 1e6) % 1000))
  local cmd
  if vim.fn.has 'mac' == 1 and vim.fn.executable 'pngpaste' == 1 then
    cmd = { 'pngpaste', path }
  elseif vim.fn.has 'mac' == 1 then
    cmd = {
      'osascript',
      '-e',
      ('set f to open for access POSIX file "%s" with write permission'):format(path),
      '-e',
      'write (the clipboard as «class PNGf») to f',
      '-e',
      'close access f',
    }
  elseif vim.env.WAYLAND_DISPLAY and vim.fn.executable 'wl-paste' == 1 then
    cmd = { 'sh', '-c', 'wl-paste --type image/png > "$1"', 'sh', path }
  elseif vim.env.DISPLAY and vim.fn.executable 'xclip' == 1 then
    cmd = { 'sh', '-c', 'xclip -selection clipboard -t image/png -o > "$1"', 'sh', path }
  else
    return nil, 'no way to read an image from the clipboard here (pngpaste/osascript, wl-paste or xclip)'
  end
  local result = vim.system(cmd, { text = true }):wait(10000)
  local stat = vim.uv.fs_stat(path)
  if result.code ~= 0 or not stat or stat.size == 0 then
    os.remove(path)
    return nil, 'no image on the clipboard'
  end
  return path
end

--- The file on the clipboard, when there is one: a file copied in Finder (macOS), else a path copied as text (quoted,
--- ~/, file:// all right). nil otherwise.
local function clipboard_file()
  if vim.fn.has 'mac' == 1 then
    local result = vim.system({ 'osascript', '-e', 'POSIX path of (the clipboard as «class furl»)' }, { text = true }):wait(3000)
    local path = vim.trim(result.stdout or '')
    if result.code == 0 and path ~= '' and vim.uv.fs_stat(path) then
      return path
    end
  end
  local ok, text = pcall(vim.fn.getreg, '+')
  text = ok and vim.trim(text or ''):gsub('^[\'"]', ''):gsub('[\'"]$', '') or ''
  if text == '' or text:find '\n' then
    return nil
  end
  text = text:gsub('^file://[^/]*', ''):gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end)
  local path = vim.fn.fnamemodify(vim.fn.expand(text), ':p')
  return vim.uv.fs_stat(path) and path or nil
end

--- Puts `![name](path)` on a line of its own below the cursor (on the cursor's line when it is empty).
local function insert_image(buf, path)
  local win = vim.fn.bufwinid(buf)
  local row = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or vim.api.nvim_buf_line_count(buf)
  local line = ('![%s](%s)'):format(vim.fs.basename(path), path)
  if vim.trim(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or '') == '' then
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { line })
  else
    vim.api.nvim_buf_set_lines(buf, row, row, false, { line })
    row = row + 1
  end
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { row, #line })
  end
end

--- A compose split for replying to chat `id`; `:w` sends the whole buffer as one message. Images go in as lines
--- `![name](path)`, sent inline: <localleader>ip pastes the clipboard's, <localleader>ia attaches a file (the prompt
--- starts with the clipboard's file; at a prompt, ctrl-r + pastes the clipboard, since ctrl-v inserts a key literally).
function M.reply(source, id, title)
  vim.cmd 'botright 8new'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.b[buf].teams_chat = id
  vim.b[buf].teams_reply = true
  pcall(vim.api.nvim_buf_set_name, buf, 'teams-reply://' .. title .. ' [' .. buf .. ']')
  vim.wo.winbar = '%#Title# Reply to '
    .. title:gsub('%%', '%%%%')
    .. '%*  %#Comment#:w sends (asks first) · :q! drops · <localleader>ip paste image · <localleader>ia attach image%*'
  vim.keymap.set('n', '<localleader>ip', function()
    local path, why = clipboard_image()
    if not path then
      vim.notify(why, vim.log.levels.WARN, { title = 'Teams' })
      return
    end
    insert_image(buf, path)
  end, { buffer = buf, desc = 'Teams: paste the clipboard image' })
  vim.keymap.set('n', '<localleader>ia', function()
    -- starts with the file on the clipboard, if any (copied in Finder, or its path as text)
    vim.ui.input({ prompt = 'Image to attach: ', completion = 'file', default = clipboard_file() }, function(input)
      if not input or vim.trim(input) == '' then
        return
      end
      local path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(input)), ':p')
      if not vim.uv.fs_stat(path) then
        vim.notify('No such file: ' .. path, vim.log.levels.WARN, { title = 'Teams' })
        return
      end
      insert_image(buf, path)
    end)
  end, { buffer = buf, desc = 'Teams: attach an image file' })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = vim.trim(table.concat(lines, '\n'))
      if text == '' then
        vim.notify('Nothing to send', vim.log.levels.WARN, { title = 'Teams' })
        return
      end
      local first = vim.split(text, '\n', { plain = true })
      local shown = table.concat(vim.list_slice(first, 1, 3), '\n') .. (#first > 3 and '\n…' or '')
      local images = #vim.tbl_filter(function(l)
        return l:match '^%s*!%[[^%]]*%]%(.-%)%s*$' ~= nil
      end, first)
      if images > 0 then
        shown = shown .. ('\n\n(with %d image%s)'):format(images, images == 1 and '' or 's')
      end
      if vim.fn.confirm(('Send to %s?\n\n%s'):format(title, shown), '&Send\n&Cancel', 2) ~= 1 then
        return
      end
      local tmp = vim.fn.tempname()
      vim.fn.writefile(lines, tmp)
      local ok = util.run(source, { 'send', '--file', tmp, '--', id }, { timeout = 30000 })
      vim.fn.delete(tmp)
      if not ok then
        return -- the text stays, still modified, so :wq does not lose it
      end
      vim.bo[buf].modified = false
      vim.notify('Sent to ' .. title, vim.log.levels.INFO, { title = 'Teams' })
      local chat = chat_buffer(id)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        if chat then
          M.load(source, chat)
        end
      end)
    end,
  })
  vim.cmd 'startinsert'
end

--- The gallery of chat `id`'s images (the backend's `images`/`image`): one at a time in the preview, `enter` copies it
--- to the clipboard, ctrl-o opens it in the image viewer. In Neovim's terminal the preview is block art; alt-w then
--- alt-g in a tmux window shows the real images.
function M.gallery(source, id)
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    return
  end
  local backend = util.shell_cmd(source)
  local key = function(selected)
    return selected[1] and vim.split(selected[1], '\t', { plain = true })[1]
  end
  local run = function(flag)
    return function(selected)
      local k = key(selected)
      if k and k ~= '' then
        run_async(source, { 'image', flag, '--', k }, function()
          if flag == '--copy' then
            vim.notify('Image copied to the clipboard', vim.log.levels.INFO, { title = 'Teams' })
          end
        end)
      end
    end
  end
  fzf.fzf_exec(backend .. ' images -f fzf -- ' .. vim.fn.shellescape(id), {
    prompt = 'images> ',
    winopts = { title = ' Images ', preview = { layout = 'vertical', vertical = 'down:75%' } },
    preview = backend .. ' image -- {1}',
    fzf_opts = { ['--ansi'] = true, ['--delimiter'] = '\t', ['--with-nth'] = '2', ['--no-sort'] = true, ['--header'] = 'enter copy · ^o open' },
    actions = { ['enter'] = run '--copy', ['ctrl-o'] = run '--open' },
  })
end

--- Opens chat `id` in the current window, reusing its buffer when it is already open.
function M.open_chat(source, id, title)
  local buf = chat_buffer(id)
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.b[buf].teams_chat = id
    vim.b[buf].teams_title = title
    -- two chats may share a name (e.g. two 1:1s with a person who has two accounts)
    if not pcall(vim.api.nvim_buf_set_name, buf, 'teams://' .. title) then
      pcall(vim.api.nvim_buf_set_name, buf, 'teams://' .. title .. ' [' .. buf .. ']')
    end
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# ' .. title, '', '_Loading…_' })
    vim.bo[buf].modifiable = false
    local map = function(lhs, fn, desc)
      vim.keymap.set('n', lhs, fn, { buffer = buf, desc = 'Teams: ' .. desc, nowait = true })
    end
    local reply = function()
      M.reply(source, id, title)
    end
    local browse = function()
      local url = util.run(source, { 'url', '--', id })
      if url and vim.trim(url) ~= '' then
        vim.ui.open(vim.trim(url))
      end
    end
    map('r', reply, 'reply')
    map('o', reply, 'reply')
    map('R', function()
      M.load(source, buf)
    end, 'reload')
    require('liveq.show').map_gx(buf, browse) -- the link under the cursor, else the chat in Teams
    map('<C-o>', browse, 'open in Teams')
    map('q', function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, 'close')
  end
  vim.api.nvim_set_current_buf(buf)
  vim.wo.wrap = true
  vim.wo.linebreak = true
  M.load(source, buf)
end

return function(opts)
  opts = opts or {}
  local spec
  local function reopen()
    local ok, fzf = pcall(require, 'fzf-lua')
    require('liveq').search(spec.name, ok and fzf.get_last_query() or '')
  end

  spec = {
    title = opts.title or 'Teams chats',
    prompt = opts.prompt or 'teams> ',
    item_name = 'chat id',
    cmd = function()
      return { vim.v.progpath, '-l', backend }
    end,
    limit = opts.limit or 200,

    url = true,
    match = true, -- `show --match QUERY` highlights the words and opens the preview at the message found
    -- draw the images pasted into messages in the preview (see the backend's "images"): chafa's block art, with the
    -- real image over it by image.nvim where it can draw (liveq/images.lua)
    preview_toggles = { ['alt-i'] = { flag = '--images', desc = 'images' } },
    images = true,
    -- in tmux, alt-w (and the `tmux` keymap) move the search to the shell's `lq teams` in a tmux window, where images
    -- are real (tmux.lua); `enter` there opens the chat here. 'default': the search keymap/command open it too
    tmux = opts.tmux,

    id_pattern = '^%d+:%S+$',

    filetype = 'teamsquery',
    extension = 'tmq',
    trigger_characters = { ' ', ':' },
    keyword_pattern = [[\%(\k\|[:"-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['enter'] = {
        desc = 'open chat',
        fn = function(items, source)
          if items[1] then
            M.open_chat(source, items[1].id, items[1].title)
          end
        end,
      },
      ['alt-g'] = {
        desc = 'gallery',
        fn = function(items, source)
          if items[1] then
            M.gallery(source, items[1].id)
          end
        end,
      },
      ['alt-r'] = {
        desc = 'reply',
        fn = function(items, source)
          if items[1] then
            M.reply(source, items[1].id, items[1].title)
          end
        end,
      },
      ['ctrl-r'] = {
        desc = 'refresh',
        fn = function(_, source)
          vim.notify('Fetching chats from Teams…', vim.log.levels.INFO, { title = 'Teams' })
          if util.run(source, { 'refresh' }, { timeout = 180000 }) then
            reopen()
          end
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  return spec
end
