-- The notmuch backend of liveq, run with `nvim -l` (no plugins, no user config):
--
--   nvim -l notmuch.lua search -f fzf -l LIMIT [--tree] -- QUERY    --tree: a row per message, threaded (5th field: depth)
--   nvim -l notmuch.lua show [--plain] [--fold] [--match QUERY] -- thread:ID
--   nvim -l notmuch.lua terms -- QUERY                       the words of QUERY to highlight, as JSON: [["word"], ["a", "phrase"]]
--   nvim -l notmuch.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l notmuch.lua url -- thread:ID                     a link to the thread, from the $LIVEQ_MAIL_URL template
--   nvim -l notmuch.lua html -- thread:ID                    writes the thread as an HTML page in $TMPDIR; prints its path
--   nvim -l notmuch.lua saved -f tsv                         notmuch's named queries (query.NAME in its config)
--   nvim -l notmuch.lua save [--label NAME] -- QUERY         adds a named query; usable as `query:NAME` anywhere
--   nvim -l notmuch.lua tag -- '+a -b' thread:ID...          changes the tags of threads
--   nvim -l notmuch.lua images -f fzf -- thread:ID           the images of a thread (inline and attached), newest first
--   nvim -l notmuch.lua image [--copy|--open] -- MSGID#PART  one of them as large as the preview, copied, or opened
--
-- Items are threads (`thread:ID`), or messages (`id:MESSAGE-ID`) in the threaded view of `search --tree`. The mailbox is the one notmuch is configured for, so a source picks it with $NOTMUCH_CONFIG.
-- See ../README.md for the contract.

local PREFIXES = {
  { 'from:', 'sender name or address' },
  { 'to:', 'recipient name or address' },
  { 'subject:', 'words in the subject' },
  { 'tag:', 'tag' },
  { 'is:', 'tag (alias)' },
  { 'date:', 'date range, e.g. date:7d.. or date:2026-01..2026-03' },
  { 'folder:', 'Maildir folder' },
  { 'path:', 'path of the file' },
  { 'attachment:', 'attachment file name' },
  { 'mimetype:', 'MIME type of a part' },
  { 'body:', 'words in the body' },
  { 'id:', 'message id' },
  { 'thread:', 'thread id' },
  { 'query:', 'saved (named) query' },
}
local KEYWORDS = { 'and', 'or', 'not' }
local DATES = { 'today', 'yesterday', '1d..', '7d..', '1w..', '2w..', '1M..', '3M..', '6M..', '1y..', 'this_month', 'last_month' }
local MIMETYPES = { 'application/pdf', 'text/calendar', 'image/png', 'image/jpeg', 'text/html' }
local MAX_CANDIDATES = 200

local collected -- when set, out() keeps the lines here instead of printing them (show --match highlights them first)
local target -- with collected: the lines { start, finish } of the message of an `id:` item, found by show()

local IMAGE_LINE = '\6' -- starts each line of a drawn image (`show --images`): never highlighted, dropped on output

local function out(text)
  if collected then
    table.insert(collected, text)
  else
    io.stdout:write((text:gsub(IMAGE_LINE, '')), '\n')
  end
end

local function fail(message, code)
  io.stderr:write('liveq-notmuch: ' .. message .. '\n')
  os.exit(code or 1)
end

local function notmuch(args, opts)
  local cmd = { os.getenv 'LIVEQ_NOTMUCH' or 'notmuch' }
  vim.list_extend(cmd, args)
  local ok, job = pcall(vim.system, cmd, { text = true, stdin = opts and opts.stdin })
  if not ok then
    return nil, tostring(job)
  end
  local result = job:wait(30000)
  if result.code ~= 0 then
    return nil, vim.trim((result.stderr ~= '' and result.stderr) or result.stdout or ('exit ' .. result.code))
  end
  return result.stdout or ''
end

local function json(args)
  local stdout, err = notmuch(args)
  if not stdout then
    return nil, err
  end
  local ok, data = pcall(vim.json.decode, stdout ~= '' and stdout or 'null', { luanil = { object = true, array = true } })
  if not ok then
    return nil, 'invalid JSON from notmuch'
  end
  return data
end

local function parse(args)
  local opts, rest = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--plain' or a == '--fold' or a == '--tree' or a == '--copy' or a == '--open' or a == '--images' then
      opts[a:sub(3)] = true
      i = i + 1
    elseif a:match '^%-' and args[i + 1] then
      opts[a:gsub('^%-+', '')] = args[i + 1]
      i = i + 2
    else
      table.insert(rest, a)
      i = i + 1
    end
  end
  return opts, rest
end

local function truncate(s, width)
  s = (s or ''):gsub('%s+', ' ')
  local n = vim.fn.strchars(s)
  if n > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. '…'
  end
  return s .. string.rep(' ', width - n)
end

local function is_thread(id)
  return id and id:match '^thread:%x+$' ~= nil
end

--- A thread (`thread:ID`) or a message (`id:MESSAGE-ID`, the rows of the threaded view).
local function is_item(id)
  return is_thread(id) or (id and id:match '^id:%S' ~= nil)
end

--- The notmuch query of an item: a message id is quoted, since it may contain characters of the query syntax.
local function item_query(id)
  if is_thread(id) then
    return id
  end
  return 'id:"' .. id:sub(4):gsub('"', '""') .. '"'
end

-- -- search -------------------------------------------------------------------------------------------------------

-- the prefixes whose terms are words, so that `prefix:word*` matches the words that start with `word`
local WILDCARD_PREFIXES = { from = true, to = true, subject = true, body = true, attachment = true }
local OPERATORS = { ['and'] = true, ['or'] = true, ['not'] = true }

--- The query as it is being typed: notmuch matches whole words only, so the last word, while it is still being typed
--- (no space after it), also matches as a prefix: `device configu` searches `device (configu or configu*)`. The word
--- itself stays, so that its stemmed forms still match too. Words under 3 characters and terms that are not plain
--- words (tags, dates, addresses, quoted phrases) are left alone.
local function live_query(query)
  if query:match '%s$' then
    return query
  end
  local before, word = query:match '^(.-)(%S+)$'
  if not word then
    return query
  end
  local open, rest = word:match '^([%(%-]*)(.*)$' -- `(word` or `-word`
  local prefix, term = rest:match '^(%a+):(.*)$'
  if prefix then
    if not WILDCARD_PREFIXES[prefix:lower()] then
      return query
    end
    prefix = prefix .. ':'
  else
    prefix, term = '', rest
  end
  if #term < 3 or not term:match '^%w+$' or OPERATORS[term:lower()] then
    return query
  end
  return ('%s%s(%s%s or %s%s*)'):format(before, open, prefix, term, prefix, term)
end

local search_tree -- the threaded view of search, defined below

-- -- matches of a query -----------------------------------------------------------------------------------------

-- the prefixes whose terms are words of the text that is shown (the others are tags, dates, addresses, …)
local TEXT_PREFIXES = { subject = true, body = true }

