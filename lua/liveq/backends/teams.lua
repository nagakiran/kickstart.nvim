-- The Microsoft Teams chat backend of liveq, run with `nvim -l`, talking to Microsoft Graph with curl.
--
--   nvim -l teams.lua search -f fzf -l LIMIT -- QUERY      chats from the on-disk cache, newest activity first
--   nvim -l teams.lua show [--plain] [--chronological] [--count N] [--fresh] -- CHAT_ID   (--fresh skips the cache)
--   nvim -l teams.lua show --images -- CHAT_ID             ...with the images pasted into messages drawn (see images)
--   nvim -l teams.lua show --plain --images -- CHAT_ID     ...with each [image] as `[image: FILE.png]`, the cached file
--                                                           (downloaded now, the newest LIVEQ_TEAMS_IMAGE_MAX), for
--                                                           a reader that looks at them (the Claude drafts)
--   nvim -l teams.lua images -f fzf -- CHAT_ID             the chat's images, a row each (`URL#WxH`), newest first
--   nvim -l teams.lua image [--copy|--open] -- URL#WxH     one of them as large as the preview, or copied, or opened
--   nvim -l teams.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l teams.lua url -- CHAT_ID                       the chat in the Teams web client
--   nvim -l teams.lua members -f fzf -- CHAT_ID            the chat's members, a row each (`address \t name address`)
--   nvim -l teams.lua people -f fzf -- CHAT_ID             the people of your other chats, to add to this one
--   nvim -l teams.lua add-members [--history all|none|DAYS] -- CHAT_ID ADDRESS...   add people to a group chat
--   nvim -l teams.lua refresh                              fetch the chat list (and new members) into the cache
--   nvim -l teams.lua refresh --deep [N]                   ...then backfill every chat's history to N messages (300)
--   nvim -l teams.lua send [--file PATH] [--dry-run] -- CHAT_ID [TEXT]   post a message (TEXT, or the file's
--                                                          contents) written in Markdown: lists, `code`, ``` blocks,
--                                                          > quotes, **bold**, links; `@Lastname, Firstname` (or a
--                                                          member's unique first/last name) is a real @mention; a line
--                                                          `![...](PATH)` sends that image inline, `[...](PATH)`
--                                                          attaches that file (OneDrive, shared with the chat);
--                                                          --dry-run prints the HTML and mentions, sends nothing
--   nvim -l teams.lua read -- CHAT_ID                      mark the chat read, as opening it in Teams does
--   nvim -l teams.lua show --match QUERY -- CHAT_ID         the preview, with the query's words highlighted (with
--                                                          --plain, not highlighted: for liveq's buffer and float);
--                                                          $LIVEQ_MATCH_FILE gets the lines of the matches
--   nvim -l teams.lua terms -- QUERY                       the query's words, as JSON (for liveq's n/N)
--   nvim -l teams.lua calls                                re-read the Teams desktop app's call log (macOS)
--
-- The query, evaluated locally over the cache:
--   words (each must be in the chat's name, members or messages; -word excludes, on name/members/last message only)
--   with:NAME (a member's name or address)   type:1:1|group|meeting|calls (or the list's tags: grp|mtg|you|cal)   is:unread   since:7d|2w|1M|2026-11-01 (last activity)
--   from:me|NAME (a message sent by you, or by someone whose name has NAME; with on:, that day; -from: none of theirs)
--   has:call (chats with a call; with on:, a call that day; the row shows its duration and the calls' total)
--   on:DATE (a message that local day: 2026-11-05, 11-05, today, yesterday, 3d = three days ago; on:11-03..11-05 a range;
--   with words, a message of those days must have the words not found in the name/members/last message)
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
-- Calls: a call started from a chat posts callStarted/callEnded events into it, the latter with the duration and the
-- people; they are kept in the message cache and the index (`calls`) and shown in the chat. A call from the Calls app
-- posts nothing into the chat; Teams logs every call in the hidden thread 48:calllogs, which Graph reads like 48:notes
-- but strips to "Call Logs for Call <id>" and the end time. It is listed as the chat "Calls" (`type:calls`), each call
-- joined by its id to the chat event that has its duration and people, when there is one.
--
-- On macOS the Teams desktop app (new Teams) caches the whole call log in its IndexedDB: start, answer and end times,
-- direction, missed or not, the people. teams_calls.py reads it (read-only, standard-library Python) into calls.json in
-- the cache, merged with what it held, so calls the app forgets stay. Then the "Calls" chat shows every call with its
-- start, direction and duration and each day's total, a chat shows its calls inline (a 1:1 by the other person, a
-- group call by its thread), and has:call counts them. A refresh re-reads it (about 4s) only when Graph's log has a
-- call it lacks; `nvim -l teams.lua calls` re-reads it now. LIVEQ_TEAMS_DESKTOP_DB names the app's LevelDB directory
-- ('' turns this off); without the app or python3 everything above still works from Graph alone.
--
-- Meetings attended: the chat "Meetings attended" (`type:attended`) lists the meetings you joined by start time, how
-- long each ran and each day's total, with the day's call time beside it. A meeting counts when you are among the
-- people of its callEnded event: Graph's (in the index) and, on macOS, the desktop app's (teams_calls.py, back months
-- further), joined by call id. Teams keeps no join or leave times (every participant's duration in the event is the
-- call's length), so a meeting's time is its length, an upper bound; overlapping meetings count once in a day's total.
--
-- Auth: a Graph token (Chat.ReadWrite, User.Read; Files.ReadWrite to attach files, Files.Read.All to name Loop
-- components) printed by LIVEQ_TEAMS_TOKEN_CMD, by default
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
local TYPES = {
  ['1:1'] = 'oneOnOne',
  dm = 'oneOnOne',
  oneonone = 'oneOnOne',
  group = 'group',
  grp = 'group',
  meeting = 'meeting',
  mtg = 'meeting',
  meet = 'meeting',
  self = 'self',
  notes = 'self',
  you = 'self',
  calls = 'calls',
  attended = 'attended',
  meetings = 'attended',
  att = 'attended',
  call = 'calls',
  cal = 'calls',
}
local TYPE_TAG = {
  oneOnOne = '\27[32m1:1\27[0m',
  group = '\27[34mgrp\27[0m',
  meeting = '\27[35mmtg\27[0m',
  self = '\27[33myou\27[0m',
  calls = '\27[36mcal\27[0m',
  attended = '\27[35matt\27[0m',
}
-- The self chat ("notes to self") is not in /me/chats and /chats/48:notes is refused ("not a ChatThread"), but its
-- messages are readable at /chats/48:notes/messages: fetch() adds it to the list from its newest message.
local SELF_CHAT = '48:notes'
local CALL_LOG = '48:calllogs'
-- the chats that are not in /me/chats, added to the list from their newest message
-- the summary of meetings attended, made by fetch() from the meetings' callEnded events (no Graph chat)
local MEETINGS = '0:meetings'
local PSEUDO = {
  { id = SELF_CHAT, topic = 'Notes (you)', chatType = 'self', webUrl = 'https://teams.microsoft.com/l/chat/48:notes/0' },
  -- the Calls app
  { id = CALL_LOG, topic = 'Calls', chatType = 'calls', webUrl = 'https://teams.microsoft.com/l/app/20c3440d-c67e-4420-9f80-0e50c39693df' },
}
local SCRIPT = debug.getinfo(1, 'S').source:sub(2)
local DESKTOP_DB = os.getenv 'LIVEQ_TEAMS_DESKTOP_DB'
  or (
    HOME
    .. '/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView/WV2Profile_tfw/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb'
  )
local CALLS_READER = vim.fs.dirname(SCRIPT) .. '/teams_calls.py'
local LOCAL_CALLS = CACHE .. '/calls.json'
local TITLES = CACHE .. '/titles.json' -- topics of chats outside the list (meetings attended long ago), kept for good
local INDEX = CACHE .. '/index.json'
local KEEP = tonumber(os.getenv 'LIVEQ_TEAMS_KEEP') -- nil: keep every message
local DEEP = 300 -- messages per chat that `refresh --deep` backfills to, unless given
local FETCH_MAX = 1000 -- messages a `show` fetches from Graph at most, for a chat that has none of them cached

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
    elseif
      a == '--plain'
      or a == '--chronological'
      or a == '--fresh'
      or a == '--quiet'
      or a == '--images'
      or a == '--copy'
      or a == '--open'
      or a == '--dry-run'
    then
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

--- Seconds of an ISO 8601 duration (`PT1H9M3.52S`), or nil.
local function duration_secs(iso)
  if type(iso) ~= 'string' or not iso:match '^P' then
    return nil
  end
  local secs = tonumber(iso:match '^P(%d+)D' or 0) * DAY
  for n, unit in (iso:match 'T(.*)$' or ''):gmatch '([%d.]+)([HMS])' do
    secs = secs + tonumber(n) * ({ H = 3600, M = 60, S = 1 })[unit]
  end
  return math.floor(secs + 0.5)
end

--- A duration as Teams shows it: 1h 9m, 8m 12s, 1s; `?` when unknown.
local function fmt_duration(secs)
  if not secs then
    return '?'
  end
  local h, m, s = math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60
  if h > 0 then
    return ('%dh %dm'):format(h, m)
  elseif m > 0 then
    return s > 0 and ('%dm %ds'):format(m, s) or (m .. 'm')
  end
  return s .. 's'
end

local function since(value)
  local n, unit = value:match '^(%d+)([dwMy])$'
  if n then
    return os.time() - tonumber(n) * UNITS[unit]
  end
  return value:match '^%d%d%d%d%-%d%d%-%d%d$' and epoch(value .. 'T00:00:00') or nil
end

--- The local days [start, stop) of `on:`: a day (2026-11-05, 11-05 this year, today, yesterday, 3d ago) or A..B.
local function day_range(value)
  local function day(v)
    local now = os.date '*t'
    local y, m, d = v:match '^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$'
    if not y then
      m, d = v:match '^(%d%d?)%-(%d%d?)$'
      y = m and now.year
    end
    if not y then
      local back = v == 'today' and 0 or v == 'yesterday' and 1 or tonumber(v:match '^(%d+)d$')
      if not back then
        return nil
      end
      y, m, d = now.year, now.month, now.day - back
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    return os.time { year = y, month = m, day = d, hour = 0 }, os.time { year = y, month = m, day = d + 1, hour = 0 }
  end
  local a, b = value:match '^(.-)%.%.(.+)$'
  local start, stop = day(a or value)
  if b then
    local _, last = day(b)
    stop = last
  end
  return start and stop and { start, stop } or nil
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

--- How an attachment reads in a message: a Loop component (fluidEmbedCard) as `[loop] url`, its link without the
--- `nav` query (Teams' own context for the Loop app, which the link opens fine without); any other as `[file: name] url`.
--- Graph does not give a Loop component's text: it lives in a .loop file in the sender's OneDrive, behind Files.Read.All.
local function attachment_line(a)
  if a.contentType == 'application/vnd.microsoft.card.fluidEmbedCard' then
    local ok, card = pcall(vim.json.decode, a.content or '')
    local url = ok and type(card) == 'table' and type(card.componentUrl) == 'string' and card.componentUrl
    return '[loop]' .. (url and (' ' .. url:gsub('%?nav=[^&]*$', '')) or '')
  end
  return '[file: ' .. (a.name or a.contentType or '?') .. ']' .. (a.contentUrl and (' ' .. a.contentUrl) or '')
end

--- The text of a message body. `attachments` resolves the `<attachment id=...>` placeholders: quoted replies
--- (messageReference) become `> Sender: preview` lines, files become `[file: name] url`. Images pasted into the message
--- (hosted by Teams) become `[image]`, and when `images` is given, their URL and size are added to it in that order.
local function body_text(body, attachments, images)
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
    return '\n' .. attachment_line(a) .. '\n'
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
  s = s:gsub('<img[^>]*>', function(tag)
    local src = tag:match 'src="([^"]*/hostedContents/[^"]*)"'
    if not src then
      return nil
    end
    if images then
      table.insert(images, {
        url = entities(src),
        w = tonumber(tag:match 'width="([%d.]+)"'),
        h = tonumber(tag:match 'height="([%d.]+)"'),
      })
    end
    return '[image]'
  end)
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
      text = text .. '\n' .. attachment_line(a)
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

-- -- Loop components ----------------------------------------------------------------------------------------------

-- What the `[loop] url` lines of the messages shown point at: the .loop file's name, who last edited it and when, by
-- url, from Graph's /shares (Files.Read.All, since the file is in the sender's OneDrive). Kept LOOP_TTL seconds, so a
-- preview redrawn as you type costs no calls; a link Graph refuses is kept as { err } just as long.
local LOOPS = CACHE .. '/loops.json'
local LOOP_TTL = 600
local LOOP_LINE = '%[loop%] (https://%S+)'

local function share_id(url)
  return 'u!' .. vim.base64.encode(url):gsub('=+$', ''):gsub('/', '_'):gsub('%+', '-')
end

--- The Loop files behind `urls`, by url: { name, by, at } or { err }. Fetches those not cached (or stale) through
--- $batch requests of 20; when Graph cannot be reached, what it has.
local function loop_info(urls)
  local cache = read_json(LOOPS) or {}
  local now, want, seen = os.time(), {}, {}
  for _, url in ipairs(urls) do
    local c = cache[url]
    if not seen[url] and (not c or now - (c.checked or 0) > LOOP_TTL) then
      seen[url] = true
      table.insert(want, url)
    end
  end
  for i = 1, #want, 20 do
    local group, requests = vim.list_slice(want, i, i + 19), {}
    for j, url in ipairs(group) do
      local path = '/shares/' .. share_id(url) .. '/driveItem?$select=name,lastModifiedDateTime,lastModifiedBy'
      table.insert(requests, { id = tostring(j), method = 'GET', url = path })
    end
    local reply = api('POST', '/$batch', { requests = requests })
    if not reply then
      break
    end
    for _, r in ipairs(reply.responses or {}) do
      local url = group[tonumber(r.id)]
      if url and r.status == 200 and r.body then
        cache[url] = {
          checked = now,
          name = (r.body.name or ''):gsub('%.loop$', ''),
          by = vim.tbl_get(r.body, 'lastModifiedBy', 'user', 'displayName'),
          at = r.body.lastModifiedDateTime,
        }
      elseif url and r.status ~= 429 then
        cache[url] = { checked = now, err = r.status }
      end
    end
  end
  if #want > 0 then
    write_json(LOOPS, cache)
  end
  return cache
end

--- The urls of the `[loop]` lines in some messages.
local function loop_urls(list)
  local urls = {}
  for _, m in ipairs(list) do
    for url in (m.text or ''):gmatch(LOOP_LINE) do
      table.insert(urls, url)
    end
  end
  return urls
end

--- `text` with each `[loop] url` line naming its file and last edit, when `info` knows it.
local function describe_loops(text, info, plain)
  return (
    text:gsub(LOOP_LINE, function(url)
      local i = info[url]
      if not i or not i.name then
        return nil
      end
      local edit = (i.by and (' · edited by ' .. i.by) or '') .. (i.at and (' ' .. long_time(i.at)) or '')
      if plain then
        return ('[loop: **%s**%s] %s'):format(i.name, edit, url)
      end
      return ('\27[1m[loop: %s\27[0m\27[2m%s\27[0m\27[1m]\27[0m %s'):format(i.name, edit, url)
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
  if chat.id == SELF_CHAT or chat.id == CALL_LOG then
    return false -- only you write there; the call log has no read state
  end
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

--- The call of a callStarted/callEnded event: its id, and for an end the duration (secs) and the people (with).
local function call_info(detail)
  local kind = detail and detail['@odata.type']
  local by = detail and vim.tbl_get(detail, 'initiator', 'user', 'id')
  if kind == '#microsoft.graph.callEndedEventMessageDetail' then
    local with = {}
    for _, p in ipairs(detail.callParticipants or {}) do
      local u = vim.tbl_get(p, 'participant', 'user') or {}
      table.insert(with, { n = u.displayName, u = u.id })
    end
    return { id = detail.callId, secs = duration_secs(detail.callDuration), with = with, by = by, kind = detail.callEventType }
  elseif kind == '#microsoft.graph.callStartedEventMessageDetail' then
    return { id = detail.callId, started = true, by = by, kind = detail.callEventType }
  end
end

local function trim_message(m)
  local images = {}
  local text = body_text(m.body, m.attachments, images)
  -- an entry of the call log: Graph leaves only the call's id (and the time it ended)
  local logged = m.chatId == CALL_LOG and text:match 'Call Logs for Call (%S+)'
  return {
    id = m.id,
    at = m.createdDateTime,
    edited = m.lastEditedDateTime,
    deleted = m.deletedDateTime,
    from = vim.tbl_get(m, 'from', 'user', 'displayName') or vim.tbl_get(m, 'from', 'application', 'displayName'),
    fromId = vim.tbl_get(m, 'from', 'user', 'id'),
    type = logged and 'calllog' or m.messageType,
    event = m.eventDetail and m.eventDetail['@odata.type'],
    call = logged and { id = logged } or call_info(m.eventDetail),
    subject = m.subject,
    text = text,
    -- present (if empty) whenever the text says image, so `show --images` can tell a message cached before images
    -- were kept (its pasted images then read "image", their alt text) and fetch it again
    images = (#images > 0 or text:lower():find('image', 1, true)) and images or nil,
    reactions = vim.tbl_map(function(r)
      return r.displayName or r.reactionType
    end, m.reactions or {}),
  }
end

local function message_file(chat_id)
  return CACHE .. '/messages/' .. chat_id:gsub('[^%w]', '_') .. '.json'
end

--- The searchable part of a chat's messages (newest first): real messages, one line each, quotes dropped.
--- Also the chat's ended calls, newest first: id, end time, duration and people (none of these for an event cached
--- before calls were kept, which a refresh of the chat fills in).
local function index_entry(list)
  local msgs, calls = {}, {}
  for _, m in ipairs(list) do
    if m.type == 'message' and not m.deleted then
      local text = one_line(m.text)
      if text ~= '' then
        table.insert(msgs, { id = m.id, at = m.at, from = m.from, fromId = m.fromId, text = text })
      end
    elseif m.event == '#microsoft.graph.callEndedEventMessageDetail' then
      local c = m.call or {}
      table.insert(calls, { id = c.id, at = m.at, secs = c.secs, with = c.with, kind = c.kind })
    end
  end
  return { newest = list[1] and list[1].id, messages = msgs, calls = calls }
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

--- Reads the desktop app's call log (teams_calls.py) into LOCAL_CALLS, merged with what it held: the app drops old
--- calls in time. nil, quietly, without the app's directory or python3.
local function sync_local_calls()
  if DESKTOP_DB == '' or not vim.uv.fs_stat(DESKTOP_DB) or vim.fn.executable 'python3' ~= 1 then
    return nil
  end
  local result = vim.system({ 'python3', '-I', CALLS_READER, DESKTOP_DB }, { text = true }):wait(120000)
  local ok, list = pcall(vim.json.decode, result.code == 0 and result.stdout or '', { luanil = { object = true, array = true } })
  if not ok or type(list) ~= 'table' then
    return nil
  end
  local old = read_json(LOCAL_CALLS) or {}
  local held, meetings = old.calls or {}, old.meetings or {}
  for _, c in ipairs(list.calls or list) do
    held[c.id] = c
  end
  for _, m in ipairs(list.meetings or {}) do
    meetings[m.id] = m
  end
  local data = { at = os.time(), calls = held, meetings = meetings }
  write_json(LOCAL_CALLS, data)
  return data
end

--- The desktop app's calls (from LOCAL_CALLS), newest first, and by id: id, at (start), ended, secs (answered to end;
--- nil for a missed call), dir, state, kind, with (the people other than you, named from the chats' members when the
--- log has no name) and chat (the group call's thread, or the 1:1 chat with the one other person).
local function desktop_calls(data)
  local file = read_json(LOCAL_CALLS)
  if not file or not file.calls then
    return {}, {}
  end
  local my_id = data and data.me
  local names, one_on_one = {}, {}
  for _, c in ipairs(data and data.chats or {}) do
    for _, m in ipairs(c.members or {}) do
      if m.u and m.n and m.n ~= '' then
        names[m.u] = names[m.u] or m.n
      end
      if c.chatType == 'oneOnOne' and m.u and m.u ~= my_id then
        one_on_one[m.u] = one_on_one[m.u] or c.id
      end
    end
  end
  local list, by_id = {}, {}
  for id, k in pairs(file.calls) do
    local with = {}
    for _, p in ipairs(k.people or {}) do
      if not p.u or p.u ~= my_id then
        table.insert(with, { u = p.u, n = p.n or (p.u and names[p.u]) })
      end
    end
    local connect, stop = epoch(k.connect), epoch(k['end'])
    local rec = {
      id = id,
      at = k.start or k['end'],
      ended = k['end'] or k.start,
      secs = connect and stop and k.state ~= 'missed' and math.floor(stop - connect) or nil, -- as Teams shows it: whole seconds, not rounded
      dir = k.dir,
      state = k.state,
      kind = k.type,
      with = with,
      chat = k.thread or (#with == 1 and with[1].u and one_on_one[with[1].u]) or nil,
    }
    table.insert(list, rec)
    by_id[id] = rec
  end
  table.sort(list, by_time_desc)
  return list, by_id
end

local CALL_ARROW = { incoming = '←', outgoing = '→' }

--- The meetings you joined, newest first: id, chat, start and stop (epoch), secs (the meeting's length) and n (the
--- people who joined). From the callEnded events of the index (Graph) and of the desktop app (LOCAL_CALLS), by call
--- id; a meeting is a call in a meeting chat or of a scheduled or recurring meeting (an ad hoc group call is a call).
local function attended_meetings(data)
  local my_id = data and data.me
  local by_chat = {}
  for _, c in ipairs(data and data.chats or {}) do
    by_chat[c.id] = c
  end
  local function joined(people)
    for _, w in ipairs(people or {}) do
      if type(w) == 'table' and w.u == my_id then
        return true
      end
    end
    return false
  end
  local list, seen = {}, {}
  local function add(id, chat_id, stop, secs, people)
    if id and not seen[id] and stop and (secs or 0) > 0 and joined(people) then
      seen[id] = true
      table.insert(list, { id = id, chat = chat_id, start = stop - secs, stop = stop, secs = secs, n = #people })
    end
  end
  for id, k in pairs((read_json(LOCAL_CALLS) or {}).meetings or {}) do
    if (by_chat[k.chat] or {}).chatType == 'meeting' or k.type == 'Scheduled' or k.type == 'Recurring' then
      add(id, k.chat, epoch(k['end']), k.secs, k.people)
    end
  end
  for chat_id, entry in pairs(read_json(INDEX) or {}) do
    for _, k in ipairs(type(entry) == 'table' and entry.calls or {}) do
      if k.kind == 'meeting' or (by_chat[chat_id] or {}).chatType == 'meeting' then
        add(k.id, chat_id, epoch(k.at), k.secs, k.with)
      end
    end
  end
  table.sort(list, function(a, b)
    return a.start > b.start
  end)
  return list
end

--- Fetches the topics of chats not in the list (in $batch requests of 20) into TITLES; each is asked once ('' for one
--- Graph refuses or that has no topic).
local function fetch_titles(ids)
  local titles = read_json(TITLES) or {}
  local todo = vim.tbl_filter(function(id)
    return titles[id] == nil
  end, ids)
  for i = 1, #todo, 20 do
    local group = vim.list_slice(todo, i, i + 19)
    local requests = {}
    for j, id in ipairs(group) do
      table.insert(requests, { id = tostring(j), method = 'GET', url = '/chats/' .. id .. '?$select=topic' })
    end
    local reply = api('POST', '/$batch', { requests = requests })
    for _, r in ipairs(reply and reply.responses or {}) do
      local id = group[tonumber(r.id)]
      if id and r.status == 200 then
        titles[id] = (r.body or {}).topic or ''
      elseif id and (r.status == 403 or r.status == 404) then
        titles[id] = ''
      end
    end
  end
  if #todo > 0 then
    write_json(TITLES, titles)
  end
  return titles
end

--- A meeting's title: its chat's name, else its fetched topic.
local function meeting_title(chat_id, chat, my_id, titles)
  if chat then
    return chat_name(chat, my_id)
  end
  local t = titles and titles[chat_id]
  return t and t ~= '' and t or '(untitled meeting)'
end

local function iso_utc(t)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(t))
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
            call = call_info(p.eventDetail),
          } or nil,
          -- members are kept from the last fetch while the chat itself has not changed
          members = prior and prior.updated == c.lastUpdatedDateTime and prior.members or nil,
        })
      end
    end
    url = page['@odata.nextLink']
  end

  -- the self chat and the call log, each placed by its last message among the others (newest activity first)
  for _, pseudo in ipairs(PSEUDO) do
    local newest = api('GET', '/chats/' .. pseudo.id .. '/messages?$top=1')
    local top = newest and newest.value and newest.value[1]
    if top then
      local m = trim_message(top)
      local chat = vim.tbl_extend('force', pseudo, {
        updated = m.at,
        members = {},
        preview = { id = m.id, at = m.at, from = m.from, fromId = m.fromId, text = one_line(m.text), event = m.type ~= 'message' or nil, call = m.call },
      })
      local at, pos = epoch(m.at) or 0, #chats + 1
      for i, c in ipairs(chats) do
        if (epoch(c.preview and c.preview.at or c.updated) or 0) < at then
          pos = i
          break
        end
      end
      table.insert(chats, pos, chat)
      seen_ids[pseudo.id] = true
    end
  end

  -- chats beyond the newest MAX_CHATS stay, as they were last seen, so their messages remain searchable (a hidden
  -- chat was seen in the pages and stays out)
  for _, c in ipairs(chats) do
    seen_ids[c.id] = true
  end
  for _, c in ipairs(old.chats or {}) do
    if not seen_ids[c.id] and c.id ~= MEETINGS then
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
    local entry = index[c.id] or {}
    return c.preview and c.preview.id and (entry.newest ~= c.preview.id or entry.calls == nil)
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

  -- the desktop app's call log: read once, then again when Graph's log has a call it lacks (at most every 5 minutes,
  -- as the app may not have it yet, or not be running)
  local newest_call
  for _, c in ipairs(chats) do
    if c.id == CALL_LOG then
      newest_call = vim.tbl_get(c, 'preview', 'call', 'id')
    end
  end
  local held = read_json(LOCAL_CALLS)
  if not held or (newest_call and not (held.calls or {})[newest_call] and os.time() - (held.at or 0) > 300) then
    sync_local_calls()
  end

  -- the meetings attended, placed by the newest one's end among the chats; the titles of their chats not in the list
  local attended = attended_meetings(data)
  local listed, unlisted, asked = {}, {}, {}
  for _, c in ipairs(chats) do
    listed[c.id] = true
  end
  for _, rec in ipairs(attended) do
    if rec.chat and not listed[rec.chat] and not asked[rec.chat] then
      asked[rec.chat] = true
      table.insert(unlisted, rec.chat)
    end
  end
  if #unlisted > 0 then
    fetch_titles(unlisted)
  end
  local newest = attended[1]
  if newest then
    local at = iso_utc(newest.stop)
    local pos = #chats + 1
    for i, c in ipairs(chats) do
      if (epoch(c.preview and c.preview.at or c.updated) or 0) < newest.stop then
        pos = i
        break
      end
    end
    table.insert(chats, pos, {
      id = MEETINGS,
      topic = 'Meetings attended',
      chatType = 'attended',
      webUrl = 'https://teams.microsoft.com/l/app/ef56c0de-36fc-4ef8-b417-3d82ba9d073c', -- the Calendar app
      updated = at,
      members = {},
      preview = { id = newest.id, at = at, event = true, meeting = { chat = newest.chat, secs = newest.secs } },
    })
    write_json(CHATS, data)
  end
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
    elseif key == 'from' then
      p.from = { value:lower(), negated }
    elseif key == 'type' then
      p.type = TYPES[value:lower()] or value
      p.type_negated = negated
    elseif key == 'is' and value == 'unread' then
      p.unread = not negated
    elseif key == 'has' and (value == 'call' or value == 'calls') then
      p.call = not negated
    elseif key == 'since' then
      p.since = since(value)
    elseif key == 'on' then
      p.on = day_range(value)
    else
      body = body:gsub('^"(.*)"$', '%1'):lower()
      if body ~= '' then
        table.insert(negated and p.without or p.words, body)
      end
    end
  end
  return p
end

--- Whether message `m` (of the index or a chat's cache) was sent by `who` of `from:`: `me`/`you`, else a part of a name.
local function sent_by(m, who, my_id)
  if who == 'me' or who == 'you' then
    return my_id ~= nil and m.fromId == my_id
  end
  return (m.from or ''):lower():find(who, 1, true) ~= nil
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
  -- `has:call`: the chat's ended calls (of the days of `on:`, when given); the row shows the newest and the total
  local call_hit
  if p.call ~= nil then
    local calls, total, unknown = {}, 0, false
    for _, k in ipairs(index and index[c.id] and index[c.id].calls or {}) do
      local t = epoch(k.at)
      if not p.on or (t and t >= p.on[1] and t < p.on[2]) then
        table.insert(calls, k)
        total = total + (k.secs or 0)
        unknown = unknown or k.secs == nil
      end
    end
    if (#calls > 0) ~= p.call then
      return false
    end
    if p.call then
      local newest = calls[1]
      call_hit = {
        at = newest.at,
        line = ('%s call %s%s'):format(
          short_time(newest.at),
          fmt_duration(newest.secs),
          #calls > 1 and (' · %d calls, %s%s in all'):format(#calls, unknown and '≥' or '', fmt_duration(total)) or ''
        ),
      }
    end
  end
  -- `on:`: the chat's messages of those days (from the index); its last activity bounds them. With `has:call` the
  -- days apply to the calls instead.
  local day_msgs
  if p.on and not p.call then
    if (epoch(c.preview and c.preview.at or c.updated) or 0) < p.on[1] then
      return false
    end
    day_msgs = {}
    for _, m in ipairs(index and index[c.id] and index[c.id].messages or {}) do
      local t = epoch(m.at)
      if t and t >= p.on[1] and t < p.on[2] then
        table.insert(day_msgs, m)
      end
    end
    if #day_msgs == 0 then
      return false
    end
  end
  -- `from:`: the messages (of `on:`'s days, else all indexed ones) sent by someone; the chat needs one of them, and
  -- the row shows the newest (words, when given, must be in them). `-from:` needs messages but none of theirs.
  if p.from then
    local theirs, others = {}, {}
    for _, m in ipairs(day_msgs or index and index[c.id] and index[c.id].messages or {}) do
      table.insert(sent_by(m, p.from[1], my_id) and theirs or others, m)
    end
    if p.from[2] then
      if #theirs > 0 or #others == 0 then
        return false
      end
      day_msgs = others
    else
      if #theirs == 0 then
        return false
      end
      day_msgs = theirs
    end
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
    return true, call_hit or (day_msgs and day_msgs[1]) -- with `on:`, the row shows the newest message of those days
  end
  local found, best, best_n = {}, nil, 0
  for _, m in ipairs(day_msgs or index and index[c.id] and index[c.id].messages or {}) do
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
  -- colours and links (OSC 8, whose URL a word must not be marked in) are left as they are
  local function next_escape()
    local s1, e1 = line:find('\27%[[%d;]*m', pos)
    local s2, e2 = line:find('\27%]8;[^\27]*\27\\', pos)
    if s2 and (not s1 or s2 < s1) then
      return s2, e2
    end
    return s1, e1
  end
  for s, e in next_escape do
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

--- When the cache was last updated: its clock time (with the day when not today) and how long ago.
local function age(at)
  at = at or 0
  local secs = os.time() - at
  local clock = os.date('%Y-%m-%d', at) == os.date '%Y-%m-%d' and os.date('%H:%M', at) or os.date('%b %d %H:%M', at)
  local ago
  if secs < 90 then
    ago = 'just now'
  elseif secs < 3600 then
    ago = math.floor(secs / 60) .. 'm ago'
  elseif secs < 86400 then
    ago = math.floor(secs / 3600) .. 'h ago'
  else
    ago = math.floor(secs / 86400) .. 'd ago'
  end
  return ('updated %s, %s'):format(clock, ago)
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
  local index = (#p.words > 0 or p.on or p.from or p.call ~= nil) and read_json(INDEX) or nil
  if p.call ~= nil and index then
    -- the desktop app's answered calls join the chats' own call events (the same call has the same id in both)
    local extra = {}
    for _, rec in ipairs((desktop_calls(data))) do
      if rec.chat and rec.secs then
        extra[rec.chat] = extra[rec.chat] or {}
        table.insert(extra[rec.chat], { id = rec.id, at = rec.ended, secs = rec.secs, with = rec.with })
      end
    end
    for chat_id, calls in pairs(extra) do
      local entry = index[chat_id] or {}
      local have, merged = {}, {}
      for _, k in ipairs(entry.calls or {}) do
        have[k.id or ''] = true
        table.insert(merged, k)
      end
      for _, k in ipairs(calls) do
        if not have[k.id] then
          table.insert(merged, k)
        end
      end
      table.sort(merged, by_time_desc)
      index[chat_id] = vim.tbl_extend('force', entry, { calls = merged })
    end
  end
  local found, hits = {}, {}
  local remote = server_hits(p.words)
  local loose = remote and vim.tbl_extend('force', p, { words = {} }) -- the query's other filters still apply
  local listed = {}
  for _, c in ipairs(data.chats) do
    listed[c.id] = true
    local ok, hit = matches(c, p, my_id, index)
    if not ok and remote and remote[c.id] and matches(c, loose, my_id, index) then
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
      ('\t\27[2m%d chats, %d unread (cache %s%s). Filter: words with: from:me type:1:1|group|meeting|calls|attended is:unread has:call since:7d on:11-05   enter: open chat  ctrl-r: refresh\27[0m\t\t'):format(
        #data.chats,
        unread_count,
        age(data.at),
        data.refreshing and ', refreshing' or ''
      )
    )
  else
    -- with a query too, a line on top says how fresh the cache searched is
    out(
      ('\t\27[%sm%s\27[0m\27[2m  (cache %s%s)\27[0m\t\t'):format(
        #found == 0 and '33' or '2',
        #found == 0 and 'No chats match' or (#found .. ' of ' .. #data.chats .. ' chats match'),
        age(data.at),
        data.refreshing and ', refreshing' or ''
      )
    )
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
    if c.id == CALL_LOG then
      local newest = (desktop_calls(data))[1]
      if newest then
        local names = vim.tbl_map(function(w)
          return w.n or '?'
        end, vim.list_slice(newest.with, 1, 2))
        last = ('\27[2m(%s %s %s %s)\27[0m'):format(
          short_time(newest.at),
          CALL_ARROW[newest.dir] or '',
          table.concat(names, '; ') .. (#newest.with > 2 and (' +' .. (#newest.with - 2)) or ''),
          newest.secs and fmt_duration(newest.secs) or 'missed'
        )
      else
        last = '\27[2m(last call ended ' .. short_time(pv.at) .. ')\27[0m'
      end
    elseif c.id == MEETINGS and pv.meeting then
      local m_chat = find(pv.meeting.chat)
      local title = meeting_title(pv.meeting.chat, m_chat, my_id, not m_chat and read_json(TITLES) or nil)
      last = ('\27[2m(%s %s)\27[0m'):format(clean(title), fmt_duration(pv.meeting.secs))
    elseif pv.call then
      last = '\27[2m(' .. (pv.call.started and 'call started' or ('call ' .. fmt_duration(pv.call.secs))) .. ')\27[0m'
    end
    local hit = hits[c.id]
    if hit and hit.line then
      last = '\27[2m↳ ' .. hit.line .. '\27[0m'
    elseif hit then
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
  -- paging stops at a page that reaches the cache (the older messages are there already) or at FETCH_MAX, so a
  -- large count (the chat buffer's whole history) costs a page or two, not the chat's whole history from Graph
  local known = {}
  for _, m in ipairs(cached and cached.messages or {}) do
    known[m.id] = true
  end
  local list, url = {}, '/chats/' .. chat.id .. '/messages?$top=50'
  local complete = false
  while url and #list < math.min(count, FETCH_MAX) do
    local page, err = api('GET', url)
    if not page then
      return nil, err
    end
    local overlaps = false
    for _, m in ipairs(page.value or {}) do
      table.insert(list, trim_message(m))
      overlaps = overlaps or known[m.id] == true
    end
    url = page['@odata.nextLink']
    complete = url == nil
    if overlaps then
      break
    end
  end
  table.sort(list, by_time_desc)
  -- keyed by the newest message actually fetched: while the chat list is behind (its preview older than that), the
  -- keys differ and the chat is fetched again on each show, until a refresh catches the list up
  local merged = store_messages(chat.id, list, complete)
  -- a newer message than the chat list knows of: bring the list's preview (and unread state) up to date with it
  local top = list[1]
  if top and top.id ~= newest then
    local data = read_json(CHATS)
    for _, c in ipairs(data and data.chats or {}) do
      if c.id == chat.id then
        c.preview =
          { id = top.id, at = top.at, from = top.from, fromId = top.fromId, text = one_line(top.text), event = top.type ~= 'message' or nil, call = top.call }
        write_json(CHATS, data)
        break
      end
    end
  end
  -- the fetched messages and the older ones of the cache behind them
  return vim.list_slice(merged, 1, count)
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

-- -- images -------------------------------------------------------------------------------------------------------

-- `show --images` draws the images pasted into messages in the preview, where the text says [image]. They are fetched
-- from Graph once into the cache (keyed by URL) and drawn by chafa as coloured block characters, which fzf shows
-- anywhere, Neovim's :terminal (fzf-lua's picker) included. In fzf straight in kitty or Ghostty (the shell's `lq`), the
-- kitty protocol's unicode placeholders show real pixels that scroll with the text, through tmux too (with
-- allow-passthrough). LIVEQ_TEAMS_IMAGE_FORMAT forces one: symbols, kitty, sixels or iterm (the last two need a
-- terminal and an fzf that pass them, never Neovim's). Real images fill the preview's height; LIVEQ_TEAMS_IMAGE_ROWS
-- caps the block art's (16 lines), LIVEQ_TEAMS_IMAGE_MAX the images drawn per preview (12, the newest), the rest
-- staying [image].
local IMAGES = CACHE .. '/images'
local IMAGE_ROWS = tonumber(os.getenv 'LIVEQ_TEAMS_IMAGE_ROWS') or 16
local IMAGE_MAX = tonumber(os.getenv 'LIVEQ_TEAMS_IMAGE_MAX') or 12
local IMAGE_LINE = '\6' -- starts each line of a drawn image: never highlighted, dropped on output
-- liveq's picker in Neovim draws the real images over the block art (liveq/images.lua): it names a file for where they
-- are, and the shape of a cell, so the art has the image's shape and fills the preview's height (as the image will)
local OVERLAY = os.getenv 'LIVEQ_IMAGE_FILE'
OVERLAY = OVERLAY ~= '' and OVERLAY or nil
local FONT_RATIO = os.getenv 'LIVEQ_FONT_RATIO'

local Img = dofile(vim.fs.dirname(SCRIPT) .. '/images.lua') -- drawing, copying and opening, shared with notmuch.lua
local image_format = Img.format

--- Downloads the images not cached yet (in parallel); sets `file` on each one there.
local function fetch_images(images)
  local jobs = {}
  for _, img in ipairs(images) do
    img.file = IMAGES .. '/' .. vim.fn.sha256(img.url):sub(1, 32)
    if not vim.uv.fs_stat(img.file) then
      if not token() then
        img.file = nil
      else
        vim.fn.mkdir(IMAGES, 'p')
        local part = img.file .. '.' .. vim.uv.os_getpid() .. '.part'
        local cmd = { 'curl', '-sSf', '--max-time', '30', '-H', '@' .. HEADER_FILE, '-o', part, img.url }
        table.insert(jobs, { img = img, part = part, job = vim.system(cmd) })
      end
    end
  end
  for _, j in ipairs(jobs) do
    if j.job:wait(35000).code == 0 then
      os.rename(j.part, j.img.file)
    else
      os.remove(j.part)
      j.img.file = nil
    end
  end
end

--- Draws `images` (from messages' `images`) `width` columns wide at most; sets `lines` on each one drawn.
local function draw_images(images, width, format)
  format = format or (OVERLAY and vim.fn.executable 'chafa' == 1 and 'symbols') or image_format()
  if not format or #images == 0 then
    return
  end
  fetch_images(images)
  local jobs = {}
  for _, img in ipairs(images) do
    if img.file and not img.lines then
      -- block art about as wide as Teams shows it (a cell is some 8 pixels wide), within the preview; a real image
      -- (kitty's, or the picker's over the art) as large as the preview allows, so its text can be read
      local cols, rows = width, IMAGE_ROWS
      if OVERLAY or format == 'kitty' or img.big then
        rows = math.max(IMAGE_ROWS, (tonumber(os.getenv 'FZF_PREVIEW_LINES') or 30) - (img.big and 3 or 2))
      elseif img.w and img.w > 0 then
        cols = math.max(8, math.min(width, math.ceil(img.w / 8)))
      end
      local job = Img.start(img.file, cols, rows, format, FONT_RATIO)
      if job then
        table.insert(jobs, { img = img, job = job })
      end
    end
  end
  for _, j in ipairs(jobs) do
    local lines = Img.finish(j.job, format)
    if lines then
      -- the box the art fills, which the real image is drawn into (chafa's art is a character per cell)
      j.img.rows = #lines
      j.img.cols = vim.fn.strdisplaywidth((lines[1]:gsub('\27%[[%d;]*m', '')))
      for i, line in ipairs(lines) do
        lines[i] = IMAGE_LINE .. line .. '\27[0m'
      end
      j.img.lines = lines
    end
  end
  -- kitten fails where it finds no terminal to ask the size of a cell: block art instead
  if format == 'kitty' and #jobs > 0 and not jobs[1].img.lines and vim.fn.executable 'chafa' == 1 then
    draw_images(images, width, 'symbols')
  end
end

local as_png, link_file = Img.as_png, Img.link_file

--- The text of message `m` with each [image] that has a drawing replaced by it (on lines of their own); for the
--- picker's real images, below a caption `[image K/N]` that tells it where image K is. One that is not drawn but has a
--- file is a link to it (OSC 8), which a click opens in kitty (with ctrl+shift while fzf has the mouse).
local function with_images(text, m, total)
  local i = 0
  return (
    text
      :gsub('%[image%]', function(word)
        i = i + 1
        local img = m.images and m.images[i]
        if img and not img.lines and img.link then
          return '\27]8;;' .. img.link .. '\27\\\27[4m' .. word .. '\27[24m\27]8;;\27\\'
        end
        if img and img.lines then
          local caption = OVERLAY and img.n and (IMAGE_LINE .. ('\27[2m[image %d/%d]\27[0m'):format(img.n, total) .. '\n') or ''
          return '\n' .. caption .. table.concat(img.lines, '\n') .. '\n'
        end
      end)
      :gsub('^\n+', '')
      :gsub('\n+$', '')
  )
end

--- Whether the newest of `list` were cached before images were kept (their pasted images then read "image"): fetching
--- them again (merged into the cache) gives them their images.
local function lacks_images(list)
  for i = 1, math.min(#list, 50) do
    local m = list[i]
    if m.type == 'message' and not m.images and (m.text or ''):lower():find('image', 1, true) then
      return true
    end
  end
  return false
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
  local q = opts.match and plan(opts.match) or {}
  local words, on, from = q.words or {}, q.on, q.from
  local searching = #words > 0 or on ~= nil or from ~= nil
  local want = tonumber(opts.count) or (searching and 100000) or (chat.id == CALL_LOG and 300) or (plain and 100) or 30
  -- the call log's older entries come from the desktop app's cache, when there is one, so Graph's newest 50 do
  local list, err, all_meetings
  if chat.id == MEETINGS then
    all_meetings, list = attended_meetings(data), {}
    for _, rec in ipairs(all_meetings) do
      table.insert(list, { id = rec.id, type = 'meeting', at = iso_utc(rec.start), rec = rec })
    end
    list = vim.list_slice(list, 1, tonumber(opts.count) or (searching and 100000) or 300)
  else
    list, err = messages(chat, chat.id == CALL_LOG and math.min(want, 50) or want, opts.fresh, searching)
    if opts.images and not plain and not opts.fresh and list and lacks_images(list) then
      messages(chat, 50, true)
      list, err = messages(chat, chat.id == CALL_LOG and math.min(want, 50) or want, false, searching)
    end
  end
  if not list then
    out((plain and '' or '\27[31m') .. 'Cannot fetch the messages: ' .. err .. (plain and '' or '\27[0m'))
    return
  end
  if not list then
    out((plain and '' or '\27[31m') .. 'Cannot fetch the messages: ' .. err .. (plain and '' or '\27[0m'))
    return
  end
  local desktop, desktop_by_id, all_calls = {}, {}, nil
  if chat.chatType ~= 'self' and chat.id ~= MEETINGS then
    desktop, desktop_by_id = desktop_calls(data)
  end
  if chat.id == CALL_LOG and #desktop > 0 then
    -- every call the app holds, and those of Graph's log it does not
    local merged = {}
    for _, rec in ipairs(desktop) do
      table.insert(merged, { id = rec.id, type = 'calllog', at = rec.at, call = { id = rec.id }, rec = rec })
    end
    for _, m in ipairs(list) do
      if not (m.call and desktop_by_id[m.call.id]) then
        table.insert(merged, m)
      end
    end
    table.sort(merged, by_time_desc)
    all_calls = merged -- a day's total counts all its calls, not just those shown
    list = vim.list_slice(merged, 1, want)
  elseif #desktop > 0 then
    -- the chat's calls the app logged but the chat has no event for (a call from the Calls app), within the messages
    local present, added = {}, false
    for _, m in ipairs(list) do
      if m.call and m.call.id then
        present[m.call.id] = true
      end
    end
    local oldest = #list > 0 and epoch(list[#list].at) or 0
    for _, rec in ipairs(desktop) do
      if rec.chat == chat.id and not present[rec.id] and (epoch(rec.ended) or 0) >= oldest then
        table.insert(list, {
          id = 'call:' .. rec.id,
          type = 'event',
          event = '#microsoft.graph.callEndedEventMessageDetail',
          at = rec.ended,
          call = { id = rec.id, secs = rec.secs, with = rec.with, missed = rec.secs == nil },
        })
        added = true
      end
    end
    if added then
      table.sort(list, by_time_desc)
    end
  end
  local draw = opts.images and not plain
  -- the preview's [image] are links to the cached files (downloaded now, the newest IMAGE_MAX), unless drawn
  local links = not plain and os.getenv 'LIVEQ_TEAMS_IMAGE_LINKS' ~= '0'
  -- plain with --images: each [image] names its cached file instead
  local paths = plain and opts.images
  local drawn = 0 -- images with a caption, for the picker's real ones
  if draw or links or paths then
    local images = {}
    for _, m in ipairs(list) do
      for _, img in ipairs(m.type == 'message' and not m.deleted and m.images or {}) do
        if #images < IMAGE_MAX then
          table.insert(images, img)
        end
      end
    end
    local width = tonumber(os.getenv 'FZF_PREVIEW_COLUMNS') or tonumber(os.getenv 'LIVEQ_WIDTH') or 80
    if draw then
      draw_images(images, math.max(8, width - 1))
    else
      fetch_images(images)
    end
    local host = vim.uv.os_gethostname() or ''
    for _, img in ipairs(images) do
      local file = img.file and not img.lines and link_file(img.file)
      if file then
        img.link = 'file://' .. host .. file:gsub('[^%w/._~-]', function(c)
          return ('%%%02X'):format(c:byte())
        end)
      end
    end
    if draw and OVERLAY then
      -- written before any output, so that the picker never pairs a caption with the previous preview's file
      local rows, n = {}, 0
      for _, img in ipairs(images) do
        if img.lines then
          n = n + 1
          img.n = n
          table.insert(rows, ('%d\t%d\t%d\t%s'):format(n, img.cols, img.rows, img.file))
        end
      end
      drawn = n
      local f = io.open(OVERLAY, 'w')
      if f then
        f:write(table.concat(rows, '\n'), '\n')
        f:close()
      end
    end
  end
  if opts.chronological then
    list = vim.fn.reverse(list)
  end
  local lines = {}
  local in_range = {} -- with `on:`, the entries of `lines` that belong to a message of those days
  local name = chat_name(chat, my_id)
  -- the call log: each call joined by its id to the chat event that has its duration and people
  local known, day_of, chat_by_id, day_totals = {}, nil, {}, {}
  local titles
  if chat.id == MEETINGS then
    titles = read_json(TITLES) or {}
    for _, c in ipairs(data.chats or {}) do
      chat_by_id[c.id] = c
    end
    -- per day: the meetings, the time they covered (overlaps once) and the time on answered calls
    local spans = {}
    for _, rec in ipairs(all_meetings) do
      local day = os.date('%a %b %d', rec.start)
      local d = day_totals[day] or { n = 0, secs = 0, calls = 0 }
      d.n = d.n + 1
      day_totals[day] = d
      spans[day] = spans[day] or {}
      table.insert(spans[day], { rec.start, rec.stop })
    end
    for day, list_of in pairs(spans) do
      table.sort(list_of, function(a, b)
        return a[1] < b[1]
      end)
      local total, s0, e0 = 0, nil, nil
      for _, span in ipairs(list_of) do
        if e0 and span[1] <= e0 then
          e0 = math.max(e0, span[2])
        else
          total = total + (e0 and (e0 - s0) or 0)
          s0, e0 = span[1], span[2]
        end
      end
      day_totals[day].secs = total + (e0 and (e0 - s0) or 0)
    end
    for _, rec in ipairs((desktop_calls(data))) do
      local t = epoch(rec.at)
      local d = t and day_totals[os.date('%a %b %d', t)]
      if d and rec.secs then
        d.calls = d.calls + rec.secs
      end
    end
  elseif chat.id == CALL_LOG then
    for _, c in ipairs(data.chats or {}) do
      chat_by_id[c.id] = c
    end
    for chat_id, entry in pairs(read_json(INDEX) or {}) do
      for _, k in ipairs(type(entry) == 'table' and entry.calls or {}) do
        if k.id then
          known[k.id] = vim.tbl_extend('force', k, { chat = chat_id })
        end
      end
    end
    -- per day: the calls and the time on them (answered calls of known duration)
    for _, m in ipairs(all_calls or list) do
      local t = epoch(m.at)
      local day = t and os.date('%a %b %d', t) or ''
      local k = m.rec or known[m.call and m.call.id or '']
      local d = day_totals[day] or { n = 0, secs = 0 }
      d.n = d.n + 1
      d.secs = d.secs + (k and k.secs or 0)
      day_totals[day] = d
    end
  end
  --- The people of a call other than you, else the chat's name.
  local function call_people(with, c)
    local names = {}
    for _, w in ipairs(with or {}) do
      if w.u ~= my_id and w.n and w.n ~= '' then
        table.insert(names, w.n)
      end
    end
    if #names == 0 then
      return c and chat_name(c, my_id) or ''
    end
    return table.concat(vim.list_slice(names, 1, 3), '; ') .. (#names > 3 and (' +' .. (#names - 3)) or '')
  end
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
  if chat.id == MEETINGS then
    local note =
      "Meetings you joined, by start time, and how long each ran. Teams keeps no join or leave times, so it is the meeting's length (an upper bound); a day's total counts overlapping meetings once."
    vim.list_extend(lines, { plain and ('_' .. note .. '_') or ('\27[2m' .. note .. '\27[0m'), '' })
  end
  if chat.id == CALL_LOG then
    local note = #desktop > 0
        and "When each call started, → outgoing, ← incoming, and how long it lasted: from the Teams app's cache on this Mac. A day's total counts answered calls."
      or 'When each call ended. Duration and people only for calls that also posted to a chat; Graph gives the rest no detail.'
    vim.list_extend(lines, { plain and ('_' .. note .. '_') or ('\27[2m' .. note .. '\27[0m'), '' })
  end
  -- the Loop files linked in the messages shown (the newest 100 of a search's), named from Graph
  local loops = loop_info(vim.list_slice(loop_urls(list), 1, 100))
  for _, m in ipairs(list) do
    local who = m.fromId == my_id and 'You' or (m.from or '?')
    local t = (on or from) and epoch(m.at)
    local first = #lines + 1
    if m.type == 'meeting' then
      local rec = m.rec
      local day = os.date('%a %b %d', rec.start)
      if day ~= day_of then
        if day_of then
          table.insert(lines, '')
        end
        day_of = day
        local d = day_totals[day] or { n = 0, secs = 0, calls = 0 }
        local sum = (' · %d meeting%s · %s'):format(d.n, d.n == 1 and '' or 's', fmt_duration(d.secs))
          .. (d.calls > 0 and (' · calls ' .. fmt_duration(d.calls)) or '')
        table.insert(lines, plain and ('## ' .. day .. sum) or ('\27[1m' .. day .. '\27[0m\27[2m' .. sum .. '\27[0m'))
      end
      local title = meeting_title(rec.chat, chat_by_id[rec.chat], my_id, titles)
      local time, dur, people = os.date('%H:%M', rec.start), fmt_duration(rec.secs), ('%d people'):format(rec.n)
      table.insert(
        lines,
        plain and ('- %s · %s · %s · %s'):format(time, dur, title, people) or ('  %s  %-8s %s  \27[2m%s\27[0m'):format(time, dur, title, people)
      )
    elseif m.type == 'calllog' then
      local et = epoch(m.at)
      local day = et and os.date('%a %b %d', et) or ''
      if day ~= day_of then
        if day_of then
          table.insert(lines, '')
        end
        day_of = day
        local d = day_totals[day] or { n = 0, secs = 0 }
        local sum = (' · %d call%s · %s'):format(d.n, d.n == 1 and '' or 's', fmt_duration(d.secs))
        table.insert(lines, plain and ('## ' .. day .. sum) or ('\27[1m' .. day .. '\27[0m\27[2m' .. sum .. '\27[0m'))
      end
      local k = m.rec or known[m.call and m.call.id or '']
      local time = et and os.date('%H:%M', et) or ''
      if k then
        local who = call_people(k.with, chat_by_id[k.chat])
        local missed = k.state == 'missed'
        local dur = missed and 'missed' or fmt_duration(k.secs)
        local arrow = CALL_ARROW[k.dir] or ' '
        table.insert(
          lines,
          plain and ('- %s %s %s · %s'):format(time, arrow, dur, who) or ('  %s %s %s%-8s\27[0m %s'):format(time, arrow, missed and '\27[31m' or '', dur, who)
        )
      else
        table.insert(lines, plain and ('- %s · ?'):format(time) or ('  %s  \27[2m?\27[0m'):format(time))
      end
    elseif m.type ~= 'message' and m.call and not m.call.started then
      local who = call_people(m.call.with)
      local rec = desktop_by_id[m.call.id]
      local dir = rec and ({ incoming = ' ←', outgoing = ' →' })[rec.dir] or ''
      local what = (m.call.missed and 'missed call' or ('call · ' .. fmt_duration(m.call.secs)))
        .. dir
        .. (chat.chatType ~= 'oneOnOne' and who ~= '' and (' · ' .. who) or '')
      table.insert(
        lines,
        plain and ('_— ' .. what .. ' · ' .. long_time(m.at) .. ' —_') or ('\27[36m— ' .. what .. ' · ' .. long_time(m.at) .. ' —\27[0m')
      )
      table.insert(lines, '')
    elseif m.type ~= 'message' and m.call then
      local what = 'call started' .. (m.call.by == my_id and ' by you' or '')
      table.insert(
        lines,
        plain and ('_— ' .. what .. ' · ' .. long_time(m.at) .. ' —_') or ('\27[2m— ' .. what .. ' · ' .. long_time(m.at) .. ' —\27[0m')
      )
      table.insert(lines, '')
    elseif m.type ~= 'message' then
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
      local text = describe_loops(m.text, loops, plain)
      if paths then
        local i = 0
        text = text:gsub('%[image%]', function(word)
          i = i + 1
          local img = m.images and m.images[i]
          -- as a .png, so that a reader going by the extension (Claude Code's Read) takes it for an image
          local file = img and img.file and (link_file(img.file) or img.file)
          return file and ('[image: ' .. file .. ']') or word
        end)
      end
      table.insert(lines, render_quotes((draw or links) and with_images(text, m, drawn) or text, plain))
      table.insert(lines, '')
    end
    -- the message counts for `on:` and `from:` (the preview jumps to those of the day, or of the sender)
    if t and (not on or (t >= on[1] and t < on[2])) and (not from or (m.type == 'message' and sent_by(m, from[1], my_id) ~= from[2])) then
      for i = first, #lines do
        in_range[i] = i == first and 'head' or true
      end
    end
  end
  if not searching then
    out((table.concat(lines, '\n'):gsub(IMAGE_LINE, '')))
    return
  end
  -- highlight the words, and tell liveq's picker the lines that have them, so the preview scrolls to the first; with
  -- `on:`, only those in the messages of its days count, and when none has the words (they matched the chat's name or
  -- members), the first line of each of those messages
  -- The first match shown is in the message with the most of the words (the newest of those, as the picker's row
  -- shows), not the first line with any one of them: a common word like `run` is in many messages.
  local numbers, heads, n = {}, {}, 0
  local start, best = 1, 0
  for i, entry in ipairs(lines) do
    local score
    for j, line in ipairs(vim.split(entry, '\n', { plain = true })) do
      n = n + 1
      local marked, hit
      if line:sub(1, 1) == IMAGE_LINE then
        marked, line = line:sub(2), line:sub(2) -- a drawn image: its escapes and data are not text to highlight
      else
        marked, hit = highlight(line, words)
      end
      if n > 1 and hit and (not (on or from) or in_range[i]) then
        table.insert(numbers, n)
        if not score then
          local text = entry:gsub(IMAGE_LINE .. '[^\n]*', ''):gsub('\27%[[%d;]*m', ''):lower()
          score = 0
          for _, w in ipairs(words) do
            score = score + (text:find(w, 1, true) and 1 or 0)
          end
          if score > best or (score == best and opts.chronological) then
            start, best = #numbers, score
          end
        end
      end
      if in_range[i] == 'head' and j == 1 then
        table.insert(heads, n)
      end
      io.stdout:write(plain and line or marked, '\n') -- a buffer highlights with the search register, not escapes
    end
  end
  if (on or from) and #numbers == 0 then
    numbers, start = heads, 1
  end
  io.stdout:flush()
  local file = os.getenv 'LIVEQ_MATCH_FILE'
  if file and file ~= '' then
    local f = io.open(file, 'w')
    if f then
      f:write(id, '\n', #numbers > 0 and start or 0, '\n', table.concat(numbers, ' '), '\n')
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

-- -- Markdown -> Teams HTML (for send) -----------------------------------------------------------------------------

--- The @mentions a message can make: a list of { form, name, id } for the chat's members other than me, longest form
--- first. Each member is matched by the full display name ("Varghese, Christo"), and by the first or last name alone
--- when no other member shares it.
local function mention_forms(members, my_id)
  local forms, count = {}, {}
  local function short(m)
    local last, first = (m.n or ''):match '^([^,]+),%s*(%S+)'
    return { first, last }
  end
  for _, m in ipairs(members or {}) do
    if m.u and m.u ~= my_id and m.n and m.n ~= '' then
      for _, s in ipairs(short(m)) do
        count[s:lower()] = (count[s:lower()] or 0) + 1
      end
    end
  end
  for _, m in ipairs(members or {}) do
    if m.u and m.u ~= my_id and m.n and m.n ~= '' then
      table.insert(forms, { form = m.n:lower(), name = m.n, id = m.u })
      for _, s in ipairs(short(m)) do
        if count[s:lower()] == 1 and s:lower() ~= m.n:lower() then
          table.insert(forms, { form = s:lower(), name = m.n, id = m.u })
        end
      end
    end
  end
  table.sort(forms, function(a, b)
    return #a.form > #b.form
  end)
  return forms
end

--- Renders one line of Markdown text as Teams HTML: `code`, [text](url), bare URLs, **bold**, *italic*, and @mentions
--- of the chat's members (`forms`), which are added to `mentions` as Graph wants them (`<at id="N">` in the body).
local function inline_html(s, forms, mentions, unknown)
  local keep = {}
  local function hold(html)
    table.insert(keep, html)
    return '\1' .. #keep .. '\2'
  end
  local function text(t)
    t = t:gsub('%[([^%]]+)%]%((https?://[^)%s]+)%)', function(label, url)
      return hold(('<a href="%s">%s</a>'):format(html_escape(url), html_escape(label)))
    end)
    t = t:gsub('https?://[^%s<>\1\2]+', function(url)
      local tail = url:match '[.,;:!?)]+$' or ''
      url = url:sub(1, #url - #tail)
      return hold(('<a href="%s">%s</a>'):format(html_escape(url), html_escape(url))) .. tail
    end)
    -- @mentions: an @ not preceded by a letter or digit (so not an address), then a member's name
    local out, i = {}, 1
    while true do
      local at = t:find('@', i, true)
      if not at then
        table.insert(out, t:sub(i))
        break
      end
      table.insert(out, t:sub(i, at - 1))
      local found
      if not t:sub(at - 1, at - 1):match '%w' then
        local rest = t:sub(at + 1):lower()
        for _, f in ipairs(forms) do
          if rest:sub(1, #f.form) == f.form and not rest:sub(#f.form + 1, #f.form + 1):match '[%w_]' then
            found = f
            break
          end
        end
      end
      if found then
        local written = t:sub(at + 1, at + #found.form)
        local n = #mentions
        table.insert(mentions, {
          id = n,
          mentionText = written,
          mentioned = { user = { id = found.id, displayName = found.name, userIdentityType = 'aadUser' } },
        })
        table.insert(out, hold(('<at id="%d">%s</at>'):format(n, html_escape(written))))
        i = at + 1 + #found.form
      else
        local word = not t:sub(at - 1, at - 1):match '%w' and t:sub(at + 1):match '^%u[%w.-]*'
        if word and unknown then
          unknown[word] = true
        end
        table.insert(out, '@')
        i = at + 1
      end
    end
    t = html_escape(table.concat(out))
    t = t:gsub('%*%*(.-)%*%*', '<b>%1</b>')
    t = t:gsub('%*([^*%s][^*]-)%*', '<i>%1</i>')
    return t
  end
  local parts, pos = {}, 1
  while true do
    local a, b, code = s:find('`([^`]+)`', pos)
    if not a then
      table.insert(parts, text(s:sub(pos)))
      break
    end
    table.insert(parts, text(s:sub(pos, a - 1)))
    table.insert(parts, '<code>' .. html_escape(code) .. '</code>')
    pos = b + 1
  end
  return (table.concat(parts):gsub('\1(%d+)\2', function(n)
    return keep[tonumber(n)]
  end))
end

--- Renders Markdown lines as Teams HTML: paragraphs (single newlines kept as <br>), `-`/`*`/`1.` lists, ``` code
--- blocks, `>` quotes and `#` headings (bold), with inline_html for the text. `raw[i]`, when set, is the HTML for line
--- i as it is (an image or a file attachment).
local function markdown_html(lines, raw, forms, mentions, unknown)
  local html, para, list = {}, {}, nil
  local function inline(s)
    return inline_html(s, forms, mentions, unknown)
  end
  local function flush()
    if #para > 0 then
      table.insert(html, '<p>' .. table.concat(para, '<br>') .. '</p>')
      para = {}
    end
    if list then
      table.insert(html, ('<%s>%s</%s>'):format(list.tag, table.concat(list.items), list.tag))
      list = nil
    end
  end
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local bullet = line:match '^%s*[-*+]%s+(.*)$'
    local numbered = not bullet and line:match '^%s*%d+[.)]%s+(.*)$'
    if raw[i] then
      flush()
      table.insert(html, raw[i])
    elseif line:match '^%s*```' then
      flush()
      local code = {}
      i = i + 1
      while i <= #lines and not lines[i]:match '^%s*```' do
        table.insert(code, html_escape(lines[i]))
        i = i + 1
      end
      table.insert(html, '<codeblock class=""><code>' .. table.concat(code, '<br>') .. '</code></codeblock>')
    elseif bullet or numbered then
      local tag = bullet and 'ul' or 'ol'
      if #para > 0 or (list and list.tag ~= tag) then
        flush()
      end
      list = list or { tag = tag, items = {} }
      table.insert(list.items, '<li>' .. inline(bullet or numbered) .. '</li>')
    elseif list and line:match '^%s%s+%S' then
      -- a wrapped list item: joins the item above
      list.items[#list.items] = list.items[#list.items]:gsub('</li>$', ' ' .. inline(vim.trim(line)) .. '</li>')
    elseif line:match '^%s*$' then
      flush()
    elseif line:match '^%s*>' then
      flush()
      local quote = {}
      while i <= #lines and lines[i]:match '^%s*>' do
        table.insert(quote, inline(lines[i]:gsub('^%s*>%s?', '')))
        i = i + 1
      end
      i = i - 1
      table.insert(html, '<blockquote>' .. table.concat(quote, '<br>') .. '</blockquote>')
    elseif line:match '^#+%s' then
      flush()
      table.insert(html, '<p><b>' .. inline(line:gsub('^#+%s+', '')) .. '</b></p>')
    else
      if list then
        flush()
      end
      table.insert(para, inline(line))
    end
    i = i + 1
  end
  flush()
  return table.concat(html)
end

local IMAGE_TYPES = { ['\137PNG'] = 'image/png', ['\255\216\255'] = 'image/jpeg', ['GIF8'] = 'image/gif' }

--- An image file to send: its bytes, MIME type and size (PNG's, from its header), or nil and why not.
local function outgoing_image(path)
  path = vim.fn.expand(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil, 'cannot read ' .. path
  end
  local bytes = f:read '*a'
  f:close()
  local mime
  for magic, type in pairs(IMAGE_TYPES) do
    if bytes:sub(1, #magic) == magic then
      mime = type
    end
  end
  if not mime then
    return nil, path .. ' is not a PNG, JPEG or GIF image'
  end
  local w, h
  if mime == 'image/png' and #bytes >= 24 then
    local function u32(i)
      local a, b, c, d = bytes:byte(i, i + 3)
      return ((a * 256 + b) * 256 + c) * 256 + d
    end
    w, h = u32(17), u32(21)
  end
  return { bytes = bytes, mime = mime, w = w, h = h }
end

local ATTACH_FOLDER = 'Microsoft Teams Chat Files' -- where Teams itself puts the files sent in chats
local UPLOAD_LIMIT = 250 * 1024 * 1024 -- Graph's simple upload

--- Uploads a file to the user's OneDrive (ATTACH_FOLDER, renamed when the name is taken) and lets `emails` read it,
--- as Teams does for a file sent in a chat (Files.ReadWrite). Returns the driveItem, or nil and an error.
local function upload_attachment(path, emails)
  if not token() then
    return nil, 'no Graph token'
  end
  local name = vim.fs.basename(path)
  local encoded = (ATTACH_FOLDER .. '/' .. name):gsub('[^%w/._~-]', function(c)
    return ('%%%02X'):format(c:byte())
  end)
  local url = GRAPH .. '/me/drive/root:/' .. encoded .. ':/content?@microsoft.graph.conflictBehavior=rename'
  local cmd = { 'curl', '-sS', '--max-time', '600', '-X', 'PUT', '-H', '@' .. HEADER_FILE, '-H', 'Content-Type: application/octet-stream' }
  vim.list_extend(cmd, { '--data-binary', '@' .. path, '-w', '\n%{http_code}', url })
  local result = vim.system(cmd, { text = true }):wait(610000)
  local body, status = (result.stdout or ''):match '^(.*)\n(%d+)$'
  local ok, item = pcall(vim.json.decode, body or '', { luanil = { object = true, array = true } })
  if result.code ~= 0 or not ok or type(item) ~= 'table' or not item.id then
    local e = ok and type(item) == 'table' and item.error or {}
    return nil, ('uploading %s: HTTP %s %s %s'):format(name, status or '?', e.code or '', e.message or vim.trim(result.stderr or ''))
  end
  if #emails > 0 then
    local recipients = vim.tbl_map(function(e)
      return { email = e }
    end, emails)
    local _, err =
      api('POST', '/me/drive/items/' .. item.id .. '/invite', { recipients = recipients, requireSignIn = true, sendInvitation = false, roles = { 'read' } })
    if err then
      return nil, ('sharing %s with the chat: %s'):format(name, err)
    end
  end
  return item
end

--- Posts a message to a chat. Multi-line text keeps its lines (as <br>); it is never sent empty. A line that is just
--- an image in Markdown, `![...](PATH)`, sends that image inline in the message (Graph's hosted contents, which
--- Chat.ReadWrite allows), where the line is. A line that is just a link to a local file, `[...](PATH)` (or an image
--- line whose file is not a PNG, JPEG or GIF), attaches that file as Teams does: uploaded to OneDrive, readable by the
--- chat's members, a card in the message (Files.ReadWrite).
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
  if id == CALL_LOG or id == MEETINGS then
    fail 'send: the call log and the meetings are read-only'
  end
  text = vim.trim(text or '')
  if text == '' then
    fail 'send: the message is empty'
  end
  -- the files to attach, checked before anything is uploaded
  local lines, files = vim.split(text, '\r?\n'), {}
  for i, line in ipairs(lines) do
    local bang, path = line:match '^%s*(!?)%[[^%]]*%]%(([/~][^)]*)%)%s*$'
    if path then
      path = vim.fn.expand(path)
      local stat = vim.uv.fs_stat(path)
      if not stat or stat.type ~= 'file' then
        fail('send: no such file: ' .. path)
      end
      if not (bang == '!' and outgoing_image(path)) then
        if stat.size > UPLOAD_LIMIT then
          fail(('send: %s is over 250 MB'):format(path))
        end
        files[i] = path
      end
    end
  end
  local attachments = {}
  if next(files) then
    local chat, data = find(id)
    local emails = {}
    for _, m in ipairs(chat and chat.members or {}) do
      if m.u ~= (data and data.me) and m.e and m.e ~= '' then
        table.insert(emails, m.e)
      end
    end
    for i, path in pairs(files) do
      local item, err = upload_attachment(path, emails)
      if not item then
        fail('send: ' .. err)
      end
      local guid = (item.eTag or ''):match '{([%x-]+)}'
      if not guid then
        fail('send: no id for the uploaded ' .. vim.fs.basename(path))
      end
      files[i] = guid
      table.insert(attachments, { id = guid, contentType = 'reference', contentUrl = item.webUrl, name = item.name })
    end
  end
  -- @mentions resolve against the chat's members (fetched when the cache has none)
  local forms = {}
  if text:find('@', 1, true) then
    local chat, data = find(id)
    local members = chat and chat.members
    if not members or #members == 0 then
      local res = api('GET', '/chats/' .. id .. '/members')
      members = res and trim_members(res.value) or {}
    end
    forms = mention_forms(members, (data and data.me) or me())
  end
  local raw, hosted = {}, {}
  for i, line in ipairs(lines) do
    local path = not files[i] and line:match '^%s*!%[[^%]]*%]%((.-)%)%s*$'
    if files[i] then
      raw[i] = ('<attachment id="%s"></attachment>'):format(files[i])
    elseif path then
      local img, why = outgoing_image(path)
      if not img then
        fail('send: ' .. why)
      end
      local n = tostring(#hosted + 1)
      table.insert(hosted, { ['@microsoft.graph.temporaryId'] = n, contentBytes = vim.base64.encode(img.bytes), contentType = img.mime })
      -- shown at most 600 pixels wide, as Teams shows a pasted screenshot
      local size = ''
      if img.w and img.h and img.w > 0 then
        local w = math.min(img.w, 600)
        size = (' width="%d" height="%d"'):format(w, math.floor(img.h * w / img.w + 0.5))
      end
      raw[i] = ('<p><img src="../hostedContents/%s/$value" alt="image"%s></p>'):format(n, size)
    end
  end
  local mentions, unknown = {}, {}
  local content = markdown_html(lines, raw, forms, mentions, unknown)
  for word in pairs(unknown) do
    io.stderr:write(('send: @%s is not a member of this chat, sent as text\n'):format(word))
  end
  if opts['dry-run'] then
    out(content)
    for _, m in ipairs(mentions) do
      out(('mention %d: %s -> %s'):format(m.id, m.mentionText, m.mentioned.user.displayName))
    end
    return
  end
  local message = { body = { contentType = 'html', content = content } }
  if #mentions > 0 then
    message.mentions = mentions
  end
  if #hosted > 0 then
    message.hostedContents = hosted
  end
  if #attachments > 0 then
    message.attachments = attachments
  end
  local reply, err = api('POST', '/chats/' .. id .. '/messages', message)
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
  if id == SELF_CHAT or id == CALL_LOG or id == MEETINGS then
    return -- no read state (markChatReadForUser refuses them), and never unread
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
  { 'type:', '1:1, group, meeting, self, calls (the call log) or attended (meetings joined)' },
  { 'is:unread', 'chats with unread messages' },
  { 'from:', 'a message sent by: me, or a name (with on:, that day)' },
  { 'has:call', 'chats with a call (with on:, a call those days); shows its duration' },
  { 'since:', 'last activity since: 1d, 7d, 2w, 1M or a date' },
  { 'on:', 'messages on a day: today, yesterday, 3d (ago), 11-05, 2026-11-05, or A..B' },
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
  if key == 'with' or key == 'from' then
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
    if key == 'from' and ('me'):sub(1, #typed) == typed then
      add(sign .. 'from:me', 'value', 'messages you sent')
    end
    for n, k in pairs(counts) do
      -- any word of the name may be the one typed
      local lower = n:lower()
      if typed == '' or lower:sub(1, #typed) == typed or lower:find('[%s,]' .. vim.pesc(typed)) then
        table.insert(list, { n, k })
      end
    end
    table.sort(list, function(a, b)
      if a[2] ~= b[2] then
        return a[2] > b[2] -- most chats first, then by name
      end
      return a[1] < b[1]
    end)
    for i = 1, math.min(#list, 100) do
      local n = list[i][1]
      add(sign .. key .. ':' .. (n:find '[%s,]' and ('"' .. n .. '"') or n), 'value', list[i][2] .. ' chats')
    end
  elseif key == 'type' or key == 'since' or key == 'is' or key == 'on' then
    context = 'value'
    local values = ({
      type = { '1:1', 'group', 'meeting', 'self', 'calls', 'attended' },
      since = { '1d', '7d', '2w', '1M', '3M' },
      is = { 'unread' },
      on = { 'today', 'yesterday', os.date('%m-%d', os.time() - 2 * DAY) },
    })[key]
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

--- Re-reads the desktop app's call log now.
local function calls()
  local data = sync_local_calls()
  if not data then
    fail('no Teams desktop app cache at ' .. DESKTOP_DB .. ' (or no python3)')
  end
  io.stderr:write(('%d calls in %s\n'):format(vim.tbl_count(data.calls), LOCAL_CALLS))
end

-- -- the images of a chat ----------------------------------------------------------------------------------------

--- `images -f fzf -- CHAT_ID`: a row per image pasted into the chat's messages, newest first, from the message cache
--- (all of it, as `refresh --deep` filled it): `url \t date sender: start of the message \t\t`. Nothing is downloaded
--- until `image` shows one.
local function images_of(_, rest)
  local chat, data = find(rest[1] or '')
  if not chat then
    return
  end
  local list = messages(chat, 100000, false, true) or {}
  if lacks_images(list) then
    messages(chat, 50, true)
    list = messages(chat, 100000, false, true) or {}
  end
  local n = 0
  for _, m in ipairs(list) do
    if m.type == 'message' and not m.deleted then
      for i, img in ipairs(m.images or {}) do
        n = n + 1
        local who = m.fromId == data.me and 'you' or (m.from or '?')
        local text = one_line((m.text or ''):gsub('%[image%]', ''))
        local display = ('\27[2m%s\27[0m  \27[36m%s\27[0m  %s%s'):format(
          short_time(m.at),
          who,
          #m.images > 1 and ('\27[33m%d/%d\27[0m '):format(i, #m.images) or '',
          text ~= '' and text:sub(1, 120) or '\27[2m(image only)\27[0m'
        )
        out(table.concat({ img.url .. '#' .. (img.w or '') .. 'x' .. (img.h or ''), display, '', long_time(m.at) .. ' ' .. who }, '\t'))
      end
    end
  end
  if n == 0 then
    out '\t\27[2mNo images in this chat (in the cached messages: `refresh --deep` fetches older ones)\27[0m\t\t'
  end
end

--- The cached file of the image of a row of `images` (`URL#WxH`), downloading it first; nil and an error message.
local function image_file(key)
  local url, w, h = (key or ''):match '^(https://[^#]+)#(%d*%.?%d*)x(%d*%.?%d*)$'
  if not url then
    return nil, nil, 'not an image of a chat: ' .. tostring(key)
  end
  local img = { url = url, w = tonumber(w), h = tonumber(h), big = true }
  fetch_images { img }
  if not img.file then
    return nil, nil, 'could not download the image (no Graph token?)'
  end
  return img.file, img
end

--- `image [--copy | --open] -- URL#WxH`: the image of a row of `images`, as large as the preview (fzf's), or copied to
--- the clipboard (macOS, or Wayland/X11 with wl-copy/xclip), or opened in the system's image viewer.
local function image(opts, rest)
  local file, img, err = image_file(rest[1])
  if not file then
    if opts.copy or opts.open then
      fail(err)
    end
    out(err)
    return
  end
  if opts.copy then
    local ok, why = Img.copy(file)
    if not ok then
      fail(why)
    end
    io.stderr:write 'Image copied to the clipboard\n'
    return
  end
  if opts.open then
    Img.open(file)
    return
  end
  out(table.concat(Img.draw_big(file), '\n'))
end

--- `members -f fzf -- CHAT_ID`: the people in a chat, a row each sorted by name and you last:
--- `address \t name  address \t`, after a heading row with the chat's name and how many there are. They come from the
--- cache, which a refresh fills for chats that changed; a chat cached without them is asked for them now.
local function members_of(_, rest)
  local chat, data = find(rest[1] or '')
  if not chat then
    return
  end
  if chat.id == SELF_CHAT or chat.id == CALL_LOG or chat.id == MEETINGS then
    out '\t\27[2mThis is not a chat with members\27[0m\t'
    return
  end
  local list = chat.members
  if not list or #list == 0 then
    local res, err = api('GET', '/chats/' .. chat.id .. '/members')
    if not res then
      out('\t\27[31mCannot fetch the members: ' .. tostring(err) .. '\27[0m\t')
      return
    end
    list = trim_members(res.value)
  end
  local my_id = data.me
  local rows = vim.deepcopy(list)
  table.sort(rows, function(a, b)
    if (a.u == my_id) ~= (b.u == my_id) then
      return b.u == my_id
    end
    return (a.n or ''):lower() < (b.n or ''):lower()
  end)
  out(('\t\27[1m%s\27[0m  \27[2m%d member%s\27[0m\t'):format(chat_name(chat, my_id), #rows, #rows == 1 and '' or 's'))
  local width = 0
  for _, m in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(m.n or ''))
  end
  for _, m in ipairs(rows) do
    local name = (m.n and m.n ~= '') and m.n or '(unknown)'
    local you = m.u == my_id and '  \27[33m(you)\27[0m' or ''
    out(table.concat({ m.e or '', pad(name, width) .. '  \27[36m' .. (m.e or '') .. '\27[0m' .. you, '' }, '\t'))
  end
end

--- `people -f fzf -- CHAT_ID`: everyone in the cached chats who is not in this one, to add to it: a row each, sorted by
--- name, `address \t name  address \t`, after a heading row. Graph's directory search would need User.ReadBasic.All,
--- which this token lacks, so the people known are those you share a chat with; anyone else is added by address.
local function people(_, rest)
  local chat, data = find(rest[1] or '')
  if not chat then
    return
  end
  local present, seen, rows = {}, {}, {}
  for _, m in ipairs(chat.members or {}) do
    present[(m.e or ''):lower()] = true
  end
  for _, c in ipairs(data.chats or {}) do
    for _, m in ipairs(c.members or {}) do
      local key = (m.e or ''):lower()
      if key ~= '' and m.u ~= data.me and not present[key] and not seen[key] then
        seen[key] = true
        table.insert(rows, m)
      end
    end
  end
  table.sort(rows, function(a, b)
    return (a.n or ''):lower() < (b.n or ''):lower()
  end)
  out(('\t\27[1mAdd to %s\27[0m  \27[2m%d people known from your chats; type an address for anyone else\27[0m\t'):format(chat_name(chat, data.me), #rows))
  local width = 0
  for _, m in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(m.n or ''))
  end
  for _, m in ipairs(rows) do
    out(table.concat({ m.e, pad(m.n or '', width) .. '  \27[36m' .. m.e .. '\27[0m', '' }, '\t'))
  end
end

--- `add-members [--history all|none|DAYS] -- CHAT_ID ADDRESS...`: adds people to a group or meeting chat (Graph's
--- POST /chats/{id}/members, which Chat.ReadWrite allows), sharing all of the chat's history with them (the default,
--- as in Teams' own Add people dialog), none, or that of the last DAYS days. A person known from the cached chats is added by their user id, anyone
--- else by the address (their sign-in name, which at HPE is the mail address). Each one added joins the cached members.
local function add_members(opts, rest)
  local id = table.remove(rest, 1) or ''
  local chat, data = find(id)
  if not chat then
    fail('chat ' .. id .. ' is not in the cache', 2)
  end
  if chat.chatType ~= 'group' and chat.chatType ~= 'meeting' then
    fail('only a group or meeting chat takes new members (this one is ' .. tostring(chat.chatType) .. ')', 2)
  end
  if #rest == 0 then
    fail('no one to add', 2)
  end
  local history = opts.history or 'all'
  local start
  if history == 'all' then
    start = '0001-01-01T00:00:00Z'
  elseif tonumber(history) then
    start = iso_utc(os.time() - tonumber(history) * 86400)
  elseif history ~= 'none' then
    fail('--history takes all, none or a number of days', 2)
  end
  local known = {}
  for _, c in ipairs(data.chats or {}) do
    for _, m in ipairs(c.members or {}) do
      if m.e and m.u then
        known[m.e:lower()] = m
      end
    end
  end
  local failed = 0
  for _, addr in ipairs(rest) do
    local m = known[addr:lower()]
    local body = {
      ['@odata.type'] = '#microsoft.graph.aadUserConversationMember',
      roles = { 'owner' },
      ['user@odata.bind'] = GRAPH .. "/users('" .. (m and m.u or addr) .. "')",
      visibleHistoryStartDateTime = start,
    }
    local res, err = api('POST', '/chats/' .. chat.id .. '/members', body)
    if res then
      out('added ' .. (res.displayName or (m and m.n) or addr) .. ' <' .. (res.email or addr) .. '>')
      local fresh, fdata = find(chat.id) -- re-read: a background refresh may have rewritten the cache meanwhile
      if fresh then
        fresh.members = fresh.members or {}
        table.insert(fresh.members, { n = res.displayName or (m and m.n), e = res.email or addr, u = res.userId or (m and m.u) })
        write_json(CHATS, fdata)
      end
    else
      failed = failed + 1
      io.stderr:write('cannot add ' .. addr .. ': ' .. tostring(err) .. '\n')
    end
  end
  if failed > 0 then
    os.exit(1)
  end
end

local commands = {
  members = members_of,
  people = people,
  ['add-members'] = add_members,
  images = images_of,
  image = image,
  search = search,
  show = show,
  terms = terms,
  complete = complete,
  url = url,
  refresh = refresh,
  send = send,
  read = read,
  calls = calls,
}
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
