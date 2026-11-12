-- The notmuch backend of liveq, run with `nvim -l` (no plugins, no user config):
--
--   nvim -l notmuch.lua search -f fzf -l LIMIT -- QUERY
--   nvim -l notmuch.lua show [--plain] -- thread:ID
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
    elseif a == '--plain' then
      opts.plain = true
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

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local fzf = opts.f == 'fzf' or opts.format == 'fzf'
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

--- The text of an HTML part, without its markup.
local function html_to_text(html)
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

--- The text of a message: its text/plain parts, or its text/html ones without the markup; and its attachments.
local function message_text(message)
  local texts, htmls, attachments = {}, {}, {}
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
      table.insert(htmls, html_to_text(part.content))
    elseif type(part.content) == 'table' then
      for _, child in ipairs(part.content) do
        walk(child)
      end
    end
  end
  for _, part in ipairs(message.body or {}) do
    walk(part)
  end
  return vim.trim(table.concat(#texts > 0 and texts or htmls, '\n')), attachments
end

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
  local messages = {}
  local function collect(node)
    -- a thread is a forest: lists of [message, replies]
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
  for index, m in ipairs(messages) do
    local h = m.headers or {}
    if index == 1 then
      out((plain and '# ' or '') .. bold .. (h.Subject or '') .. reset)
    end
    out(((plain and '## ' or '') .. '%s%s%s  %s%s%s'):format(bold, h.From or '', reset, dim, h.Date or '', reset))
    for _, header in ipairs { 'To', 'Cc' } do
      if h[header] then
        out(('%s%s:%s %s'):format(dim, header, reset, h[header]))
      end
    end
    if m.tags and #m.tags > 0 then
      out(('%sTags:%s %s'):format(dim, reset, table.concat(m.tags, ' ')))
    end
    local text, attachments = message_text(m)
    for _, a in ipairs(attachments) do
      out(('%sAttachment:%s %s'):format(dim, reset, a))
    end
    out ''
    out(text ~= '' and text or (dim .. '(no text part)' .. reset))
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
  if #messages == 0 then
    fail('no message in ' .. id)
  end

  -- not vim.fn.tempname(): that directory is deleted when this `nvim -l` exits, before the browser reads the page
  local tmp = (os.getenv 'TMPDIR' or '/tmp'):gsub('/$', '')
  local dir = vim.uv.fs_mkdtemp(tmp .. '/liveq-mail-XXXXXX')
  if not dir then
    fail('cannot create a directory in ' .. tmp)
  end

  local subject = (messages[1].headers or {}).Subject or ''
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
