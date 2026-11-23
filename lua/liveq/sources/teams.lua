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

local INLINE = { png = true, jpg = true, jpeg = true, gif = true } -- sent in the message; other files are attached

--- Puts `![name](path)` (an image, sent inline) or `[name](path)` (any other file, attached through OneDrive) on a
--- line of its own below the cursor (on the cursor's line when it is empty).
local function insert_image(buf, path)
  local win = vim.fn.bufwinid(buf)
  local row = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or vim.api.nvim_buf_line_count(buf)
  local ext = (path:match '%.(%w+)$' or ''):lower()
  local line = ('%s[%s](%s)'):format(INLINE[ext] and '!' or '', vim.fs.basename(path), path)
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

-- -- reply drafts by Claude ---------------------------------------------------------------------------------------

-- <localleader>id in a reply split: Claude (`claude -p`, the Claude Code CLI and its login) turns the points typed in
-- the split into drafts, given the chat's recent messages and a guide to how I write (the teams-reply skill's
-- style.md). The split then holds sections, `── draft 1 · short ──` and so on, then `── worth adding (not sent) ──`
-- (what the chat suggests I may have left out, as questions) and `── your points (not sent) ──`; `:w` sends the draft
-- the cursor is in, `u` brings the points back, and <localleader>id again drafts anew from the points.
local STYLE = vim.env.LIVEQ_TEAMS_STYLE or vim.fs.joinpath(vim.env.HOME, 'rcfiles', '.claude', 'skills', 'teams-reply', 'style.md')
local DRAFT_MODEL = vim.env.LIVEQ_TEAMS_DRAFT_MODEL or 'sonnet'
local HISTORY = 20 -- messages of the chat Claude sees
local MARK = '── '
local ATTACHMENT = '^%s*!?%[[^%]]*%]%([/~][^)]*%)%s*$'

