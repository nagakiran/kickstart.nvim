-- The notmuch backend of liveq, run with `nvim -l` (no plugins, no user config):
--
--   nvim -l notmuch.lua search -f fzf -l LIMIT -- QUERY
--   nvim -l notmuch.lua show [--plain] [--fold] -- thread:ID
--   nvim -l notmuch.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l notmuch.lua url -- thread:ID                     a link to the thread, from the $LIVEQ_MAIL_URL template
--   nvim -l notmuch.lua html -- thread:ID                    writes the thread as an HTML page in $TMPDIR; prints its path
--   nvim -l notmuch.lua saved -f tsv                         notmuch's named queries (query.NAME in its config)
--   nvim -l notmuch.lua save [--label NAME] -- QUERY         adds a named query; usable as `query:NAME` anywhere
--   nvim -l notmuch.lua tag -- '+a -b' thread:ID...          changes the tags of threads
--
-- Items are threads. The mailbox is the one notmuch is configured for, so a source picks it with $NOTMUCH_CONFIG.
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

local function out(text)
  io.stdout:write(text, '\n')
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
    elseif a == '--plain' or a == '--fold' then
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
local function message_text(message)
  local texts, htmls, html_parts, attachments = {}, {}, {}, {}
  local function walk(part)
    if type(part) ~= 'table' then
      return
    end
    local ctype = (part['content-type'] or ''):lower()
    if part.filename then
      table.insert(attachments, ('%s (%s)'):format(part.filename, ctype))
    elseif ctype == 'text/plain' and type(part.content) == 'string' then
      table.insert(texts, part.content)
    elseif ctype == 'text/html' and type(part.content) == 'string' then
      table.insert(html_parts, part.content)
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
    attachments
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
    for _, child in ipairs(node) do
      collect(child)
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

--- The thread as text, newest message first. `--plain`: Markdown for the float, without colours. `--fold`: without
--- the quoted history of each reply (alt-h in the picker).
local function show(opts, rest)
  local id = rest[1]
  if not is_thread(id) then
    return -- e.g. a hint line of fzf
  end
  local thread, err = json { 'show', '--format=json', '--entire-thread=true', '--include-html', id }
  if not thread then
    fail(err)
  end
  local plain = opts.plain
  local bold, dim, reset = '\27[1m', '\27[2m', '\27[0m'
  if plain then
    bold, dim, reset = '', '', ''
  end
  local messages = thread_messages(thread)
  local width = text_width()
  -- start rendering every message (w3m runs in parallel) before printing the first
  local bodies = {}
  for i, m in ipairs(messages) do
    local text, attachments = message_text(m)
    bodies[i] = { text = text, attachments = attachments }
  end
  local subject
  for _, m in ipairs(messages) do
    if m.liveq_index == 1 then
      subject = (m.headers or {}).Subject
    end
  end
  out((plain and '# ' or '') .. bold .. (subject or (messages[1] and messages[1].headers or {}).Subject or '') .. reset)
  for i, m in ipairs(messages) do
    local h = m.headers or {}
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
    local text = bodies[i].text()
    if opts.fold then
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
  if not is_thread(id) then
    fail('not a thread id: ' .. tostring(id))
  end
  local thread, err = json { 'show', '--format=json', '--entire-thread=true', '--include-html', id }
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
  if not is_thread(id) or not template or template == '' then
    return
  end
  local first = lines_of(notmuch { 'search', '--output=messages', '--sort=oldest-first', '--limit=1', id })[1]
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
  local ids = vim.tbl_filter(is_thread, vim.list_slice(rest, 2))
  if #changes == 0 or #ids == 0 then
    fail "usage: tag -- '+add -remove' thread:ID..."
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

local commands = { search = search, show = show, html = html, complete = complete, url = url, saved = saved, save = save, tag = tag }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