--- The words of a query that the text of a thread may contain, to highlight: the free words and phrases and those of
--- `subject:`/`body:`, but not negated ones (`-word`, `not word`), operators or other prefixes. Each is a list of
--- lowercase words (a phrase has several).
local function query_terms(query)
  local terms = {}
  local negated = false
  local i, n = 1, #query
  while i <= n do
    local c = query:sub(i, i)
    if c:match '[%s()]' then
      i = i + 1
    else
      local minus = c == '-'
      if minus then
        i = i + 1
      end
      local prefix = query:match('^(%a+):', i)
      if prefix then
        i = i + #prefix + 1
      end
      local value
      if query:sub(i, i) == '"' then
        local close = query:find('"', i + 1, true) or n + 1
        value, i = query:sub(i + 1, close - 1), close + 1
      else
        local s, e = query:find('^[^%s()]*', i)
        value, i = query:sub(s, e), e + 1
      end
      if not prefix and OPERATORS[value:lower()] then
        negated = value:lower() == 'not'
      else
        if not minus and not negated and (not prefix or TEXT_PREFIXES[prefix:lower()]) then
          local words = {}
          for w in value:gmatch '[%w_]+' do
            table.insert(words, w:lower())
          end
          if #words > 1 or (words[1] and #words[1] > 1) then
            table.insert(terms, words)
          end
        end
        negated = false
      end
    end
  end
  return terms
end

local function terms(_, rest)
  out(vim.json.encode(query_terms(rest[1] or '')))
end