--- The sections of a split with drafts: { { title = 'draft 1 · short', first = n, last = n }, ... } (1-based lines).
local function sections(lines)
  local list = {}
  for i, line in ipairs(lines) do
    local title = line:match('^' .. MARK .. '(.-) ──$')
    if title then
      if #list > 0 then
        list[#list].last = i - 1
      end
      table.insert(list, { title = title, first = i + 1, last = #lines })
    end
  end
  return list
end

local function section_text(lines, sec)
  return vim.trim(table.concat(vim.list_slice(lines, sec.first, sec.last), '\n'))
end

local function draft_prompt(title, history, points)
  local file = io.open(STYLE, 'r')
  local style = file and file:read '*a'
    or 'Write short, direct, informal work replies; no greetings unless opening a thread, no sign-off, no emoji. Never repeat credentials.'
  if file then
    file:close()
  end
  if #history > 12000 then
    history = '…\n' .. history:sub(-12000)
  end
  return table.concat({
    'You draft my replies in a Microsoft Teams chat. Write as me, in my style:',
    '',
    style,
    '',
    ('## The chat "%s", oldest first (the last %d messages)'):format(title, HISTORY),
    '',
    history,
    '',
    '## What I want to say',
    '',
    points ~= '' and points or '(nothing given: reply to the latest message as I would)',
    '',
    '## Output',
    '',
    'Reply with exactly these sections and nothing else (no preamble, no code fences around the whole):',
    '=== short',
    'the reply as I would most likely send it',
    '=== fuller',
    'a somewhat fuller version, still in my style',
    '=== worth adding',
    '- up to three things the chat suggests I might add or ask (as short questions to me), or "- nothing"',
  }, '\n')
end

--- Parses Claude's `=== name` sections into { { name, text } }.
local function parse_drafts(output)
  local list, current = {}, nil
  for _, line in ipairs(vim.split(output, '\n', { plain = true })) do
    local name = line:match '^===%s*(.-)%s*$'
    if name then
      current = { name = name, lines = {} }
      table.insert(list, current)
    elseif current then
      table.insert(current.lines, line)
    end
  end
  return vim.tbl_map(function(d)
    return { name = d.name, text = vim.trim(table.concat(d.lines, '\n')) }
  end, list)
end

--- Drafts a reply to chat `id` from the points in reply split `buf` (see above).
local function draft(source, id, title, buf)
  if vim.fn.executable 'claude' ~= 1 then
    vim.notify('No `claude` command (Claude Code) on PATH', vim.log.levels.WARN, { title = 'Teams' })
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local secs = sections(lines)
  local points_lines = lines
  for _, sec in ipairs(secs) do
    if sec.title:match '^your points' then
      points_lines = vim.list_slice(lines, sec.first, sec.last)
    end
  end
  if #secs > 0 and points_lines == lines then
    points_lines = {} -- drafts without the points section: draft from the chat alone
  end
  -- attached images and files stay out of Claude's hands: kept as they are, added to every draft
  local points, attached = {}, {}
  for _, line in ipairs(points_lines) do
    table.insert(line:match(ATTACHMENT) and attached or points, line)
  end
  local points_text = vim.trim(table.concat(points, '\n'))
  vim.notify(('Drafting with Claude (%s)…'):format(DRAFT_MODEL), vim.log.levels.INFO, { title = 'Teams' })
  run_async(source, { 'show', '--plain', '--chronological', '--count', tostring(HISTORY), '--', id }, function(history)
    local prompt = draft_prompt(title, history, points_text)
    local cmd = { 'claude', '-p', '--model', DRAFT_MODEL, '--tools', '', '--strict-mcp-config', '--no-session-persistence' }
    -- from a neutral directory, so that no project's CLAUDE.md comes along
    vim.system(cmd, { stdin = prompt, text = true, cwd = vim.fn.stdpath 'cache', timeout = 120000 }, function(result)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local drafts = result.code == 0 and parse_drafts(result.stdout or '') or {}
        if #drafts == 0 then
          local why = vim.trim((result.stderr or '') .. ' ' .. (result.stdout or ''))
          vim.notify('Claude gave no drafts: ' .. (why ~= '' and why:sub(1, 300) or ('exit ' .. result.code)), vim.log.levels.ERROR, { title = 'Teams' })
          return
        end
        local out, n = {}, 0
        for _, d in ipairs(drafts) do
          if d.name:match '^worth' then
            vim.list_extend(out, { MARK .. 'worth adding (not sent) ──' })
            vim.list_extend(out, vim.split(d.text, '\n', { plain = true }))
          elseif d.text ~= '' then
            n = n + 1
            table.insert(out, ('%sdraft %d · %s ──'):format(MARK, n, d.name))
            vim.list_extend(out, vim.split(d.text, '\n', { plain = true }))
            vim.list_extend(out, attached)
          end
          table.insert(out, '')
        end
        table.insert(out, MARK .. 'your points (not sent) ──')
        vim.list_extend(out, points)
        vim.list_extend(out, attached)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
        local win = vim.fn.bufwinid(buf)
        if win ~= -1 then
          vim.api.nvim_win_set_height(win, math.min(#out + 1, math.floor(vim.o.lines / 2)))
          vim.api.nvim_win_set_cursor(win, { 2, 0 })
        end
        vim.notify('Drafts ready: put the cursor in one and :w sends it', vim.log.levels.INFO, { title = 'Teams' })
      end)
    end)
  end, { LIVEQ_WIDTH = '100' })
end

-- <localleader>iC: the reply goes to Claude Code's teams-reply skill (~/rcfiles/.claude/skills/teams-reply), for one
-- that needs research (Jira, MRs, the code): an interactive `claude` in a tmux window of its own, in the main codebase
-- ($LIVEQ_TEAMS_REPLY_DIR, default ~/stormbreaker/security_director, else Neovim's directory), given the chat and the
-- points of the split. The skill sends only what is approved there; the split stays as it was.
local REPLY_DIR = vim.env.LIVEQ_TEAMS_REPLY_DIR or vim.fs.joinpath(vim.env.HOME, 'stormbreaker', 'security_director')

local function claude_session(id, title, buf)
  if not vim.env.TMUX or vim.fn.executable 'claude' ~= 1 then
    vim.notify('Needs tmux and the `claude` command (Claude Code)', vim.log.levels.WARN, { title = 'Teams' })
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, sec in ipairs(sections(lines)) do
    if sec.title:match '^your points' then
      lines = vim.list_slice(lines, sec.first, sec.last)
    end
  end
  local points = vim.trim(table.concat(lines, '\n'))
  local prompt = ('/teams-reply Reply in the Teams chat "%s" (chat id %s).%s'):format(
    title,
    id,
    points ~= '' and ('\n\nWhat I want to say:\n' .. points) or ' Read it and suggest what I should reply.'
  )
  local dir = vim.uv.fs_stat(REPLY_DIR) and REPLY_DIR or vim.fn.getcwd()
  local result = vim.system({ 'tmux', 'new-window', '-n', 'reply', '-c', dir, 'claude', prompt }, { text = true }):wait(5000)
  if result.code ~= 0 then
    vim.notify('Could not open a tmux window: ' .. vim.trim(result.stderr or ''), vim.log.levels.ERROR, { title = 'Teams' })
  end
end

--- A compose split for replying to chat `id`; `:w` sends the whole buffer as one message (with drafts, the draft the
--- cursor is in). Images go in as lines
--- `![name](path)`, sent inline, other files as `[name](path)`, attached (uploaded to OneDrive and shared with the
--- chat, as Teams does): <localleader>ip pastes the clipboard's image, <localleader>ia attaches a file (the prompt
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
    .. '%*  %#Comment#:w sends (asks first) · :q! drops · <localleader>id draft with Claude · <localleader>iC Claude Code · <localleader>ip paste image · <localleader>ia attach file%*'
  vim.keymap.set('n', '<localleader>id', function()
    draft(source, id, title, buf)
  end, { buffer = buf, desc = 'Teams: draft the reply with Claude' })
  vim.keymap.set('n', '<localleader>iC', function()
    claude_session(id, title, buf)
  end, { buffer = buf, desc = 'Teams: reply with Claude Code (teams-reply skill, research)' })
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
    vim.ui.input({ prompt = 'File to attach: ', completion = 'file', default = clipboard_file() }, function(input)
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
  end, { buffer = buf, desc = 'Teams: attach a file' })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- with drafts, the one the cursor is in
      local secs = sections(lines)
      if #secs > 0 then
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local sec = vim.tbl_filter(function(s)
          return row >= s.first - 1 and row <= s.last
        end, secs)[1]
        if not (sec and sec.title:match '^draft') then
          vim.notify('Put the cursor in the draft to send', vim.log.levels.WARN, { title = 'Teams' })
          return
        end
        lines = vim.split(section_text(lines, sec), '\n', { plain = true })
      end
      local text = vim.trim(table.concat(lines, '\n'))
      if text == '' then
        vim.notify('Nothing to send', vim.log.levels.WARN, { title = 'Teams' })
        return
      end
      local first = vim.split(text, '\n', { plain = true })
      local shown = table.concat(vim.list_slice(first, 1, 3), '\n') .. (#first > 3 and '\n…' or '')
      local images, files = 0, 0
      for _, l in ipairs(first) do
        local bang, path = l:match '^%s*(!?)%[[^%]]*%]%(([/~][^)]*)%)%s*$'
        if path then
          local ext = (path:match '%.(%w+)$' or ''):lower()
          if bang == '!' and INLINE[ext] then
            images = images + 1
          else
            files = files + 1
          end
        end
      end
      local with = {}
      if images > 0 then
        table.insert(with, ('%d image%s'):format(images, images == 1 and '' or 's'))
      end
      if files > 0 then
        table.insert(with, ('%d file%s, uploaded to your OneDrive and shared with the chat'):format(files, files == 1 and '' or 's'))
      end
      if #with > 0 then
        shown = shown .. '\n\n(with ' .. table.concat(with, ' and ') .. ')'
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
    gallery = true, -- alt-g: the chat's images, one at a time (`images`/`image`, gallery.lua)
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
          -- in the background: a refresh fetches every changed chat (15s to minutes), which froze the editor when waited on
          vim.notify('Fetching chats from Teams…', vim.log.levels.INFO, { title = 'Teams' })
          local cmd = vim.list_extend(util.cmd(source), { 'refresh' })
          local ok, err = pcall(vim.system, cmd, { text = true, timeout = 180000 }, function(result)
            vim.schedule(function()
              if result.code ~= 0 then
                local msg = vim.trim((result.stderr or '') .. (result.stdout or ''))
                vim.notify(msg ~= '' and msg or ('refresh failed (exit ' .. result.code .. ')'), vim.log.levels.ERROR, { title = 'Teams' })
                return
              end
              local done = vim.trim((result.stdout or '') .. (result.stderr or '')) -- "Fetched N chats" (stderr)
              vim.notify(done ~= '' and done or 'Teams chats refreshed', vim.log.levels.INFO, { title = 'Teams' })
              reopen()
            end)
          end)
          if not ok then
            vim.notify(tostring(err), vim.log.levels.ERROR, { title = 'Teams' })
          end
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  return spec
end
