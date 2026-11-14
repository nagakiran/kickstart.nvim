-- The Microsoft Teams chat backend of liveq, run with `nvim -l`, talking to Microsoft Graph with curl.
--
--   nvim -l teams.lua search -f fzf -l LIMIT -- QUERY      chats from the on-disk cache, newest activity first
--   nvim -l teams.lua show [--plain] [--chronological] [--count N] [--fresh] -- CHAT_ID   (--fresh skips the cache)
--   nvim -l teams.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l teams.lua url -- CHAT_ID                       the chat in the Teams web client
--   nvim -l teams.lua refresh                              fetch the chat list (and new members) into the cache
--   nvim -l teams.lua refresh --deep [N]                   ...then backfill every chat's history to N messages (300)
--   nvim -l teams.lua send [--file PATH] -- CHAT_ID [TEXT] post a message (TEXT, or the file's contents)
--   nvim -l teams.lua read -- CHAT_ID                      mark the chat read, as opening it in Teams does
--   nvim -l teams.lua show --match QUERY -- CHAT_ID         the preview, with the query's words highlighted
--   nvim -l teams.lua terms -- QUERY                       the query's words, as JSON (for liveq's n/N)
--
-- The query, evaluated locally over the cache:
--   words (each must be in the chat's name, members or messages; -word excludes, on name/members/last message only)
--   with:NAME (a member's name or address)   type:1:1|group|meeting   is:unread   since:7d|2w|1M|2026-11-01
--
-- Searching never waits for the network once there is a cache: when the cache is older than LIVEQ_TEAMS_TTL seconds
-- (default 120) a refresh is started in the background and the next keystroke sees its result. The messages of a chat
-- are fetched on `show` and cached per chat, keyed by the chat's last message, so an unchanged chat previews instantly.
--
-- Words also search message text. Graph's message search needs ChannelMessage.Read.All, which only an admin can
-- consent, so the search is local: each refresh fetches the latest 50 messages of every chat whose last message
-- changed (in $batch requests of 20), merges them into the chat's message cache and writes their text to index.json.
-- Nothing is ever dropped: messages accumulate (LIVEQ_TEAMS_KEEP caps them per chat only when set), and a chat that
-- falls out of the newest LIVEQ_TEAMS_MAX stays in the list, searchable, until it is active again. `refresh --deep`
-- backfills older history. A chat found through a message shows that message in its row, and the preview opens at it.
--
-- Auth: a Graph token (Chat.ReadWrite, User.Read) printed by LIVEQ_TEAMS_TOKEN_CMD, by default
-- `~/.venvs/mail/bin/python ~/rcfiles/bin/mail/o365_auth.py token-graph $LIVEQ_TEAMS_ACCOUNT` (account defaulting to
-- $HPE_MAIL_ADDR). It is cached until a few minutes before it expires, so most calls do not start Python. The token
-- reaches curl through a header file (mode 600), never through its argv, which any process could read.
--
-- Environment: LIVEQ_TEAMS_ACCOUNT, LIVEQ_TEAMS_TOKEN_CMD, LIVEQ_TEAMS_CACHE (directory), LIVEQ_TEAMS_TTL,
-- LIVEQ_TEAMS_MAX (chats kept, default 150).

local HOME = os.getenv 'HOME'
local GRAPH = 'https://graph.microsoft.com/v1.0'
local CACHE = os.getenv 'LIVEQ_TEAMS_CACHE' or ((os.getenv 'XDG_CACHE_HOME' or (HOME .. '/.cache')) .. '/liveq/teams')
local CHATS = CACHE .. '/chats.json'
local TTL = tonumber(os.getenv 'LIVEQ_TEAMS_TTL') or 120
local MAX_CHATS = tonumber(os.getenv 'LIVEQ_TEAMS_MAX') or 150
local DAY = 24 * 3600
local UNITS = { d = DAY, w = 7 * DAY, M = 30 * DAY, y = 365 * DAY }
local TYPES = { ['1:1'] = 'oneOnOne', dm = 'oneOnOne', oneonone = 'oneOnOne', group = 'group', meeting = 'meeting' }
local TYPE_TAG = { oneOnOne = '\27[32m1:1\27[0m', group = '\27[34mgrp\27[0m', meeting = '\27[35mmtg\27[0m' }
local SCRIPT = debug.getinfo(1, 'S').source:sub(2)
local INDEX = CACHE .. '/index.json'
local KEEP = tonumber(os.getenv 'LIVEQ_TEAMS_KEEP') -- nil: keep every message
local DEEP = 300 -- messages per chat that `refresh --deep` backfills to, unless given

local function out(text)
  io.stdout:write(text, '\n')
end

local function fail(message, code)
  io.stderr:write('liveq-teams: ' .. message .. '\n')
  os.exit(code or 1)
end

local function parse(args)
  local opts, rest = {}, {}
  if args[#args] == '--deep' then
    args[#args] = nil
    opts.deep = tostring(DEEP)
  end
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--plain' or a == '--chronological' or a == '--fresh' or a == '--quiet' then
      opts[a:sub(3)] = true
      i = i + 1
    elseif a:match '^%-' and args[i + 1] then
      opts[(a:gsub('^%-+', ''))] = args[i + 1]
      i = i + 2
    else
      table.insert(rest, a)
      i = i + 1
    end
  end
  return opts, rest
end

-- -- files --------------------------------------------------------------------------------------------------------

local function read_json(path)
  local file = io.open(path, 'r')
  if not file then
    return nil
  end
  local ok, data = pcall(vim.json.decode, file:read '*a', { luanil = { object = true, array = true } })
  file:close()
  return ok and type(data) == 'table' and data or nil
end

--- Writes through a temp file, so that a failed or concurrent write never leaves a half-written cache.
local function write_file(path, text, mode)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.uv.fs_chmod(CACHE, tonumber('700', 8))
  local tmp = path .. '.' .. vim.uv.os_getpid() .. '.new'
  local file = assert(io.open(tmp, 'w'))
  if mode then
    vim.uv.fs_chmod(tmp, tonumber(mode, 8))
  end
  file:write(text)
  file:close()
  os.rename(tmp, path)
end

local function write_json(path, data)
  write_file(path, vim.json.encode(data))
end

-- -- time ---------------------------------------------------------------------------------------------------------

local UTC_OFFSET = (function()
  local now = os.time()
  local utc = os.date('!*t', now)
  utc.isdst = false
  return os.difftime(now, os.time(utc))
end)()

--- Seconds since the epoch of a Graph timestamp (`2026-11-14T08:19:36.877Z`), fraction included; nil for nil.
local function epoch(iso)
  local y, m, d, hh, mm, ss, frac = (iso or ''):match '^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)'
  if not y then
    return nil
  end
  local t = os.time { year = y, month = m, day = d, hour = hh, min = mm, sec = ss, isdst = false }
  return t + UTC_OFFSET + (frac ~= '' and tonumber('0.' .. frac) or 0)
end

--- A short local time: 13:49 today, Nov 14 this year, 2025-11-14 before.
local function short_time(iso)
  local t = epoch(iso)
  if not t then
    return ''
  end
  if os.date('%Y%m%d', t) == os.date '%Y%m%d' then
    return os.date('%H:%M', t)
  elseif os.date('%Y', t) == os.date '%Y' then
    return os.date('%b %d', t)
  end
  return os.date('%Y-%m-%d', t)
end

local function long_time(iso)
  local t = epoch(iso)
  return t and os.date('%a %b %d %H:%M', t) or ''
end

local function since(value)
  local n, unit = value:match '^(%d+)([dwMy])$'
  if n then
    return os.time() - tonumber(n) * UNITS[unit]
  end
  return value:match '^%d%d%d%d%-%d%d%-%d%d$' and epoch(value .. 'T00:00:00') or nil
end

-- -- auth ---------------------------------------------------------------------------------------------------------

local function account()
  local a = os.getenv 'LIVEQ_TEAMS_ACCOUNT'
  if not a or a == '' then
    a = os.getenv 'HPE_MAIL_ADDR'
  end
  return a ~= '' and a or nil
end

--- The claims of a JWT (exp, oid, tid, ...), or {}.
local function claims(token)
  local payload = (token or ''):match '^[^.]+%.([^.]+)%.'
  if not payload then
    return {}
  end
  payload = payload:gsub('-', '+'):gsub('_', '/')
  payload = payload .. string.rep('=', (4 - #payload % 4) % 4)
  local ok, decoded = pcall(vim.base64.decode, payload)
  local ok2, data = pcall(vim.json.decode, ok and decoded or '')
  return ok2 and type(data) == 'table' and data or {}
end

local TOKEN_FILE = CACHE .. '/token'
local HEADER_FILE = CACHE .. '/auth.header'

local function fetch_token()
  local cmd = os.getenv 'LIVEQ_TEAMS_TOKEN_CMD'
  local argv
  if cmd and cmd ~= '' then
    argv = { 'sh', '-c', cmd }
  else
    local acct = account()
    if not acct then
      return nil, 'set LIVEQ_TEAMS_ACCOUNT (or HPE_MAIL_ADDR) to the Microsoft 365 address'
    end
    argv = { HOME .. '/.venvs/mail/bin/python', HOME .. '/rcfiles/bin/mail/o365_auth.py', 'token-graph', acct }
  end
  local ok, job = pcall(vim.system, argv, { text = true })
  if not ok then
    return nil, 'cannot run the token command: ' .. tostring(job)
  end
  local result = job:wait(60000)
  local token = vim.trim(result.stdout or '')
  if result.code ~= 0 or not token:match '^[%w_-]+%.[%w_-]+%.[%w_-]+$' then
    return nil, 'no Graph token: ' .. vim.trim((result.stderr or '') .. ' ' .. token):sub(1, 300)
  end
  write_file(TOKEN_FILE, token, '600')
  write_file(HEADER_FILE, 'Authorization: Bearer ' .. token .. '\n', '600')
  return token
end

local token_cache
--- A Graph token with at least five minutes left, from the cache or a fresh one. `force` skips the cache.
local function token(force)
  if token_cache and not force then
    return token_cache
  end
  if not force then
    local file = io.open(TOKEN_FILE, 'r')
    local cached = file and vim.trim(file:read '*a')
    if file then
      file:close()
    end
    local exp = cached and tonumber(claims(cached).exp)
    if exp and exp - os.time() > 300 and vim.uv.fs_stat(HEADER_FILE) then
      token_cache = cached
      return cached
    end
  end
  local fresh, err = fetch_token()
  token_cache = fresh
  return fresh, err
end

-- -- Graph --------------------------------------------------------------------------------------------------------

--- A Graph call; returns the decoded JSON reply, or nil and an error. Retries once with a new token on a 401.
local function api(method, path, body, retried)
  local tok, err = token(retried)
  if not tok then
    return nil, err
  end
  local url = path:match '^https://' and path or (GRAPH .. path)
  local cmd = { 'curl', '-sS', '--max-time', '60', '-X', method, '-H', '@' .. HEADER_FILE, '-H', 'Accept: application/json', '-w', '\n%{http_code}' }
  if body then
    vim.list_extend(cmd, { '-H', 'Content-Type: application/json', '--data-binary', '@-' })
  end
  table.insert(cmd, url)
  local result = vim.system(cmd, { text = true, stdin = body and vim.json.encode(body) or nil }):wait(70000)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or ('curl exited with ' .. result.code)
  end
  local text, status = (result.stdout or ''):match '^(.*)\n(%d+)$'
  status = tonumber(status)
  if status == 401 and not retried then
    return api(method, path, body, true)
  end
  local ok, data = pcall(vim.json.decode, text ~= '' and text or '{}', { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    return nil, ('HTTP %s: %s'):format(status, (text or ''):sub(1, 300))
  end
  if not status or status >= 300 then
    local e = data.error or {}
    return nil, ('HTTP %s %s: %s'):format(status, e.code or '', e.message or (text or ''):sub(1, 300))
  end
  return data
end

-- -- HTML -> text -------------------------------------------------------------------------------------------------

local ENTITIES = { nbsp = ' ', amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

local function entities(s)
  return (
    s:gsub('&(#?x?)(%w+);', function(kind, name)
      if kind == '#' then
        return vim.fn.nr2char(tonumber(name) or 63)
      elseif kind == '#x' then
        return vim.fn.nr2char(tonumber(name, 16) or 63)
      end
      return ENTITIES[name:lower()]
    end)
  )
end

local function strip_tags(s)
  return entities((s:gsub('<[^>]*>', '')))
end

--- The text of a message body. `attachments` resolves the `<attachment id=...>` placeholders: quoted replies
--- (messageReference) become `> Sender: preview` lines, files become `[file: name] url`.
local function body_text(body, attachments)
  if not body or not body.content then
    return ''
  end
  local s = body.content
  if body.contentType ~= 'html' then
    return vim.trim(s)
  end
  local by_id = {}
  for _, a in ipairs(attachments or {}) do
    by_id[tostring(a.id)] = a
  end
  s = s:gsub('[\r\n]', '')
  s = s:gsub('<attachment id="([^"]*)"[^>]*>%s*</attachment>', function(id)
    local a = by_id[id]
    if not a then
      return ''
    end
    by_id[id] = nil
    if a.contentType == 'messageReference' then
      local ok, ref = pcall(vim.json.decode, a.content or '')
      if ok and type(ref) == 'table' then
        local who = vim.tbl_get(ref, 'messageSender', 'user', 'displayName') or '?'
        return '\1QUOTE' .. who .. '\2' .. strip_tags(ref.messagePreview or '') .. '\3'
      end
      return ''
    end
    return '\n[file: ' .. (a.name or a.contentType or '?') .. ']' .. (a.contentUrl and (' ' .. a.contentUrl) or '') .. '\n'
  end)
  s = s:gsub('<codeblock[^>]*>(.-)</codeblock>', function(code)
    code = code:gsub('<br%s*/?>', '\n'):gsub('</div>', '\n')
    return '\n```\n' .. vim.trim(strip_tags(code)) .. '\n```\n'
  end)
  s = s:gsub('<code[^>]*>(.-)</code>', function(code)
    return '`' .. strip_tags(code) .. '`'
  end)
  s = s:gsub('<at [^>]*>(.-)</at>', '@%1')
  s = s:gsub('<a [^>]*href="([^"]*)"[^>]*>(.-)</a>', function(href, text)
    text = vim.trim(strip_tags(text))
    href = entities(href)
    return (text == href or text == '') and href or (text .. ' <' .. href .. '>')
  end)
  s = s:gsub('<emoji[^>]-alt="([^"]*)"[^>]*>.-</emoji>', '%1')
  s = s:gsub('<img[^>]-alt="([^"]+)"[^>]*>', '%1')
  s = s:gsub('<img[^>]*>', '[image]')
  s = s:gsub('<li[^>]*>', '\n- ')
  s = s:gsub('<br%s*/?>', '\n'):gsub('</p>', '\n'):gsub('</div>', '\n'):gsub('</blockquote>', '\n')
  s = strip_tags(s)
  s = s:gsub('[ \t]+\n', '\n'):gsub('\n\n\n+', '\n\n')
  local text = vim.trim(s)
  -- what is left in by_id was not placed in the body (Teams usually places them): list files at the end
  for _, a in pairs(by_id) do
    if a.contentType ~= 'messageReference' then
      text = text .. '\n[file: ' .. (a.name or a.contentType or '?') .. ']' .. (a.contentUrl and (' ' .. a.contentUrl) or '')
    end
  end
  return text
end

--- `text` with the quote markers of body_text rendered: for a Markdown buffer or the ANSI preview.
local function render_quotes(text, plain)
  return (
    text:gsub('\1QUOTE(.-)\2(.-)\3%s*', function(who, preview)
      preview = preview:gsub('%s+', ' ')
      if plain then
        return '> **' .. who .. ':** ' .. preview .. '\n\n'
      end
      return '\27[2m│ ' .. who .. ': ' .. preview .. '\27[0m\n'
    end)
  )
end

local function one_line(s)
  return vim.trim(((s or ''):gsub('\1QUOTE.-\3', ''):gsub('%s+', ' ')))
end

-- -- chat cache ---------------------------------------------------------------------------------------------------

local function me()
  local c = claims(token())
  return c.oid, c.tid
end

local function member_names(chat, my_id)
  local names = {}
  for _, m in ipairs(chat.members or {}) do
    if m.u ~= my_id and m.n and m.n ~= '' then
      table.insert(names, m.n)
    end
  end
  return names
end

--- What a chat is called: its topic, else the other members (the person, for a 1:1).
local function chat_name(chat, my_id)
  if chat.topic and chat.topic ~= '' then
    return chat.topic
  end
  local names = member_names(chat, my_id)
  if #names == 0 then
    return chat.chatType == 'oneOnOne' and '(1:1 chat)' or '(untitled chat)'
  end
  local shown = vim.list_slice(names, 1, 4)
  return table.concat(shown, ', ') .. (#names > 4 and (' +' .. (#names - 4)) or '')
end

local function unread(chat, my_id)
  local last = chat.preview and epoch(chat.preview.at)
  -- a call or membership event as the last item does not make a chat unread in Teams either
  if not last or chat.preview.event or (chat.preview.fromId and chat.preview.fromId == my_id) then
    return false
  end
  local read = epoch(chat.lastRead)
  return not read or last > read + 0.001
end

local function trim_members(list)
  return vim.tbl_map(function(m)
    return { n = m.displayName, e = m.email, u = m.userId }
  end, list or {})
end

local function by_time_desc(a, b)
  return (epoch(a.at) or 0) > (epoch(b.at) or 0)
end

local function trim_message(m)
  return {
    id = m.id,
    at = m.createdDateTime,
    edited = m.lastEditedDateTime,
    deleted = m.deletedDateTime,
    from = vim.tbl_get(m, 'from', 'user', 'displayName') or vim.tbl_get(m, 'from', 'application', 'displayName'),
    fromId = vim.tbl_get(m, 'from', 'user', 'id'),
    type = m.messageType,
    event = m.eventDetail and m.eventDetail['@odata.type'],
    subject = m.subject,
    text = body_text(m.body, m.attachments),
    reactions = vim.tbl_map(function(r)
      return r.displayName or r.reactionType
    end, m.reactions or {}),
  }
end

local function message_file(chat_id)
  return CACHE .. '/messages/' .. chat_id:gsub('[^%w]', '_') .. '.json'
end

--- The searchable part of a chat's messages (newest first): real messages, one line each, quotes dropped.
local function index_entry(list)
  local msgs = {}
  for _, m in ipairs(list) do
    if m.type == 'message' and not m.deleted then
      local text = one_line(m.text)
      if text ~= '' then
        table.insert(msgs, { id = m.id, at = m.at, from = m.from, fromId = m.fromId, text = text })
      end
    end
  end
  return { newest = list[1] and list[1].id, messages = msgs }
end

--- Replaces the index entries of some chats, re-reading the index first so that concurrent writers lose nothing.
local function update_index(entries)
  local index = read_json(INDEX) or {}
  for id, entry in pairs(entries) do
    index[id] = entry
  end
  write_json(INDEX, index)
end

--- Merges freshly fetched messages (newest first) into a chat's message cache (all kept, or the newest KEEP when
--- LIVEQ_TEAMS_KEEP is set); the fetched copy of
--- a message wins (edits, deletions, reactions). Returns the merged list and its index entry; the index is updated
--- too unless `defer_index` (a refresh writes all its entries at once).
local function store_messages(chat_id, fetched, complete, defer_index)
  local file = message_file(chat_id)
  local cached = read_json(file) or {}
  local seen, list = {}, {}
  for _, m in ipairs(fetched) do
    seen[m.id] = true
    table.insert(list, m)
  end
  for _, m in ipairs(cached.messages or {}) do
    if not seen[m.id] then
      table.insert(list, m)
    end
  end
  table.sort(list, by_time_desc)
  local kept = KEEP and vim.list_slice(list, 1, KEEP) or list
  -- `complete`: the cache reaches back to the chat's first message
  write_json(file, { newest = kept[1] and kept[1].id, messages = kept, complete = (complete or cached.complete or false) and #kept == #list })
  local entry = index_entry(kept)
  if not defer_index then
    update_index { [chat_id] = entry }
  end
  return kept, entry
end

--- Fetches the chat list, newest activity first, then the members of the chats that changed (in $batch requests of
--- 20, since expanding members inline costs seconds per meeting chat). Writes the cache and returns it.
local function fetch()
  local old = read_json(CHATS) or {}
  local old_by_id = {}
  for _, c in ipairs(old.chats or {}) do
    old_by_id[c.id] = c
  end
  local chats, seen_ids = {}, {}
  local url = '/me/chats?$top=50&$expand=lastMessagePreview&$orderby=lastMessagePreview/createdDateTime%20desc'
  while url and #chats < MAX_CHATS do
    local page, err = api('GET', url)
    if not page then
      return nil, err
    end
    for _, c in ipairs(page.value or {}) do
      seen_ids[c.id] = true
      if not vim.tbl_get(c, 'viewpoint', 'isHidden') then
        local p = c.lastMessagePreview
        local prior = old_by_id[c.id]
        table.insert(chats, {
          id = c.id,
          topic = c.topic,
          chatType = c.chatType,
          webUrl = c.webUrl,
          updated = c.lastUpdatedDateTime,
          lastRead = vim.tbl_get(c, 'viewpoint', 'lastMessageReadDateTime'),
          preview = p and {
            id = p.id,
            at = p.createdDateTime,
            from = vim.tbl_get(p, 'from', 'user', 'displayName'),
            fromId = vim.tbl_get(p, 'from', 'user', 'id'),
            text = one_line(body_text(p.body)),
            event = p.messageType ~= 'message' or nil,
          } or nil,
          -- members are kept from the last fetch while the chat itself has not changed
          members = prior and prior.updated == c.lastUpdatedDateTime and prior.members or nil,
        })
      end
    end
    url = page['@odata.nextLink']
  end

  -- chats beyond the newest MAX_CHATS stay, as they were last seen, so their messages remain searchable (a hidden
  -- chat was seen in the pages and stays out)
  for _, c in ipairs(chats) do
    seen_ids[c.id] = true
  end
  for _, c in ipairs(old.chats or {}) do
    if not seen_ids[c.id] then
      seen_ids[c.id] = true
      table.insert(chats, c)
    end
  end

  local missing = vim.tbl_filter(function(c)
    return c.members == nil
  end, chats)
  for i = 1, #missing, 20 do
    local group = vim.list_slice(missing, i, i + 19)
    local requests = {}
    for j, c in ipairs(group) do
      table.insert(requests, { id = tostring(j), method = 'GET', url = '/chats/' .. c.id .. '/members' })
    end
    local reply = api('POST', '/$batch', { requests = requests })
    for _, r in ipairs(reply and reply.responses or {}) do
      local c = group[tonumber(r.id)]
      if c and r.status == 200 and r.body then
        c.members = trim_members(r.body.value)
      end
    end
  end

  -- the latest messages of the chats whose last message is not in the index yet, for searching message text
  local index = read_json(INDEX) or {}
  local stale = vim.tbl_filter(function(c)
    return c.preview and c.preview.id and (index[c.id] or {}).newest ~= c.preview.id
  end, chats)
  local entries = {}
  for i = 1, #stale, 20 do
    local group = vim.list_slice(stale, i, i + 19)
    local requests = {}
    for j, c in ipairs(group) do
      table.insert(requests, { id = tostring(j), method = 'GET', url = '/chats/' .. c.id .. '/messages?$top=50' })
    end
    local reply = api('POST', '/$batch', { requests = requests })
    -- a throttled (429) or failed chat keeps its old entry and is retried by the next refresh
    for _, r in ipairs(reply and reply.responses or {}) do
      local c = group[tonumber(r.id)]
      if c and r.status == 200 and r.body then
        local list = vim.tbl_map(trim_message, r.body.value or {})
        table.sort(list, by_time_desc)
        local _, entry = store_messages(c.id, list, r.body['@odata.nextLink'] == nil, true)
        entries[c.id] = entry
      end
    end
  end
  if next(entries) then
    update_index(entries)
  end

  -- A `read` (opening a chat) or a `show --fresh` may have updated the cache while this fetch was under way; the list
  -- fetched before them would undo that, and the chat would show unread again until the next refresh. So re-read the
  -- cache now and keep, per chat, the later read time and the later last message.
  local current = {}
  for _, c in ipairs((read_json(CHATS) or {}).chats or {}) do
    current[c.id] = c
  end
  for _, c in ipairs(chats) do
    local cur = current[c.id]
    if cur then
      if (epoch(cur.lastRead) or 0) > (epoch(c.lastRead) or 0) then
        c.lastRead = cur.lastRead
      end
      if cur.preview and (epoch(cur.preview.at) or 0) > (epoch(c.preview and c.preview.at) or 0) then
        c.preview = cur.preview
      end
    end
  end

  local my_id, tenant = me()
  local data = { at = os.time(), me = my_id, tenant = tenant, chats = chats }
  write_json(CHATS, data)
  return data
end

--- Backfills the message cache of every chat to `target` messages (or to its first message), paging all chats in
--- parallel through $batch requests of 20. Skips chats already full or complete, so a second run is cheap and an
--- interrupted one resumes: the index is written after every request. Progress goes to stderr.
local function deep(data, target)
  local pending = {}
  for _, c in ipairs(data.chats) do
    local cached = read_json(message_file(c.id)) or {}
    if c.preview and not cached.complete and #(cached.messages or {}) < target then
      table.insert(pending, { chat = c, url = '/chats/' .. c.id .. '/messages?$top=50', got = {} })
    end
  end
  local total, done, requests_made = #pending, 0, 0
  io.stderr:write(('Backfilling %d chats to %d messages each…\n'):format(total, target))
  while #pending > 0 do
    local group = vim.list_slice(pending, 1, 20)
    local requests = {}
    for j, item in ipairs(group) do
      -- $batch takes URLs relative to the version root; a nextLink is absolute
      table.insert(requests, { id = tostring(j), method = 'GET', url = (item.url:gsub('^https://graph%.microsoft%.com/v1%.0', '')) })
    end
    local reply, err = api('POST', '/$batch', { requests = requests })
    requests_made = requests_made + 1
    if not reply then
      return nil, err
    end
    local finished, entries, throttled = {}, {}, false
    for _, r in ipairs(reply.responses or {}) do
      local item = group[tonumber(r.id)]
      if item and r.status == 200 and r.body then
        for _, m in ipairs(r.body.value or {}) do
          table.insert(item.got, trim_message(m))
        end
        local next_link = r.body['@odata.nextLink']
        if next_link and #item.got < target then
          item.url = next_link
        else
          table.sort(item.got, by_time_desc)
          local _, entry = store_messages(item.chat.id, item.got, next_link == nil, true)
          entries[item.chat.id] = entry
          finished[item] = true
        end
      elseif item and r.status == 429 then
        throttled = true -- stays pending, same page, after a pause
      elseif item then
        finished[item] = true -- e.g. 403 for a chat no longer readable: give up on it, keep what it had
      end
    end
    if next(entries) then
      update_index(entries)
    end
    pending = vim.tbl_filter(function(item)
      return not finished[item]
    end, pending)
    done = total - #pending
    io.stderr:write(('\r  %d/%d chats done (%d requests)%s'):format(done, total, requests_made, throttled and ', throttled: pausing' or ''))
    if throttled then
      vim.uv.sleep(5000)
    end
  end
  io.stderr:write '\n'
  return true
end

--- Starts a refresh in the background (detached, so it outlives this search), unless one started in the last 2 minutes.
local function refresh_in_background()
  local lock = CACHE .. '/refresh.lock'
  local stat = vim.uv.fs_stat(lock)
  if stat and os.time() - stat.mtime.sec < 120 then
    return
  end
  write_file(lock, tostring(os.time()))
  pcall(vim.system, { vim.v.progpath, '-l', SCRIPT, 'refresh', '--quiet', '1' }, { detach = true, stdout = false, stderr = false })
end

--- The cached chats; a synchronous fetch when there is no cache, a background one when it is stale.
local function chats()
  local data = read_json(CHATS)
  if not data or not data.chats then
    local err
    data, err = fetch()
    if not data then
      return nil, err
    end
  elseif os.time() - (data.at or 0) > TTL then
    refresh_in_background()
    data.refreshing = true
  end
  return data
end

local function find(id)
  local data = read_json(CHATS)
  for _, c in ipairs(data and data.chats or {}) do
    if c.id == id then
      return c, data
    end
  end
  return nil, data
end

-- -- query --------------------------------------------------------------------------------------------------------

local function terms_of(query)
  local terms = {}
  for quoted in query:gmatch '%-?%a*:?"[^"]*"' do
    table.insert(terms, quoted)
  end
  query = query:gsub('%-?%a*:?"[^"]*"', ' ')
  for word in query:gmatch '%S+' do
    table.insert(terms, word)
  end
  return terms
end

local function plan(query)
  local p = { words = {}, without = {}, with = {} }
  for _, t in ipairs(terms_of(query)) do
    local negated = t:sub(1, 1) == '-' and #t > 1
    local body = negated and t:sub(2) or t
    local key, value = body:match '^(%a+):(.+)$'
    if value then
      value = value:gsub('^"(.*)"$', '%1')
    end
    if key == 'with' then
      table.insert(p.with, { value:lower(), negated })
    elseif key == 'type' then
      p.type = TYPES[value:lower()] or value
      p.type_negated = negated
    elseif key == 'is' and value == 'unread' then
      p.unread = not negated
    elseif key == 'since' then
      p.since = since(value)
    else
      body = body:gsub('^"(.*)"$', '%1'):lower()
      if body ~= '' then
        table.insert(negated and p.without or p.words, body)
      end
    end
  end
  return p
end

--- Whether chat `c` matches plan `p`; also returns the message that matched when a word was found only in messages
--- (the newest one with the most of those words).
local function matches(c, p, my_id, index)
  if p.type and (c.chatType == p.type) == (p.type_negated or false) then
    return false
  end
  if p.unread ~= nil and unread(c, my_id) ~= p.unread then
    return false
  end
  if p.since and (epoch(c.preview and c.preview.at or c.updated) or 0) < p.since then
    return false
  end
  local people = {}
  for _, m in ipairs(c.members or {}) do
    table.insert(people, (m.n or '') .. ' ' .. (m.e or ''))
  end
  local people_text = table.concat(people, '\n'):lower()
  for _, w in ipairs(p.with) do
    if (people_text:find(w[1], 1, true) ~= nil) == w[2] then
      return false
    end
  end
  local haystack = table.concat({ chat_name(c, my_id), people_text, c.preview and c.preview.from or '', c.preview and c.preview.text or '' }, '\n'):lower()
  for _, w in ipairs(p.without) do
    if haystack:find(w, 1, true) then
      return false
    end
  end
  local missing = {}
  for _, w in ipairs(p.words) do
    if not haystack:find(w, 1, true) then
      table.insert(missing, w)
    end
  end
  if #missing == 0 then
    return true
  end
  local found, best, best_n = {}, nil, 0
  for _, m in ipairs(index and index[c.id] and index[c.id].messages or {}) do
    local text, n = m.text:lower(), 0
    for _, w in ipairs(missing) do
      if text:find(w, 1, true) then
        n = n + 1
        found[w] = true
      end
    end
    if n > best_n then
      best, best_n = m, n
    end
  end
  for _, w in ipairs(missing) do
    if not found[w] then
      return false
    end
  end
  return true, best
end

--- Message hits from Graph's own search, by chat (the most relevant hit of each), when the token carries
--- ChannelMessage.Read.All, which only an admin can consent (`o365_auth.py consent --scope ...` asks for it). A token
--- carries every scope consented for its resource, so no other change is needed once it is granted. nil without the
--- scope or on any failure: the search then stays local. Covers all history, not just what the index holds.
local function server_hits(words)
  if #words == 0 then
    return nil
  end
  local tok = token()
  if not tok or not (' ' .. (claims(tok).scp or '') .. ' '):find(' ChannelMessage.Read.All ', 1, true) then
    return nil
  end
  local reply = api('POST', '/search/query', {
    requests = { { entityTypes = { 'chatMessage' }, query = { queryString = table.concat(words, ' ') }, from = 0, size = 50 } },
  })
  local hits = {}
  for _, container in ipairs(vim.tbl_get(reply or {}, 'value', 1, 'hitsContainers') or {}) do
    for _, h in ipairs(container.hits or {}) do
      local r = h.resource or {}
      if r.chatId and not hits[r.chatId] then
        hits[r.chatId] =
          { id = r.id, at = r.createdDateTime, from = vim.tbl_get(r, 'from', 'emailAddress', 'name'), text = one_line(strip_tags(h.summary or '')) }
      end
    end
  end
  return hits
end

--- A Lua pattern matching `word` in any case.
local function ci_pattern(word)
  return (word:gsub('%p', '%%%0'):gsub('%a', function(ch)
    return '[' .. ch:lower() .. ch:upper() .. ']'
  end))
end

--- `line` with the words highlighted, leaving its ANSI escapes alone (a word like `2m` must not match inside one);
--- also returns whether anything was highlighted.
local function highlight(line, words, resume)
  if #words == 0 then
    return line, false
  end
  local hit = false
  local parts, pos = {}, 1
  local function mark(segment)
    for _, w in ipairs(words) do
      local n
      segment, n = segment:gsub(ci_pattern(w), '\27[1;33m%0\27[0m' .. (resume or ''))
      hit = hit or n > 0
    end
    return segment
  end
  for s, e in
    function()
      return line:find('\27%[[%d;]*m', pos)
    end
  do
    table.insert(parts, mark(line:sub(pos, s - 1)))
    table.insert(parts, line:sub(s, e))
    pos = e + 1
  end
  table.insert(parts, mark(line:sub(pos)))
  return table.concat(parts), hit
end

--- The part of `text` around the first of the words, so the match is visible in a row of the picker.
local function excerpt(text, words)
  local lower, first = text:lower(), nil
  for _, w in ipairs(words) do
    local at = lower:find(w, 1, true)
    if at and (not first or at < first) then
      first = at
    end
  end
  local start = math.max(1, (first or 1) - 40)
  while start > 1 and (text:byte(start) or 0) >= 0x80 and (text:byte(start) or 0) < 0xC0 do
    start = start - 1 -- not in the middle of a UTF-8 character
  end
  return (start > 1 and '…' or '') .. text:sub(start)
end

-- -- commands -----------------------------------------------------------------------------------------------------

local function clean(s)
  return ((s or ''):gsub('[\t\r\n]+', ' '))
end

local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. '…'
  end
  return s .. string.rep(' ', width - w)
end

local function age(at)
  local secs = os.time() - (at or 0)
  if secs < 90 then
    return 'just now'
  elseif secs < 3600 then
    return math.floor(secs / 60) .. 'm old'
  end
  return math.floor(secs / 3600) .. 'h old'
end

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local limit = tonumber(opts.l or opts.limit) or 200
  local data, err = chats()
  if not data then
    out('\t\27[31m' .. clean(err) .. '\27[0m\t\t')
    return
  end
  local my_id = data.me
  local p = plan(query)
  local index = #p.words > 0 and read_json(INDEX) or nil
  local found, hits = {}, {}
  local remote = server_hits(p.words)
  local loose = remote and vim.tbl_extend('force', p, { words = {} }) -- the query's other filters still apply
  local listed = {}
  for _, c in ipairs(data.chats) do
    listed[c.id] = true
    local ok, hit = matches(c, p, my_id, index)
    if not ok and remote and remote[c.id] and matches(c, loose, my_id) then
      ok, hit = true, remote[c.id]
    end
    if ok then
      table.insert(found, c)
      hits[c.id] = hit
    end
  end
  local unread_count = #vim.tbl_filter(function(c)
    return unread(c, my_id)
  end, data.chats)
  if query == '' then
    out(
      ('\t\27[2m%d chats, %d unread (cache %s%s). Filter: words with: type:1:1|group|meeting is:unread since:7d   enter: open chat  ctrl-r: refresh\27[0m\t\t'):format(
        #data.chats,
        unread_count,
        age(data.at),
        data.refreshing and ', refreshing' or ''
      )
    )
  elseif #found == 0 then
    out '\t\27[33mNo chats match\27[0m\t\t'
  end
  local beyond = 0
  for chat_id in pairs(remote or {}) do
    beyond = beyond + (listed[chat_id] and 0 or 1)
  end
  if beyond > 0 then
    out(('\t\27[2m+%d older chats also match (beyond the %d cached; raise LIVEQ_TEAMS_MAX)\27[0m\t\t'):format(beyond, #data.chats))
  end
  for i = 1, math.min(#found, limit) do
    local c = found[i]
    local name = clean(chat_name(c, my_id))
    local pv = c.preview or {}
    local who = pv.fromId == my_id and 'you' or (pv.from or ''):match '^[^,%s]+' or ''
    local last = pv.event and '\27[2m(event)\27[0m' or ('\27[2m' .. (who ~= '' and (who .. ': ') or '') .. clean(pv.text) .. '\27[0m')
    local hit = hits[c.id]
    if hit then
      -- found in a message other than the last one: show that message, with its own time
      local by = hit.fromId == my_id and 'you' or (hit.from or ''):match '^[^,%s]+' or ''
      local text = highlight(clean(excerpt(hit.text, p.words)), p.words, '\27[2m')
      last = ('\27[2m↳ %s %s: %s\27[0m'):format(short_time(hit.at), by, text)
    end
    local new = unread(c, my_id)
    local display = ('%s %s %s %s %s'):format(
      new and '\27[33m●\27[0m' or ' ',
      pad(short_time(pv.at or c.updated), 6),
      TYPE_TAG[c.chatType] or '   ',
      (new and '\27[1m' or '') .. pad(name, 40) .. '\27[0m',
      last
    )
    out(('%s\t%s\t%s\t%s'):format(c.id, display, clean(c.webUrl), name))
  end
end

--- The messages of a chat, newest first: from the per-chat cache when its newest message is still the chat's last
--- one and it holds enough of them, else from Graph (50 per page).
local function messages(chat, count, fresh, any_cached)
  local cached = read_json(message_file(chat.id))
  local newest = chat.preview and chat.preview.id
  -- `any_cached`: whatever the cache holds will do (a search hit is in it, since the index is made from it)
  if not fresh and cached and cached.newest == newest and newest and (any_cached or #cached.messages >= count or cached.complete) then
    return vim.list_slice(cached.messages, 1, math.min(count, #cached.messages))
  end
  if any_cached then
    count = math.min(count, 100) -- "all cached" with nothing cached: a preview, not the whole history
  end
  local list, url = {}, '/chats/' .. chat.id .. '/messages?$top=50'
  local complete = false
  while url and #list < count do
    local page, err = api('GET', url)
    if not page then
      return nil, err
    end
    for _, m in ipairs(page.value or {}) do
      table.insert(list, trim_message(m))
    end
    url = page['@odata.nextLink']
    complete = url == nil
  end
  table.sort(list, by_time_desc)
  -- keyed by the newest message actually fetched: while the chat list is behind (its preview older than that), the
  -- keys differ and the chat is fetched again on each show, until a refresh catches the list up
  store_messages(chat.id, list, complete)
  -- a newer message than the chat list knows of: bring the list's preview (and unread state) up to date with it
  local top = list[1]
  if top and top.id ~= newest then
    local data = read_json(CHATS)
    for _, c in ipairs(data and data.chats or {}) do
      if c.id == chat.id then
        c.preview = { id = top.id, at = top.at, from = top.from, fromId = top.fromId, text = one_line(top.text), event = top.type ~= 'message' or nil }
        write_json(CHATS, data)
        break
      end
    end
  end
  return list
end

local function reaction_summary(list)
  if not list or #list == 0 then
    return ''
  end
  local counts, order = {}, {}
  for _, r in ipairs(list) do
    if not counts[r] then
      table.insert(order, r)
    end
    counts[r] = (counts[r] or 0) + 1
  end
  return '  ['
    .. table.concat(
      vim.tbl_map(function(r)
        return r .. (counts[r] > 1 and (' ×' .. counts[r]) or '')
      end, order),
      ', '
    )
    .. ']'
end

local function show(opts, rest)
  local id = rest[1]
  if not id or not id:match '^%d+:' then
    return
  end
  local chat, data = find(id)
  if not chat then
    out('Chat ' .. id .. ' is not in the cache (ctrl-r in the picker refreshes it)')
    return
  end
  local my_id = data.me
  local plain = opts.plain
  local words = opts.match and plan(opts.match).words or {}
  local list, err = messages(chat, tonumber(opts.count) or ((plain or #words > 0) and (#words > 0 and 100000 or 100) or 30), opts.fresh, #words > 0)
  if not list then
    out((plain and '' or '\27[31m') .. 'Cannot fetch the messages: ' .. err .. (plain and '' or '\27[0m'))
    return
  end
  if opts.chronological then
    list = vim.fn.reverse(list)
  end
  local lines = {}
  local name = chat_name(chat, my_id)
  if plain then
    vim.list_extend(lines, { '# ' .. name, '' })
    local names = member_names(chat, my_id)
    if chat.topic and #names > 0 then
      local shown = vim.list_slice(names, 1, 12)
      table.insert(lines, '_With ' .. table.concat(shown, ', ') .. (#names > 12 and (' and ' .. (#names - 12) .. ' more') or '') .. '_')
      table.insert(lines, '')
    end
  else
    table.insert(lines, '\27[1m' .. name .. '\27[0m  \27[2m' .. (chat.chatType or '') .. ', newest first\27[0m')
    table.insert(lines, '')
  end
  for _, m in ipairs(list) do
    local who = m.fromId == my_id and 'You' or (m.from or '?')
    if m.type ~= 'message' then
      local what = (m.event or m.type or 'event'):gsub('^#microsoft%.graph%.', ''):gsub('EventMessageDetail$', '')
      table.insert(
        lines,
        plain and ('_— ' .. what .. ' · ' .. long_time(m.at) .. ' —_') or ('\27[2m— ' .. what .. ' · ' .. long_time(m.at) .. ' —\27[0m')
      )
      table.insert(lines, '')
    elseif m.deleted then
      table.insert(
        lines,
        plain and ('_' .. who .. ' deleted a message · ' .. long_time(m.at) .. '_')
          or ('\27[2m' .. who .. ' deleted a message · ' .. long_time(m.at) .. '\27[0m')
      )
      table.insert(lines, '')
    else
      local meta = long_time(m.at) .. (m.edited and ' (edited)' or '') .. reaction_summary(m.reactions)
      if plain then
        table.insert(lines, '## ' .. who .. ' · ' .. meta)
      else
        local colour = m.fromId == my_id and '\27[32m' or '\27[36m'
        table.insert(lines, colour .. '\27[1m' .. who .. '\27[0m \27[2m' .. meta .. '\27[0m')
      end
      if m.subject and m.subject ~= '' then
        table.insert(lines, plain and ('**' .. m.subject .. '**') or ('\27[1m' .. m.subject .. '\27[0m'))
      end
      table.insert(lines, render_quotes(m.text, plain))
      table.insert(lines, '')
    end
  end
  if #words == 0 then
    out(table.concat(lines, '\n'))
    return
  end
  -- highlight the words, and tell liveq's picker the lines that have them, so the preview scrolls to the first
  local numbers = {}
  for n, line in ipairs(vim.split(table.concat(lines, '\n'), '\n', { plain = true })) do
    local marked, hit = highlight(line, words)
    if hit and n > 1 then
      table.insert(numbers, n)
    end
    io.stdout:write(marked, '\n')
  end
  io.stdout:flush()
  local file = os.getenv 'LIVEQ_MATCH_FILE'
  if file and file ~= '' then
    local f = io.open(file, 'w')
    if f then
      f:write(id, '\n', #numbers > 0 and 1 or 0, '\n', table.concat(numbers, ' '), '\n')
      f:close()
    end
  end
end

local function terms(_, rest)
  out(vim.json.encode(vim.tbl_map(function(w)
    return { w }
  end, plan(rest[1] or '').words)))
end

local function url(_, rest)
  local chat = rest[1] and find(rest[1])
  if chat and chat.webUrl then
    out(chat.webUrl)
  end
end

local function refresh(opts)
  local data, err = fetch()
  os.remove(CACHE .. '/refresh.lock')
  if not data then
    fail(err)
  end
  if opts.deep then
    local ok, deep_err = deep(data, tonumber(opts.deep) or DEEP)
    if not ok then
      fail('deep: ' .. deep_err)
    end
  end
  if not opts.quiet then
    io.stderr:write(('Fetched %d chats\n'):format(#data.chats))
  end
end

local function html_escape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

--- Posts a message to a chat. Multi-line text keeps its lines (as <br>); it is never sent empty.
local function send(opts, rest)
  local id = rest[1]
  if not id or not id:match '^%d+:' then
    fail 'send: no chat id'
  end
  local text
  if opts.file then
    local file = io.open(opts.file, 'r')
    if not file then
      fail('send: cannot read ' .. opts.file)
    end
    text = file:read '*a'
    file:close()
  else
    text = table.concat(vim.list_slice(rest, 2), ' ')
  end
  text = vim.trim(text or '')
  if text == '' then
    fail 'send: the message is empty'
  end
  local html = html_escape(text):gsub('\r?\n', '<br>')
  local reply, err = api('POST', '/chats/' .. id .. '/messages', { body = { contentType = 'html', content = html } })
  if not reply then
    fail('send: ' .. err)
  end
  out(reply.id or '')
end

local function read(_, rest)
  local id = rest[1]
  if not id or not id:match '^%d+:' then
    fail 'read: no chat id'
  end
  local my_id, tenant = me()
  if not my_id then
    fail 'read: no user id in the token'
  end
  local _, err = api('POST', '/chats/' .. id .. '/markChatReadForUser', { user = { id = my_id, tenantId = tenant } })
  if err then
    fail('read: ' .. err)
  end
  -- reflect it in the cache, so the chat stops showing as unread before the next refresh
  local data = read_json(CHATS)
  for _, c in ipairs(data and data.chats or {}) do
    if c.id == id and c.preview then
      c.lastRead = c.preview.at
      write_json(CHATS, data)
      break
    end
  end
end

-- -- complete -----------------------------------------------------------------------------------------------------

local PREFIXES = {
  { 'with:', "a member's name or address" },
  { 'type:', '1:1, group or meeting' },
  { 'is:unread', 'chats with unread messages' },
  { 'since:', 'last activity since: 1d, 7d, 2w, 1M or a date' },
}

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
  local before = vim.fn.strcharpart(text, 0, cursor)
  local start = cursor
  while start > 0 and not vim.fn.strcharpart(before, start - 1, 1):match '%s' do
    start = start - 1
  end
  local finish, length = cursor, vim.fn.strchars(text)
  while finish < length and not vim.fn.strcharpart(text, finish, 1):match '%s' do
    finish = finish + 1
  end
  local term = vim.fn.strcharpart(text, start, cursor - start)
  local sign, key, value = term:match '^(%-?)(%a+):(.*)$'

  local context, candidates = 'field', {}
  local add = function(insert, kind, detail)
    table.insert(candidates, { display = insert, insert = insert .. ' ', cursor_offset = vim.fn.strchars(insert) + 1, kind = kind, detail = detail or '' })
  end
  if key == 'with' then
    context = 'value'
    local data = read_json(CHATS) or {}
    local counts, typed = {}, value:lower():gsub('^"', '')
    for _, c in ipairs(data.chats or {}) do
      for _, m in ipairs(c.members or {}) do
        if m.u ~= data.me and m.n and m.n ~= '' then
          counts[m.n] = (counts[m.n] or 0) + 1
        end
      end
    end
    local list = {}
    for n, k in pairs(counts) do
      -- any word of the name may be the one typed
      local lower = n:lower()
      if typed == '' or lower:sub(1, #typed) == typed or lower:find('[%s,]' .. vim.pesc(typed)) then
        table.insert(list, { n, k })
      end
    end
    table.sort(list, function(a, b)
      return a[2] ~= b[2] and a[2] > b[2] or a[1] < b[1]
    end)
    for i = 1, math.min(#list, 100) do
      local n = list[i][1]
      add(sign .. 'with:' .. (n:find '[%s,]' and ('"' .. n .. '"') or n), 'value', list[i][2] .. ' chats')
    end
  elseif key == 'type' or key == 'since' or key == 'is' then
    context = 'value'
    local values = ({ type = { '1:1', 'group', 'meeting' }, since = { '1d', '7d', '2w', '1M', '3M' }, is = { 'unread' } })[key]
    for _, v in ipairs(values) do
      if v:sub(1, #value) == value then
        add(sign .. key .. ':' .. v, 'value')
      end
    end
  elseif term == '' or term:match '^%-?%a*$' then
    local bare = term:gsub('^%-', '')
    for _, p in ipairs(PREFIXES) do
      if p[1]:sub(1, #bare) == bare and p[1] ~= bare then
        local open = p[1]:match ':$'
        local insert = (term:sub(1, 1) == '-' and '-' or '') .. p[1]
        table.insert(candidates, {
          display = insert,
          insert = open and insert or (insert .. ' '),
          cursor_offset = vim.fn.strchars(insert) + (open and 0 or 1),
          kind = open and 'field' or 'keyword',
          detail = p[2],
        })
      end
    end
  end
  out(vim.json.encode { context = context, prefix = term, replace_start = start, replace_end = finish, candidates = candidates })
end

local commands = { search = search, show = show, terms = terms, complete = complete, url = url, refresh = refresh, send = send, read = read }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