--- Lua patterns (on lowercase text) for the terms: each starts at a word, and its last word matches as a prefix
--- (notmuch also matches stemmed forms, and the picker's last word as a prefix: `config` finds "configuration").
local function term_patterns(query)
  local patterns = {}
  for _, words in ipairs(query_terms(query)) do
    table.insert(patterns, '%f[%w]' .. table.concat(words, '[^%w]+'))
  end
  return patterns
end

local HL_ON, HL_OFF = '\27[7m', '\27[27m'

--- The line with the matches of the patterns in reverse video, and the set of the patterns (indexes) found in it, nil
--- when none. Colour codes in the line are kept (the match is looked for in the visible text), and the highlight is
--- turned on again after each of them.
local function highlight(line, patterns)
  local visible, at = {}, {} -- the visible bytes, and where each is in the line
  local i = 1
  while i <= #line do
    local _, e = line:find('^\27%[[%d;]*m', i)
    if e then
      i = e + 1
    else
      table.insert(visible, line:sub(i, i))
      at[#visible] = i
      i = i + 1
    end
  end
  local text = table.concat(visible):lower()
  local on = {}
  local found
  for p, pattern in ipairs(patterns) do
    local init = 1
    while true do
      local s, e = text:find(pattern, init)
      if not s then
        break
      end
      found = found or {}
      found[p] = true
      for k = s, e do
        on[k] = true
      end
      init = e + 1
    end
  end
  if not found then
    return line, nil
  end
  local result = {}
  local k = 0 -- visible bytes copied
  i = 1
  while i <= #line do
    local _, e = line:find('^\27%[[%d;]*m', i)
    if e then
      table.insert(result, line:sub(i, e))
      if on[k] and on[k + 1] then
        table.insert(result, HL_ON) -- e.g. after the reset that ends a link
      end
      i = e + 1
    else
      k = k + 1
      if on[k] and not on[k - 1] then
        table.insert(result, HL_ON)
      end
      table.insert(result, line:sub(i, i))
      if on[k] and not on[k + 1] then
        table.insert(result, HL_OFF)
      end
      i = i + 1
    end
  end
  return table.concat(result), found
end

--- Prints the lines kept by out() with the matches of the query highlighted, and writes the numbers of the lines that
--- have one to $LIVEQ_MATCH_FILE (liveq's picker scrolls the preview to them): `id`, the index of the match to show
--- first, and the line numbers separated by spaces. The one shown first is the first line with the term that is the
--- rarest in the thread, below the subject: a common term (e.g. a word of the subject) is in every message, so the
--- rarest one is closer to why the thread matched.
---
--- `range`: the lines of the message of an `id:` item (a row of the threaded view); its first line is shown first,
--- at the top of the preview (a number with a `t` after it), and the matches follow.
---
--- `plain`: the lines are printed as they are (liveq's buffer and float highlight with the search register), but the
--- matches are still written, so that they start at the same match as the preview.
local function print_highlighted(lines, query, id, range, plain)
  local patterns = term_patterns(query)
  local text = vim.split(table.concat(lines, '\n'), '\n', { plain = true })
  local matches, found_in = {}, {}
  local count = {} -- lines per pattern
  for n, line in ipairs(text) do
    local found
    if line:sub(1, 1) == IMAGE_LINE then
      line = line:sub(2) -- a drawn image: its escapes and data are not text to highlight
    elseif #patterns > 0 then
      local marked
      marked, found = highlight(line, patterns)
      line = plain and line or marked
      if found then
        table.insert(matches, n)
        found_in[#matches] = found
        for p in pairs(found) do
          count[p] = (count[p] or 0) + 1
        end
      end
    end
    io.stdout:write(line, '\n')
  end
  io.stdout:flush()
  local rarest
  for p, c in pairs(count) do
    if not rarest or c < count[rarest] or (c == count[rarest] and p < rarest) then
      rarest = p
    end
  end
  local first = matches[1] and 1 or 0
  if range then
    first = 1
    while matches[first] and matches[first] < range[1] do
      first = first + 1
    end
    table.insert(matches, first, range[1] .. 't')
  else
    for i, n in ipairs(matches) do
      if n > 1 and found_in[i][rarest] then
        first = i
        break
      end
    end
  end
  local file = os.getenv 'LIVEQ_MATCH_FILE'
  if file and file ~= '' then
    local f = io.open(file, 'w')
    if f then
      f:write(id, '\n', first, '\n', table.concat(matches, ' '), '\n')
      f:close()
    end
  end
end

--- The subject without its Re:/Fw: prefixes, to tell whether a reply changed it.
local function base_subject(subject)
  subject = vim.trim(subject or ''):lower()
  while true do
    local prefix, rest = subject:match '^(%a+)%s*%[?%d*%]?:%s*(.*)$'
    if not prefix or not (prefix == 're' or prefix == 'fw' or prefix == 'fwd' or prefix == 'aw') then
      return subject
    end
    subject = rest
  end
end

--- The name of a From header ("Shelat, Ritesh" of `"Shelat, Ritesh" <ritesh@…>`), else its address.
local function sender_name(from)
  from = from or ''
  local name = from:match '^%s*"?(.-)"?%s*<'
  return (name and name ~= '') and name or (from:gsub('[<>]', ''))
end

--- The threaded view, like mutt's: a row per message of the threads (newest thread first), in reply order, with the
--- depth in the 5th field and \31 where liveq's tree.awk draws the branches. A reply's subject is only shown when it
--- changed. Messages that match the query are shown normally and the others dimmed, unread ones in bold. Tags that
--- every message has (e.g. the mailbox's) are left out.
search_tree = function(query, threads)
  local ids = vim.tbl_map(function(t)
    return 'thread:' .. t.thread
  end, threads)
  -- `match` is set on the messages that match the query; --entire-thread adds the others of their threads
  local forest, err = json {
    'show',
    '--format=json',
    '--body=false',
    '--entire-thread=true',
    '--sort=newest-first',
    ('(%s) and (%s)'):format(table.concat(ids, ' or '), query),
  }
  if not forest then
    out('\t\27[31m' .. tostring(err):gsub('\n', ' ') .. '\27[0m\t\t')
    return
  end
  local rows = {}
  local function walk(nodes, depth, parent_subject)
    for _, node in ipairs(nodes or {}) do
      local m, replies = node[1], node[2]
      local subject = m and (m.headers or {}).Subject or ''
      if m then
        local changed = depth == 0 or base_subject(subject) ~= parent_subject
        table.insert(rows, { m = m, depth = depth, subject = changed and subject or '' })
      end
      walk(replies, depth + 1, base_subject(subject))
    end
  end
  for _, thread in ipairs(forest) do
    walk(thread, 0, nil)
  end
  local common -- the tags of every message
  for _, row in ipairs(rows) do
    local set = {}
    for _, tag in ipairs(row.m.tags or {}) do
      if not common or common[tag] then
        set[tag] = true
      end
    end
    common = set
  end
  common = common or {}
  for _, row in ipairs(rows) do
    local m = row.m
    local tags = vim.tbl_filter(function(tag)
      return tag ~= 'inbox' and tag ~= 'unread' and not common[tag]
    end, m.tags or {})
    local style = vim.tbl_contains(m.tags or {}, 'unread') and '\27[1m' or (m.match and '' or '\27[2m')
    out(
      ('id:%s\t%s%s \27[33m%s\27[39m \31%s \27[36m%s\27[0m\t\t%s\t%d'):format(
        m.id,
        style,
        truncate(m.date_relative, 12),
        truncate(sender_name((m.headers or {}).From), 22),
        row.subject,
        table.concat(tags, ' '),
        ((m.headers or {}).Subject or ''):gsub('[\t\n]', ' '),
        row.depth
      )
    )
  end
end

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local fzf = opts.f == 'fzf' or opts.format == 'fzf'
  if fzf then
    -- fzf passes the prompt without its trailing space; the picker's {q} keeps it in the raw arguments
    query = live_query(table.concat(rest, ' '):gsub('^%s+', ''))
  end
  if query == '' then
    if fzf then
      out '\t\27[2mType a notmuch query, e.g. from:bank tag:attachment date:1M..   tab: complete\27[0m\t\t'
    end
    return
  end
  local threads, err = json { 'search', '--format=json', '--sort=newest-first', '--limit=' .. (opts.l or opts.limit or 100), query }
  if not threads then
    if fzf then
      out('\t\27[31m' .. err:gsub('\n', ' ') .. '\27[0m\t\t')
      return
    end
    fail(err)
  end
  if #threads == 0 and fzf then
    out '\t\27[2mNo threads match the query\27[0m\t\t'
  end
  if opts.tree and fzf and #threads > 0 then
    return search_tree(query, threads)
  end
  for _, t in ipairs(threads) do
    local id = 'thread:' .. t.thread
    if fzf then
      local tags = table.concat(
        vim.tbl_filter(function(tag)
          return tag ~= 'inbox'
        end, t.tags or {}),
        ' '
      )
      local count = (t.total or 1) > 1 and (' \27[2m(' .. t.total .. ')\27[0m') or ''
      out(
        ('%s\t\27[2m%s\27[0m \27[33m%s\27[0m %s%s \27[36m%s\27[0m\t\t%s'):format(
          id,
          truncate(t.date_relative, 12),
          truncate(t.authors, 22),
          t.subject or '',
          count,
          tags,
          (t.subject or ''):gsub('[\t\n]', ' ')
        )
      )
    else
      out(('%s\t%s\t%s\t%s'):format(id, t.date_relative or '', t.authors or '', t.subject or ''))
    end
  end
end

-- -- show ---------------------------------------------------------------------------------------------------------

local ENTITIES = { nbsp = ' ', amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", ['#39'] = "'" }

local Img = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/images.lua') -- shared with teams.lua
-- not liveq/mail/: the shell's `lq` keeps the mail source's query history in a file of that name
local IMAGE_CACHE = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/liveq/mail-images'

local W3M = vim.fn.executable 'w3m' == 1

--- The width to lay text out in: fzf's preview window, else a fixed one (the float is at most 110 wide).
--- The width to lay text out in: $LIVEQ_WIDTH when the frontend gives one (the text width of the buffer or float that
--- shows it), else fzf's preview window, else 100.
local function text_width()
  local given = tonumber(os.getenv 'LIVEQ_WIDTH' or '')
  if given then
    return math.max(40, given)
  end
  local columns = tonumber(os.getenv 'FZF_PREVIEW_COLUMNS' or '')
  return math.max(40, math.min(columns or 100, 160) - 2)
end

--- Starts w3m on an HTML part (it lays out tables, lists and paragraphs as a browser would); nil when it cannot.
local function w3m_start(html)
  -- notmuch has already decoded the part to UTF-8, so a charset the HTML declares would be wrong now
  html = html:gsub('<[Mm][Ee][Tt][Aa][^>]-[Cc][Hh][Aa][Rr][Ss][Ee][Tt][^>]*>', '')
  local ok, job = pcall(
    vim.system,
    { 'w3m', '-T', 'text/html', '-dump', '-cols', tostring(text_width()), '-I', 'UTF-8', '-O', 'UTF-8' },
    { stdin = html, text = true }
  )
  return ok and job or nil
end

--- The text w3m rendered; nil when it failed.
local function w3m_finish(job)
  local result = job:wait(5000)
  if result.code ~= 0 or not result.stdout then
    return nil
  end
  return vim.trim((result.stdout:gsub('[ \t]+\n', '\n'):gsub('\n\n\n+', '\n\n')))
end

--- The text of an HTML part with its markup stripped, when w3m is not there.
local function crude_html_to_text(html)
  local text = html:gsub('<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>', ''):gsub('<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>', '')
  text = text:gsub('<!%-%-.-%-%->', '')
  text = text:gsub('<[Bb][Rr]%s*/?>', '\n'):gsub('</[Pp]>', '\n\n'):gsub('</[Tt][Rr]>', '\n'):gsub('</[Dd][Ii][Vv]>', '\n'):gsub('</[Hh]%d>', '\n\n')
  text = text:gsub('<[^>]+>', ' ')
  text = text:gsub('&(#?%w+);', function(name)
    if ENTITIES[name] then
      return ENTITIES[name]
    end
    local code = name:match '^#(%d+)$'
    return code and vim.fn.nr2char(tonumber(code)) or ('&' .. name .. ';')
  end)
  text = text:gsub('[ \t\r]+', ' '):gsub(' *\n *', '\n'):gsub('\n\n\n+', '\n\n')
  return vim.trim(text)
end

-- w3m runs on every HTML part of a thread at once, up to this many processes; the rest run one by one when read
local MAX_W3M_JOBS = 32
local w3m_jobs = 0

--- The text of an HTML part, as a function that returns it: w3m starts now, so that the parts of a thread render in
--- parallel, and the function waits for it. Without w3m (or when it fails), the crude conversion.
local function html_to_text(html)
  local job
  if W3M and w3m_jobs < MAX_W3M_JOBS then
    job = w3m_start(html)
    w3m_jobs = w3m_jobs + 1
  end
  return function()
    if W3M and not job then
      job = w3m_start(html)
    end
    return (job and w3m_finish(job)) or crude_html_to_text(html)
  end
end

--- The text of a message (as a function that returns it, see html_to_text) and its attachments. With w3m, the HTML
--- alternative rendered (it keeps the layout that the plain one of e.g. Outlook loses, which double-spaces every
--- line); without it, the text/plain parts when there are any, else the HTML ones stripped of markup.
--- Third: the message's images for `show --images`, `{ inline = CIDS, parts = PARTS }`: the content-id of each
--- [image] placeholder in the order of the text, and every image part (inline or attached).
local function message_text(message)
  local texts, htmls, html_parts, attachments = {}, {}, {}, {}
  local pictures = { inline = {}, parts = {} }
  local function walk(part)
    if type(part) ~= 'table' then
      return
    end
    local ctype = (part['content-type'] or ''):lower()
    if ctype:match '^image/' and part.id then
      table.insert(pictures.parts, part)
    end
    if part.filename then
      table.insert(attachments, ('%s (%s)'):format(part.filename, ctype))
    elseif ctype == 'text/plain' and type(part.content) == 'string' then
      table.insert(texts, part.content)
    elseif ctype == 'text/html' and type(part.content) == 'string' then
      -- inline images (`cid:`), which w3m shows as [cid]: [image], or [image: ALT]; alt-g shows them (`images`)
      table.insert(html_parts, (part.content:gsub('<[Ii][Mm][Gg]%s[^>]-[Ss][Rr][Cc]%s*=%s*["\']?[Cc][Ii][Dd]:[^>]*>', function(tag)
        local cid = tag:match '[Ss][Rr][Cc]%s*=%s*["\']?[Cc][Ii][Dd]:([^"\'%s>]+)'
        table.insert(pictures.inline, cid and vim.uri_decode(cid) or '')
        local alt = tag:match '[Aa][Ll][Tt]%s*=%s*"([^"]*)"' or ''
        alt = vim.trim(alt)
        return (alt ~= '' and not alt:lower():match '^cid' and not alt:lower():match '^image%d*$') and ('[image: ' .. alt .. ']') or '[image]'
      end)))
    elseif type(part.content) == 'table' then
      for _, child in ipairs(part.content) do
        walk(child)
      end
    end
  end
  for _, part in ipairs(message.body or {}) do
    walk(part)
  end
  local use_html = #html_parts > 0 and (W3M or #texts == 0)
  if use_html then
    for _, html in ipairs(html_parts) do
      table.insert(htmls, html_to_text(html))
    end
  end
  return function()
    local parts = use_html and vim.tbl_map(function(f)
      return f()
    end, htmls) or texts
    return vim.trim(table.concat(parts, '\n'))
  end,
    attachments,
    pictures
end

local QUOTE_HEADERS = { From = true, Sent = true, Date = true, To = true, Cc = true, Subject = true }

local function quote_header(line)
  local name = line:match '^%s*%**(%a+):%**%s'
  return name and QUOTE_HEADERS[name] and name
end

--- Whether the quoted history of a reply starts at line `i`: Outlook's "From: … Sent:/Date: …" block, Gmail's
--- "On … wrote:" (which w3m may wrap onto two lines), "-----Original Message-----", or a `>` quote.
local function quote_start(lines, i)
  local line = lines[i]
  if quote_header(line) == 'From' then
    for j = i + 1, math.min(i + 4, #lines) do
      local name = quote_header(lines[j])
      if name == 'Sent' or name == 'Date' then
        return true
      end
    end
    return false
  end
  if line:match '^%s*On%s' and (line:match 'wrote:%s*$' or (lines[i + 1] or ''):match 'wrote:%s*$') then
    return true
  end
  return line:match '^%s*%-%-%-%-%-+%s*Original Message' ~= nil or line:match '^%s*>' ~= nil
end

--- The text without the quoted history of a reply; the line after the reply says how much was folded.
local function fold_quotes(text)
  local lines = vim.split(text, '\n', { plain = true })
  for i = 1, #lines do
    if quote_start(lines, i) then
      local kept = vim.list_slice(lines, 1, i - 1)
      -- the separator Outlook puts above the quoted headers (a row of underscores, or w3m's rule for an <hr>)
      while #kept > 0 and (vim.trim(kept[#kept]) == '' or kept[#kept]:match '^%s*[_━─-]+%s*$') do
        table.remove(kept)
      end
      table.insert(kept, '')
      table.insert(kept, ('\27[2m[… %d quoted lines folded]\27[0m'):format(#lines - i + 1))
      return table.concat(kept, '\n')
    end
  end
  return text
end

--- Colours the body of a message for the terminal: the header blocks of quoted replies ("From: … Sent: …") dimmed
--- under a rule, `>` quotes dimmed, inline comment markers ("[Ritesh]") and @mentions highlighted, links underlined.
local function colorize(text, width)
  local dim, reset = '\27[2m', '\27[0m'
  local rule = dim .. string.rep('─', width) .. reset
  local lines = vim.split(text, '\n', { plain = true })
  local result = {}
  local in_headers = false
  for i, line in ipairs(lines) do
    if line:sub(1, 1) == IMAGE_LINE then
      table.insert(result, line)
      goto continue
    end
    if not in_headers and quote_header(line) == 'From' and quote_start(lines, i) then
      in_headers = true
      table.insert(result, rule)
    elseif in_headers and vim.trim(line) == '' then
      in_headers = false -- the block ends at a blank line; long To:/Cc: lines may wrap within it
    end
    if in_headers or line:match '^%s*>' then
      table.insert(result, dim .. line .. reset)
    else
      line = line:gsub('(https?://[^%s<>"\')]+)', '\27[4;34m%1\27[0m')
      line = line:gsub("^(%s*)(%[[%a][%w .,'-]*%])", '%1\27[1;35m%2\27[0m')
      line = line:gsub('(%f[%w@]@%u[%w]*,? ?%u?[%w]*)', '\27[36m%1\27[0m')
      table.insert(result, line)
    end
    ::continue::
  end
  return table.concat(result, '\n')
end

--- The messages of a thread (a forest: lists of [message, replies]), newest first.
local function thread_messages(thread)
  local messages = {}
  local function collect(node)
    if type(node) ~= 'table' then
      return
    end
    if node.id and node.headers then
      table.insert(messages, node)
      return
    end
    -- with --entire-thread=false the messages that do not match are null: holes, which ipairs would stop at
    for i = 1, table.maxn(node) do
      collect(node[i])
    end
  end
  collect(thread)
  for i, m in ipairs(messages) do
    m.liveq_index = i -- the order of the reply tree, to break ties of dates
  end
  table.sort(messages, function(a, b)
    if (a.timestamp or 0) ~= (b.timestamp or 0) then
      return (a.timestamp or 0) > (b.timestamp or 0)
    end
    return a.liveq_index > b.liveq_index
  end)
  for i, m in ipairs(messages) do
    m.liveq_index = #messages - i + 1 -- now the position by date, oldest first, for the dividers
  end
  return messages
end

-- -- images in the preview (`show --images`) -------------------------------------------------------------------

-- The images of each message drawn where its text says [image] (inline `cid:` ones, in the order of the HTML), and
-- those not placed so (attached, or a placeholder w3m lost) after its text, under their name. Extracted from the store
-- once into IMAGE_CACHE (shared with `image`, so the gallery finds them too). Drawn as backends/images.lua does for
-- Teams: real pixels by kitten when fzf runs straight in kitty/Ghostty (the shell's `lq`, through tmux too), else
-- chafa's block art; in Neovim's picker the block art gets the real image over it (liveq/images.lua, via
-- $LIVEQ_IMAGE_FILE). LIVEQ_MAIL_IMAGE_MAX caps the images drawn per preview (12, newest messages first),
-- LIVEQ_MAIL_IMAGE_ROWS the block art's height (16 lines).
local IMAGE_MAX = tonumber(os.getenv 'LIVEQ_MAIL_IMAGE_MAX') or 12
local IMAGE_ROWS = tonumber(os.getenv 'LIVEQ_MAIL_IMAGE_ROWS') or 16
local OVERLAY = os.getenv 'LIVEQ_IMAGE_FILE'
OVERLAY = OVERLAY ~= '' and OVERLAY or nil
local FONT_RATIO = os.getenv 'LIVEQ_FONT_RATIO'

--- The cache file of part `part_id` of message `msgid` (the key `image` uses: `MSGID#PART`).
local function image_file(msgid, part_id)
  return IMAGE_CACHE .. '/' .. vim.fn.sha256(msgid .. '#' .. part_id):sub(1, 32)
end

--- Extracts the images not cached yet, in parallel; sets `file` on each one there.
local function extract_images(images)
  vim.fn.mkdir(IMAGE_CACHE, 'p')
  local jobs = {}
  for _, img in ipairs(images) do
    local file = image_file(img.msgid, img.part)
    if vim.uv.fs_stat(file) then
      img.file = file
    else
      local cmd = { os.getenv 'LIVEQ_NOTMUCH' or 'notmuch', 'show', '--format=raw', '--part=' .. img.part, 'id:' .. img.msgid }
      local ok, job = pcall(vim.system, cmd)
      if ok then
        table.insert(jobs, { img = img, file = file, job = job })
      end
    end
  end
  for _, j in ipairs(jobs) do
    local result = j.job:wait(30000)
    if result.code == 0 and result.stdout and result.stdout ~= '' then
      local tmp = j.file .. '.' .. vim.uv.os_getpid() .. '.part'
      local f = io.open(tmp, 'wb')
      if f then
        f:write(result.stdout)
        f:close()
        os.rename(tmp, j.file)
        j.img.file = j.file
      end
    end
  end
end

--- Draws `images` at most `width` columns wide; sets `lines` (and the box, `cols` x `rows`) on each one drawn.
local function draw_images(images, width, format)
  format = format or (OVERLAY and vim.fn.executable 'chafa' == 1 and 'symbols') or Img.format()
  if not format or #images == 0 then
    return
  end
  local jobs = {}
  for _, img in ipairs(images) do
    if img.file and not img.lines then
      -- a real image (kitty's, or the picker's over the art) as tall as the preview, so that a screenshot's text can
      -- be read; block art shorter, as it only tells what the image is
      local rows = IMAGE_ROWS
      if OVERLAY or format == 'kitty' then
        rows = math.max(IMAGE_ROWS, (tonumber(os.getenv 'FZF_PREVIEW_LINES') or 30) - 2)
      end
      local job = Img.start(img.file, width, rows, format, FONT_RATIO)
      if job then
        table.insert(jobs, { img = img, job = job })
      end
    end
  end
  for _, j in ipairs(jobs) do
    local lines = Img.finish(j.job, format)
    if lines then
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

local PLACEHOLDER = '%[image[^%]\n]*%]'

--- Plans and draws the images of `messages` (their `bodies`, texts resolved into `.resolved`): sets `bodies[i].slots`
--- (the image of each placeholder, by position) and `.rest` (the others, after the text). Writes the picker's layout
--- file first, numbering the images in the order they will be printed, so captions and file always agree.
local function prepare_images(messages, bodies, width, fold)
  -- the messages the preview opens at (`match`: the `id:` item's, or those the query found) get the budget first
  local order = {}
  for i, m in ipairs(messages) do
    if m.match then
      table.insert(order, i)
    end
  end
  for i, m in ipairs(messages) do
    if not m.match then
      table.insert(order, i)
    end
  end
  local all = {}
  for _, i in ipairs(order) do
    local m, b = messages[i], bodies[i]
    b.slots, b.rest = {}, {}
    local by_cid, used, referenced = {}, {}, {}
    for _, cid in ipairs(b.pictures.inline) do
      referenced[cid] = true
    end
    for _, part in ipairs(b.pictures.parts) do
      local cid = part['content-id']
      if cid then
        by_cid[(cid:gsub('^<', ''):gsub('>$', ''))] = part
      end
    end
    local _, placeholders = b.resolved:gsub(PLACEHOLDER, '')
    for k = 1, placeholders do
      local part = by_cid[b.pictures.inline[k] or '']
      if part and not used[part] and #all < IMAGE_MAX then
        used[part] = true
        b.slots[k] = { msgid = m.id, part = part.id }
        table.insert(all, b.slots[k])
      end
    end
    for _, part in ipairs(b.pictures.parts) do
      local cid = (part['content-id'] or ''):gsub('^<', ''):gsub('>$', '')
      -- folded (alt-h): an inline image whose placeholder was in the quoted history stays hidden with it
      if not used[part] and #all < IMAGE_MAX and not (fold and referenced[cid]) then
        used[part] = true
        local img = { msgid = m.id, part = part.id, name = part.filename or part['content-type'] }
        table.insert(b.rest, img)
        table.insert(all, img)
      end
    end
  end
  if #all == 0 then
    return 0
  end
  extract_images(all)
  draw_images(all, math.max(8, width - 1))
  -- numbered in the order they are printed (the captions'), not the order they were planned in
  local n, rows = 0, {}
  local function number(img)
    if img and img.lines then
      n = n + 1
      img.n = n
      table.insert(rows, ('%d\t%d\t%d\t%s'):format(n, img.cols, img.rows, img.file))
    end
  end
  for _, b in ipairs(bodies) do
    for k = 1, table.maxn(b.slots) do
      number(b.slots[k])
    end
    for _, img in ipairs(b.rest) do
      number(img)
    end
  end
  if OVERLAY then
    local f = io.open(OVERLAY, 'w')
    if f then
      f:write(table.concat(rows, '\n'), '\n')
      f:close()
    end
  end
  return n
end

--- An image's lines as a block of text: for the picker's real images, below a caption `[image K/N]` that tells it
--- where image K is.
local function image_block(img, total, label)
  local caption = OVERLAY and (IMAGE_LINE .. ('\27[2m[image %d/%d]\27[0m'):format(img.n, total)) or (label and (IMAGE_LINE .. '\27[2m' .. label .. '\27[0m'))
  return (caption and (caption .. '\n') or '') .. table.concat(img.lines, '\n')
end

--- The text of a message with its images drawn: each placeholder with a drawing replaced by it, on lines of its own,
--- and the images not placed after the text.
local function with_images(text, b, total)
  local k = 0
  text = text:gsub(PLACEHOLDER, function(word)
    k = k + 1
    local img = b.slots[k]
    if img and img.lines then
      return '\n' .. image_block(img, total, word) .. '\n'
    end
  end)
  for _, img in ipairs(b.rest) do
    if img.lines then
      text = text .. '\n\n' .. image_block(img, total, '[' .. (img.name or 'image') .. ']')
    end
  end
  return (text:gsub('\n\n\n+', '\n\n'))
end

--- The thread as text, newest message first. `--plain`: Markdown for the float, without colours. `--fold`: without
--- the quoted history of each reply (alt-h in the picker). `--match QUERY`: the words of the query highlighted, and
--- the lines that have them written to $LIVEQ_MATCH_FILE (see print_highlighted).
local function show(opts, rest)
  local id = rest[1]
  if not is_item(id) then
    return -- e.g. a hint line of fzf
  end
  -- with --match, or for a message in a buffer or float ($LIVEQ_MATCH_FILE tells liveq where the message starts), the
  -- text is collected first, to find the matches and the message
  local locate = opts.plain and not is_thread(id) and os.getenv 'LIVEQ_MATCH_FILE'
  if not collected and (opts.match or locate) then
    collected, target = {}, {}
    show({ fold = opts.fold, plain = opts.plain, match = opts.match, images = opts.images }, rest)
    local lines = collected
    collected = nil
    print_highlighted(lines, opts.match or '', id, target.start and { target.start, target.finish or math.huge }, opts.plain)
    return
  end
  -- a thread shown with the picker's query: notmuch marks the messages that match it (`match`), so that the preview
  -- starts at the newest of them (e.g. the message of `folder:"Sent Items"`, not the reply above it)
  local thread, err
  local query = is_thread(id) and not opts.plain and vim.trim(live_query(opts.match or ''))
  if query and query ~= '' then
    thread = json { 'show', '--format=json', '--entire-thread=true', '--include-html', ('%s and (%s)'):format(id, query) }
    if thread and #thread == 0 then
      thread = nil -- the thread no longer matches
    end
  end
  if not thread then
    thread, err = json { 'show', '--format=json', '--entire-thread=true', '--include-html', item_query(id) }
  end
  if not thread then
    fail(err)
  end
  local plain = opts.plain
  local bold, dim, reset = '\27[1m', '\27[2m', '\27[0m'
  if plain then
    bold, dim, reset = '', '', ''
  end
  local messages = thread_messages(thread)
  -- whether only some of the messages of a thread match the query: the preview then starts at the newest that does
  local narrowed = false
  if is_thread(id) then
    local some, all = false, true
    for _, m in ipairs(messages) do
      some, all = some or m.match == true, all and m.match == true
    end
    narrowed = some and not all
  end
  local width = text_width()
  -- start rendering every message (w3m runs in parallel) before printing the first
  local bodies = {}
  for i, m in ipairs(messages) do
    local text, attachments, pictures = message_text(m)
    bodies[i] = { text = text, attachments = attachments, pictures = pictures }
  end
  -- `--images` (alt-i): every text is needed first, to know which placeholder each image fills, before printing any
  local drawn
  if opts.images and not plain then
    for _, b in ipairs(bodies) do
      b.resolved = b.text()
      if opts.fold then
        b.resolved, b.folded = fold_quotes(b.resolved), true -- only the images left in sight are drawn
      end
    end
    drawn = prepare_images(messages, bodies, width, opts.fold)
  end
  local subject
  for _, m in ipairs(messages) do
    if m.liveq_index == 1 then
      subject = (m.headers or {}).Subject
    end
  end
  out((plain and '# ' or '') .. bold .. (subject or (messages[1] and messages[1].headers or {}).Subject or '') .. reset)
  -- the lines printed so far, to know where the message of an `id:` item is (show --match scrolls to it)
  local function printed()
    local n = 0
    for _, text in ipairs(collected or {}) do
      n = n + select(2, text:gsub('\n', '')) + 1
    end
    return n
  end
  for i, m in ipairs(messages) do
    local h = m.headers or {}
    if collected and target and target.start and not target.finish then
      target.finish = printed()
    end
    if collected and target and m.match and (narrowed or not is_thread(id)) and not target.start then
      target.start = printed() + 1
    end
    if not plain and #messages > 1 then
      local label = (' %d/%d '):format(m.liveq_index, #messages)
      out('\27[33m' .. string.rep('━', 2) .. label .. string.rep('━', width - 2 - #label) .. reset)
    end
    out(((plain and '## ' or '') .. '%s%s%s  %s%s%s'):format(plain and '' or '\27[1;32m', h.From or '', reset, dim, h.Date or '', reset))
    for _, header in ipairs { 'To', 'Cc' } do
      if h[header] then
        out(('%s%s:%s %s'):format(dim, header, reset, h[header]))
      end
    end
    if m.tags and #m.tags > 0 then
      out(('%sTags:%s %s'):format(dim, reset, table.concat(m.tags, ' ')))
    end
    for _, a in ipairs(bodies[i].attachments) do
      out(('%sAttachment:%s %s'):format(dim, reset, a))
    end
    out ''
    local text = bodies[i].resolved or bodies[i].text()
    if drawn and drawn > 0 then
      text = with_images(text, bodies[i], drawn)
    end
    if opts.fold and not bodies[i].folded then
      text = fold_quotes(text)
      if plain then
        text = text:gsub('\27%[[%d;]*m', '')
      end
    end
    if text == '' then
      out(dim .. '(no text part)' .. reset)
    else
      out(plain and text or colorize(text, width))
    end
    out ''
  end
end

-- -- html ---------------------------------------------------------------------------------------------------------

local function escape_html(s)
  return (s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

--- The part of an HTML document that goes inside another page's body: its <style> blocks and the inside of its <body>.
local function html_fragment(html)
  local styles = {}
  for style in html:gmatch '<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>' do
    table.insert(styles, style)
  end
  local body = html:match '<[Bb][Oo][Dd][Yy][^>]*>(.*)</[Bb][Oo][Dd][Yy]>' or html:match '<[Bb][Oo][Dd][Yy][^>]*>(.*)$'
  if not body then
    body = html:gsub('<[Hh][Ee][Aa][Dd].-</[Hh][Ee][Aa][Dd]>', ''):gsub('</?[Hh][Tt][Mm][Ll][^>]*>', ''):gsub('<!%a[^>]*>', '')
    styles = {} -- they are still in the body
  end
  return table.concat(styles, '\n') .. body
end

--- Writes the bytes of a leaf part of a message to `path`; false when notmuch fails.
local function save_part(message_id, part_id, path)
  local ok, job = pcall(vim.system, { os.getenv 'LIVEQ_NOTMUCH' or 'notmuch', 'show', '--format=raw', '--part=' .. part_id, 'id:' .. message_id })
  if not ok then
    return false
  end
  local result = job:wait(30000)
  local file = result.code == 0 and io.open(path, 'wb')
  if not file then
    return false
  end
  file:write(result.stdout or '')
  file:close()
  return true
end

--- The body of a message as HTML: its HTML parts (the HTML alternative when there is one), its other text parts as
--- preformatted text; inline images (`cid:` links) are saved into `dir` and linked from there.
local function message_html(message, dir)
  local bodies, attachments, cids = {}, {}, {}
  local function walk(part)
    if type(part) ~= 'table' then
      return
    end
    local ctype = (part['content-type'] or ''):lower()
    if part['content-id'] then
      cids[part['content-id']:gsub('^<', ''):gsub('>$', '')] = part
    end
    if type(part.content) == 'table' then
      if ctype == 'multipart/alternative' then
        -- the richest alternative: an HTML one if any, else the last
        local chosen
        for _, child in ipairs(part.content) do
          local cct = (child['content-type'] or ''):lower()
          if cct == 'text/html' or (cct:match '^multipart/' and vim.inspect(child):find('text/html', 1, true)) then
            chosen = child
          end
        end
        walk(chosen or part.content[#part.content])
      else
        for _, child in ipairs(part.content) do
          walk(child)
        end
      end
    elseif ctype == 'text/html' and type(part.content) == 'string' and not part.filename then
      table.insert(bodies, html_fragment(part.content))
    elseif ctype == 'text/plain' and type(part.content) == 'string' and not part.filename then
      table.insert(bodies, '<pre class="plain">' .. escape_html(part.content) .. '</pre>')
    elseif part.filename and not part['content-id'] then
      table.insert(attachments, ('%s (%s)'):format(part.filename, ctype))
    end
  end
  for _, part in ipairs(message.body or {}) do
    walk(part)
  end
  local html = table.concat(bodies, '\n<hr class="part">\n')
  -- the inline images that the HTML refers to, saved next to the page
  html = html:gsub('([Cc][Ii][Dd]:)([^"\'%s>)]+)', function(prefix, cid)
    local part = cids[vim.uri_decode(cid)]
    if not part then
      return prefix .. cid
    end
    local name = ('%s-%s'):format(message.id:gsub('[^%w]', '_'):sub(1, 40), part.id)
    local ext = (part.filename or ''):match '(%.%w+)$' or ('.' .. ((part['content-type'] or ''):match '/(%w+)' or 'bin'))
    local path = vim.fs.joinpath(dir, name .. ext)
    if vim.uv.fs_stat(path) or save_part(message.id, part.id, path) then
      return vim.uri_from_fname(path)
    end
    return prefix .. cid
  end)
  return html, attachments
end

local PAGE_STYLE = [[
body { font-family: -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 1100px; padding: 16px; }
.message { border: 1px solid #ccc; border-radius: 6px; margin: 0 0 24px; padding: 0 16px 16px; overflow-x: auto; }
.headers { background: #f4f4f4; margin: 0 -16px 16px; padding: 10px 16px; font-size: 13px; border-bottom: 1px solid #ddd; }
.headers th { text-align: right; color: #666; font-weight: normal; padding-right: 8px; vertical-align: top; white-space: nowrap; }
pre.plain { white-space: pre-wrap; font-family: ui-monospace, Menlo, monospace; font-size: 13px; }
hr.part { border: 0; border-top: 1px dashed #ccc; }
]]

--- Writes the thread as an HTML page into a new temporary directory and prints the page's path.
local function html(_, rest)
  local id = rest[1]
  if not is_item(id) then
    fail('not a thread or message id: ' .. tostring(id))
  end
  local thread, err = json { 'show', '--format=json', '--entire-thread=true', '--include-html', item_query(id) }
  if not thread then
    fail(err)
  end
  local messages = thread_messages(thread) -- newest first, as in the preview
  if #messages == 0 then
    fail('no message in ' .. id)
  end

  -- not vim.fn.tempname(): that directory is deleted when this `nvim -l` exits, before the browser reads the page
  local tmp = (os.getenv 'TMPDIR' or '/tmp'):gsub('/$', '')
  local dir = vim.uv.fs_mkdtemp(tmp .. '/liveq-mail-XXXXXX')
  if not dir then
    fail('cannot create a directory in ' .. tmp)
  end

  local subject = (messages[#messages].headers or {}).Subject or ''
  for _, m in ipairs(messages) do
    if m.liveq_index == 1 then
      subject = (m.headers or {}).Subject or subject
    end
  end
  local page = {
    '<!doctype html><html><head><meta charset="utf-8">',
    '<title>' .. escape_html(subject) .. '</title>',
    '<style>' .. PAGE_STYLE .. '</style></head><body>',
  }
  for _, m in ipairs(messages) do
    local h = m.headers or {}
    local body, attachments = message_html(m, dir)
    table.insert(page, '<div class="message"><table class="headers">')
    for _, header in ipairs { 'From', 'To', 'Cc', 'Date', 'Subject' } do
      if h[header] and h[header] ~= '' then
        table.insert(page, ('<tr><th>%s</th><td>%s</td></tr>'):format(header, escape_html(h[header])))
      end
    end
    if #attachments > 0 then
      table.insert(page, ('<tr><th>Attachments</th><td>%s</td></tr>'):format(escape_html(table.concat(attachments, ', '))))
    end
    table.insert(page, '</table>')
    table.insert(page, body ~= '' and body or '<p><i>(no text part)</i></p>')
    table.insert(page, '</div>')
  end
  table.insert(page, '</body></html>')

  local path = vim.fs.joinpath(dir, 'index.html')
  local file = io.open(path, 'w')
  if not file then
    fail('cannot write ' .. path)
  end
  file:write(table.concat(page, '\n'))
  file:close()
  out(path)
end

-- -- complete -----------------------------------------------------------------------------------------------------

local function candidate(display, insert, kind, detail)
  return { display = display, insert = insert, cursor_offset = vim.fn.strchars(insert), kind = kind, detail = detail or '' }
end

local function quote(value)
  if value:find '[%s()"]' then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

local function matching(values, typed)
  typed = typed:lower()
  local result = {}
  for _, v in ipairs(values) do
    if typed == '' or v:lower():find(typed, 1, true) then
      table.insert(result, v)
      if #result >= MAX_CANDIDATES then
        break
      end
    end
  end
  return result
end

local function lines_of(stdout)
  return vim.split(vim.trim(stdout or ''), '\n', { plain = true, trimempty = true })
end

local function folders()
  local root = notmuch { 'config', 'get', 'database.mail_root' }
  root = root and vim.trim(root) or ''
  if root == '' then
    return {}
  end
  local result = {}
  for name, kind in vim.fs.dir(root, { depth = 3 }) do
    if kind == 'directory' and name:match '/cur$' then
      table.insert(result, name:sub(1, -5))
    elseif kind == 'directory' and name == 'cur' then
      table.insert(result, '""')
    end
  end
  table.sort(result)
  return result
end

local function addresses(direction, typed)
  -- with nothing typed, the people of the last months rather than every address of a large mailbox
  local query = 'date:6M..'
  if typed:match '^[%w._@+-]+$' then
    -- a prefix of a name or an address: notmuch matches whole words unless the term ends with a wildcard
    query = direction .. ':' .. typed .. '*'
  elseif typed ~= '' then
    query = direction .. ':' .. quote(typed)
  end
  local output = direction == 'to' and 'recipients' or 'sender'
  local data = json { 'address', '--format=json', '--output=' .. output, '--deduplicate=address', query } or {}
  local result = {}
  for _, a in ipairs(data) do
    if a.address then
      table.insert(result, { address = a.address, name = a.name or '' })
      if #result >= MAX_CANDIDATES then
        break
      end
    end
  end
  return result
end

local function saved_queries()
  local result = {}
  for _, line in ipairs(lines_of(notmuch { 'config', 'list' })) do
    local name, query = line:match '^query%.([^=]+)=(.*)$'
    if name then
      table.insert(result, { name = name, query = query })
    end
  end
  return result
end

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
  local before = vim.fn.strcharpart(text, 0, cursor)
  -- the term being typed: back to the last unquoted space or parenthesis
  local start = cursor
  local in_quote = false
  for i = cursor, 1, -1 do
    local ch = vim.fn.strcharpart(before, i - 1, 1)
    if ch == '"' then
      in_quote = not in_quote
    elseif not in_quote and (ch:match '%s' or ch == '(' or ch == ')') then
      break
    end
    start = i - 1
  end
  local finish = cursor
  local length = vim.fn.strchars(text)
  while finish < length and not vim.fn.strcharpart(text, finish, 1):match '[%s()]' do
    finish = finish + 1
  end
  local term = vim.fn.strcharpart(text, start, cursor - start)
  local prefix, value = term:match '^([%w_]+:)(.*)$'
  value = value and value:gsub('^"', '') or nil

  local context, candidates = 'field', {}
  if not prefix then
    for _, p in ipairs(PREFIXES) do
      if term == '' or p[1]:sub(1, #term):lower() == term:lower() then
        table.insert(candidates, { display = p[1], insert = p[1], cursor_offset = #p[1], kind = 'field', detail = p[2] })
      end
    end
    for _, k in ipairs(KEYWORDS) do
      if term ~= '' and k:sub(1, #term) == term:lower() then
        table.insert(candidates, candidate(k, k .. ' ', 'keyword'))
      end
    end
  else
    context = 'value'
    local p = prefix:lower()
    if p == 'tag:' or p == 'is:' then
      for _, tag in ipairs(matching(lines_of(notmuch { 'search', '--output=tags', '*' }), value)) do
        table.insert(candidates, candidate(tag, p .. quote(tag) .. ' ', 'value'))
      end
    elseif p == 'from:' or p == 'to:' then
      for _, a in ipairs(addresses(p:sub(1, -2), value)) do
        table.insert(candidates, candidate(a.address, p .. a.address .. ' ', 'value', a.name))
      end
    elseif p == 'date:' then
      for _, d in ipairs(matching(DATES, value)) do
        table.insert(candidates, candidate(d, p .. d .. ' ', 'value'))
      end
    elseif p == 'folder:' then
      for _, f in ipairs(matching(folders(), value)) do
        table.insert(candidates, candidate(f, p .. quote(f) .. ' ', 'value'))
      end
    elseif p == 'mimetype:' then
      for _, m in ipairs(matching(MIMETYPES, value)) do
        table.insert(candidates, candidate(m, p .. m .. ' ', 'value'))
      end
    elseif p == 'query:' then
      for _, q in ipairs(saved_queries()) do
        if value == '' or q.name:lower():find(value:lower(), 1, true) then
          table.insert(candidates, candidate(q.name, p .. q.name .. ' ', 'value', q.query))
        end
      end
    end
  end
  out(vim.json.encode {
    context = context,
    prefix = term,
    replace_start = start,
    replace_end = finish,
    candidates = candidates,
  })
end

-- -- url, saved, save, tag ----------------------------------------------------------------------------------------

--- A link to the thread's first message, from the template in $LIVEQ_MAIL_URL (`%s` is the message id, URL-encoded);
--- e.g. `https://mail.google.com/mail/u/0/#search/rfc822msgid%%3A%s`. Prints nothing without a template.
local function url(_, rest)
  local id = rest[1]
  local template = os.getenv 'LIVEQ_MAIL_URL'
  if not is_item(id) or not template or template == '' then
    return
  end
  local first = is_thread(id) and lines_of(notmuch { 'search', '--output=messages', '--sort=oldest-first', '--limit=1', id })[1] or id
  if not first then
    fail('no message in ' .. id)
  end
  out((template:gsub('%%s', (vim.uri_encode(first:gsub('^id:', ''), 'rfc3986'):gsub('%%', '%%%%')))))
end

local function saved()
  for _, q in ipairs(saved_queries()) do
    out(('%s\t%s\t%s\tnotmuch'):format(q.name, q.query, q.name))
  end
end

local function save(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  if query == '' then
    fail 'a query is required'
  end
  local label = opts.label or opts.l
  if not label then
    io.stderr:write('Saving: ' .. query .. '\nName: ')
    local tty = io.open('/dev/tty', 'r')
    label = tty and tty:read '*l' or nil
    if tty then
      tty:close()
    end
  end
  local name = label and label:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '') or ''
  if name == '' then
    fail 'a name is required'
  end
  local ok, err = notmuch { 'config', 'set', 'query.' .. name, query }
  if not ok then
    fail(err)
  end
  io.stderr:write(('Saved as query:%s\n'):format(name))
end

local function tag(_, rest)
  local changes = vim.split(rest[1] or '', '%s+', { trimempty = true })
  local ids = vim.tbl_map(item_query, vim.tbl_filter(is_item, vim.list_slice(rest, 2)))
  if #changes == 0 or #ids == 0 then
    fail "usage: tag -- '+add -remove' thread:ID|id:MESSAGE-ID..."
  end
  local args = { 'tag' }
  vim.list_extend(args, changes)
  table.insert(args, '--')
  table.insert(args, table.concat(ids, ' or '))
  local ok, err = notmuch(args)
  if not ok then
    fail(err)
  end
end

-- -- images ---------------------------------------------------------------------------------------------------------

--- `images -f fzf -- ITEM`: a row per image of the thread (of the message, for `id:`), inline (`cid:`) or attached,
--- newest message first: `MSGID#PART \t date sender: name — subject \t\t title`. Nothing is extracted until
--- `image` shows one.
local function images_of(_, rest)
  local id = rest[1]
  if not is_item(id) then
    return
  end
  -- a thread's images, or a message's (`id:`, as neomutt's gi and the threaded view's rows give)
  local whole = is_thread(id) and 'true' or 'false'
  local thread, err = json { 'show', '--format=json', '--entire-thread=' .. whole, '--body=true', item_query(id) }
  if not thread then
    fail(err)
  end
  local n = 0
  for _, m in ipairs(thread_messages(thread)) do
    local found = {}
    local function walk(part)
      if type(part) ~= 'table' then
        return
      end
      local ctype = (part['content-type'] or ''):lower()
      if ctype:match '^image/' then
        table.insert(found, part)
      elseif type(part.content) == 'table' then
        for _, child in ipairs(part.content) do
          walk(child)
        end
      end
    end
    for _, part in ipairs(m.body or {}) do
      walk(part)
    end
    local headers = m.headers or {}
    for i, part in ipairs(found) do
      n = n + 1
      local name = part.filename or ('inline ' .. (part['content-type'] or 'image'))
      local display = ('\27[2m%s\27[0m  \27[36m%s\27[0m  %s%s  \27[2m%s\27[0m'):format(
        os.date('%Y-%m-%d %H:%M', m.timestamp or 0),
        truncate(sender_name(headers.From or ''), 24),
        #found > 1 and ('\27[33m%d/%d\27[0m '):format(i, #found) or '',
        name,
        truncate(headers.Subject or '', 60)
      )
      out(table.concat({ m.id .. '#' .. part.id, display, '', (headers.Subject or '') .. ' — ' .. name }, '\t'))
    end
  end
  if n == 0 then
    out(('\t\27[2mNo images in this %s\27[0m\t\t'):format(is_thread(id) and 'thread' or 'message'))
  end
end

--- `image [--copy | --open] -- MSGID#PART`: an image of `images`, extracted from the mail into the cache once, then
--- drawn as large as fzf's preview, or put on the clipboard as PNG, or opened in the image viewer.
local function image(opts, rest)
  local msgid, part = (rest[1] or ''):match '^(.+)#(%d+)$'
  if not msgid then
    return -- e.g. a hint line
  end
  vim.fn.mkdir(IMAGE_CACHE, 'p')
  local file = IMAGE_CACHE .. '/' .. vim.fn.sha256(rest[1]):sub(1, 32)
  if not vim.uv.fs_stat(file) then
    local tmp = file .. '.' .. vim.uv.os_getpid() .. '.part'
    if not save_part(msgid, part, tmp) then
      os.remove(tmp)
      fail('could not extract part ' .. part .. ' of ' .. msgid)
    end
    os.rename(tmp, file)
  end
  if opts.copy then
    local ok, why = Img.copy(file)
    if not ok then
      fail(why)
    end
    io.stderr:write 'Image copied to the clipboard\n'
  elseif opts.open then
    Img.open(file)
  else
    out(table.concat(Img.draw_big(file), '\n'))
  end
end

local commands = {
  search = search,
  show = show,
  terms = terms,
  html = html,
  complete = complete,
  url = url,
  saved = saved,
  save = save,
  tag = tag,
  images = images_of,
  image = image,
}
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
