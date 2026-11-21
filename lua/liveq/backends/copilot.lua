-- The copilot-api usage backend of liveq, run with `nvim -l`. It reads the request log that copilot-api
-- (@jeffreycao/copilot-api, the Copilot proxy Claude Code talks to) keeps in SQLite: one row per request with its
-- time, model, client, session, tokens and cost (table `token_usage_events`). Read-only, through the `sqlite3` CLI;
-- the proxy need not be running. Its own /token-usage API answers only six fixed periods; this answers any range.
--
--   nvim -l copilot.lua search -f fzf -l LIMIT [--header] -- QUERY   a row per group (day, model, session, ...)
--   nvim -l copilot.lua show [--plain] [--match QUERY] -- ID          a group broken down (with the query's filters)
--   nvim -l copilot.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l copilot.lua terms -- QUERY                                (no words to highlight: [])
--
-- The query (all parts optional; times are local):
--   since:7d|2w|1M|2026-11-01   on:today|yesterday|3d|2026-11-05|11-05|2026-11 (a month)|11-01..11-15   since:all
--                                (default: this month)
--   model:opus  client:claude-cli  endpoint:responses  session:71f0  (a part of it; -model: etc. exclude)
--   by:day|hour|week|month|model|session|client|endpoint   (what a row is; default day)
--   sort:time|cost|requests|tokens   (default: time for by:day/hour/week/month and session, else cost)
--   other words: a part of the model, client or session id
--
-- Ids are `KIND:KEY` (`day:2026-11-19`, `model:claude-opus-5.5`, `session:UUID`, `client:claude-cli/2.1.322`); `show`
-- breaks one down within the query's filters, which reach it through `--match` (the picker passes its query).
--
-- Environment: COPILOT_API_SQLITE_DB_PATH (as copilot-api), else ~/.local/share/copilot-api/copilot-api.sqlite.

local HOME = os.getenv 'HOME' or ''
local DB = os.getenv 'COPILOT_API_SQLITE_DB_PATH' or (HOME .. '/.local/share/copilot-api/copilot-api.sqlite')
local DAY = 24 * 3600
local UNITS = { h = 3600, d = DAY, w = 7 * DAY, M = 30 * DAY, y = 365 * DAY }
local MAX_CANDIDATES = 100

local function out(text)
  io.stdout:write(text, '\n')
end

local function fail(message, code)
  io.stderr:write('liveq-copilot: ' .. message .. '\n')
  os.exit(code or 1)
end

local function parse(args)
  local opts, rest = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--' then
      vim.list_extend(rest, vim.list_slice(args, i + 1))
      break
    elseif a == '--plain' or a == '--header' then
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

-- -- database -----------------------------------------------------------------------------------------------------

--- Runs SQL read-only; the rows as tables, or nil and an error.
local function sql(query)
  if vim.fn.executable 'sqlite3' == 0 then
    return nil, 'sqlite3 is not installed'
  end
  if not vim.uv.fs_stat(DB) then
    return nil, 'no copilot-api database at ' .. DB
  end
  local r = vim.system({ 'sqlite3', '-readonly', '-json', DB, query }, { text = true }):wait(30000)
  if r.code ~= 0 then
    return nil, vim.trim(r.stderr or '') ~= '' and vim.trim(r.stderr) or ('sqlite3 exited with ' .. tostring(r.code))
  end
  if vim.trim(r.stdout or '') == '' then
    return {}
  end
  local ok, rows = pcall(vim.json.decode, r.stdout, { luanil = { object = true, array = true } })
  if not ok or type(rows) ~= 'table' then
    return nil, 'unexpected output of sqlite3'
  end
  return rows
end

local function lit(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- A LIKE pattern for "contains s" (case-insensitive for ASCII, as LIKE is), with % _ \ escaped.
local function contains(column, s)
  return ('%s LIKE %s ESCAPE %s'):format(column, lit('%' .. s:gsub('[%%_\\]', '\\%0') .. '%'), lit '\\')
end

-- -- time ---------------------------------------------------------------------------------------------------------

local function midnight(t)
  local d = os.date('*t', t)
  return os.time { year = d.year, month = d.month, day = d.day, hour = 0 }
end

local function month_start(y, m)
  return os.time { year = y + math.floor((m - 1) / 12), month = (m - 1) % 12 + 1, day = 1, hour = 0 }
end

--- A day or a month as [start, end) seconds: 2026-11-05, 11-05, 2026-11, today, yesterday, 3d (three days ago).
local function period(v)
  local today = midnight(os.time())
  local back = v == 'today' and 0 or v == 'yesterday' and 1 or tonumber(v:match '^(%d+)d$')
  if back then
    local s = midnight(today - back * DAY + 3600) -- +1h: safe across a DST change
    return s, midnight(s + DAY + 3600)
  end
  local y, m, d = v:match '^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$'
  if not y then
    m, d = v:match '^(%d%d?)%-(%d%d?)$'
    y = m and os.date('*t').year
  end
  if y then
    local s = os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 }
    return s, midnight(s + DAY + 3600)
  end
  y, m = v:match '^(%d%d%d%d)%-(%d%d?)$'
  if y then
    return month_start(tonumber(y), tonumber(m)), month_start(tonumber(y), tonumber(m) + 1)
  end
end

--- on:VALUE as [start, end): a day, a month, or A..B (from the start of A to the end of B).
local function on_range(v)
  local a, b = v:match '^(.-)%.%.(.+)$'
  if a then
    local s = period(a)
    local _, e = period(b)
    return s and e and s, e
  end
  return period(v)
end

--- since:VALUE as a start: 7d, 2w, 1M, 12h (back from now) or a date.
local function since(v)
  local n, unit = v:match '^(%d+)([hdwMy])$'
  if n then
    return os.time() - tonumber(n) * UNITS[unit]
  end
  return (period(v))
end

-- -- query --------------------------------------------------------------------------------------------------------

local LOCAL = "datetime(created_at_ms / 1000, 'unixepoch', 'localtime')"
local CLIENT =
  "CASE WHEN user_agent = '' THEN '(none)' WHEN instr(user_agent, ' ') > 0 THEN substr(user_agent, 1, instr(user_agent, ' ') - 1) ELSE user_agent END"

-- what a row is: the SQL of its key, how its key reads, and how a key of it filters (for `show`)
local GROUPS = {
  hour = { key = "strftime('%Y-%m-%d %H:00', " .. LOCAL .. ')', time = true, width = 20 },
  day = { key = 'date(' .. LOCAL .. ')', time = true, width = 14 },
  week = { key = 'date(' .. LOCAL .. ", 'weekday 0', '-6 days')", time = true, width = 18 },
  month = { key = "strftime('%Y-%m', " .. LOCAL .. ')', time = true, width = 8 },
  model = { key = 'model', width = 20 },
  session = { key = "CASE WHEN session_id = '' THEN '(none)' ELSE session_id END", width = 10 },
  client = { key = CLIENT, width = 26 },
  endpoint = { key = 'endpoint', width = 12 },
}
local GROUP_NAMES = { 'day', 'hour', 'week', 'month', 'model', 'session', 'client', 'endpoint' }
local FILTERS = { model = 'model', client = 'user_agent', endpoint = 'endpoint', session = 'session_id' }
local SORTS = { time = true, cost = true, requests = true, tokens = true }

local function terms_of(query)
  local terms = {}
  for quoted in query:gmatch '%-?%a*:?"[^"]*"' do
    table.insert(terms, quoted)
  end
  for word in query:gsub('%-?%a*:?"[^"]*"', ' '):gmatch '%S+' do
    table.insert(terms, word)
  end
  return terms
end

--- The query as { where = {SQL...}, by, sort, start, finish, errors = {...}, label }.
local function plan(query)
  local p = { where = {}, errors = {}, by = 'day' }
  local start, finish
  for _, t in ipairs(terms_of(query or '')) do
    local negated = t:sub(1, 1) == '-' and #t > 1
    local body = negated and t:sub(2) or t
    local key, value = body:match '^(%a+):(.*)$'
    value = value and value:gsub('^"(.*)"$', '%1')
    if key and value == '' then
      -- a prefix still being typed: ignored
    elseif key == 'by' then
      if GROUPS[value] then
        p.by = value
      else
        table.insert(p.errors, 'by: ' .. table.concat(GROUP_NAMES, '|'))
      end
    elseif key == 'sort' then
      if SORTS[value] then
        p.sort = value
      else
        table.insert(p.errors, 'sort: time|cost|requests|tokens')
      end
    elseif key == 'since' then
      if value == 'all' then
        start, p.all = 0, true
      else
        start = since(value)
        if not start then
          table.insert(p.errors, 'since: 7d, 2w, 1M, 12h, a date, or all')
        end
      end
    elseif key == 'on' then
      local s, e = on_range(value)
      if s then
        start, finish = s, e
      else
        table.insert(p.errors, 'on: today, yesterday, 3d, 2026-11-05, 11-05, 2026-11, A..B')
      end
    elseif key and FILTERS[key] then
      local cond = key == 'client' and value == '(none)' and "user_agent = ''" or contains(FILTERS[key], value)
      table.insert(p.where, (negated and 'NOT ' or '') .. '(' .. cond .. ')')
    elseif key then
      table.insert(p.errors, 'unknown prefix ' .. key .. ':')
    else
      local any = '(' .. table.concat({ contains('model', body), contains('user_agent', body), contains('session_id', body) }, ' OR ') .. ')'
      table.insert(p.where, (negated and 'NOT ' or '') .. any)
    end
  end
  if not start then
    local now = os.date '*t'
    start = month_start(now.year, now.month) -- this month
    p.default_range = true
  end
  p.start, p.finish = start, finish
  table.insert(p.where, 1, 'created_at_ms >= ' .. math.floor(start * 1000))
  if finish then
    table.insert(p.where, 2, 'created_at_ms < ' .. math.floor(finish * 1000))
  end
  p.sort = p.sort or (GROUPS[p.by].time or p.by == 'session') and 'time' or 'cost'
  return p
end

local function range_label(p)
  if p.all then
    return 'all time'
  end
  local s = os.date('%Y-%m-%d', p.start)
  if p.default_range then
    return 'this month (' .. os.date('%b', p.start) .. ')'
  end
  if not p.finish then
    return 'since ' .. os.date('%Y-%m-%d %H:%M', p.start)
  end
  local e = os.date('%Y-%m-%d', p.finish - 1)
  return s == e and s or (s .. ' .. ' .. e)
end

--- The filter of a group's key, for `show`.
local function key_filter(kind, key)
  local g = GROUPS[kind]
  if not g then
    return nil
  end
  if kind == 'client' and key == '(none)' then
    return "user_agent = ''"
  elseif kind == 'client' then
    return ('(user_agent = %s OR user_agent LIKE %s)'):format(lit(key), lit(key:gsub('[%%_\\]', '\\%0') .. ' %') .. " ESCAPE '\\'")
  elseif kind == 'session' and key == '(none)' then
    return "session_id = ''"
  end
  return ('%s = %s'):format(g.key, lit(key))
end

local AGG = table.concat({
  'count(*) AS n',
  'sum(input_tokens) AS i',
  'sum(output_tokens) AS o',
  'sum(cache_read_input_tokens) AS cr',
  'sum(cache_creation_input_tokens) AS cw',
  'sum(total_tokens) AS t',
  'coalesce(sum(total_cost_nanos), 0) / 1e9 AS cost',
  'coalesce(sum(total_nano_aiu), 0) / 1e9 AS aiu',
  'min(created_at_ms) AS first',
  'max(created_at_ms) AS last',
  'count(DISTINCT session_id) AS sessions',
  'group_concat(DISTINCT model) AS models',
  'group_concat(DISTINCT ' .. CLIENT .. ') AS clients',
}, ', ')

local ORDER = { time = 'last DESC', cost = 'cost DESC', requests = 'n DESC', tokens = 't DESC' }

local function grouped(where, by, sort)
  local g = GROUPS[by]
  local order = (sort == 'time' and g.time) and 'k DESC' or ORDER[sort] or 'cost DESC'
  return sql(('SELECT %s AS k, %s FROM token_usage_events WHERE %s GROUP BY k ORDER BY %s'):format(g.key, AGG, table.concat(where, ' AND '), order))
end

-- -- formatting ---------------------------------------------------------------------------------------------------

local function human(n)
  n = tonumber(n) or 0
  if n >= 1e9 then
    return ('%.1fB'):format(n / 1e9)
  elseif n >= 1e6 then
    return ('%.1fM'):format(n / 1e6)
  elseif n >= 1e4 then
    return ('%.0fk'):format(n / 1e3)
  elseif n >= 1e3 then
    return ('%.1fk'):format(n / 1e3)
  end
  return tostring(math.floor(n))
end

local function money(x)
  x = tonumber(x) or 0
  return x >= 100 and ('$%.0f'):format(x) or ('$%.2f'):format(x)
end

local function pad(s, w)
  s = tostring(s or '')
  local n = vim.fn.strdisplaywidth(s)
  if n > w then
    return vim.fn.strcharpart(s, 0, w - 1) .. '…'
  end
  return s .. (' '):rep(w - n)
end

local function lpad(s, w)
  s = tostring(s or '')
  return (' '):rep(math.max(0, w - vim.fn.strdisplaywidth(s))) .. s
end

local function short_model(m)
  return (m or ''):gsub('^claude%-', '')
end

local function key_label(by, k)
  if by == 'day' then
    local y, m, d = k:match '^(%d+)-(%d+)-(%d+)$'
    return y and os.date('%a %Y-%m-%d', os.time { year = y, month = m, day = d, hour = 12 }) or k
  elseif by == 'week' then
    local y, m, d = k:match '^(%d+)-(%d+)-(%d+)$'
    return y and os.date('%Y-%m-%d W%V', os.time { year = y, month = m, day = d, hour = 12 }) or k
  elseif by == 'hour' then
    local y, m, d, h = k:match '^(%d+)-(%d+)-(%d+) (%d+)'
    return y and os.date('%a %m-%d %H:00', os.time { year = y, month = m, day = d, hour = h }) or k
  end
  return k
end

local NUMS = { { 'req', 6 }, { 'input', 7 }, { 'output', 7 }, { 'cache rd', 8 }, { 'cache wr', 8 }, { 'cost', 8 }, { 'credits', 8 } }

local function numbers(r)
  local v = { human(r.n), human(r.i), human(r.o), human(r.cr), human(r.cw), money(r.cost), human(r.aiu) }
  local cells = {}
  for j, c in ipairs(NUMS) do
    table.insert(cells, lpad(v[j], c[2]))
  end
  return table.concat(cells, ' ')
end

local function headings()
  local cells = {}
  for _, c in ipairs(NUMS) do
    table.insert(cells, lpad(c[1], c[2]))
  end
  return table.concat(cells, ' ')
end

--- What follows the numbers in a row: the models of a time or client row, the span and client of a session.
local function extra(by, r)
  local models = table.concat(vim.tbl_map(short_model, vim.split(r.models or '', ',', { trimempty = true })), ' ')
  if by == 'session' then
    local first, last = math.floor((r.first or 0) / 1000), math.floor((r.last or 0) / 1000)
    local mins = math.floor((last - first) / 60)
    return ('%s %s  %s  %s'):format(
      os.date('%m-%d %H:%M', first),
      mins >= 60 and ('%dh%02dm'):format(math.floor(mins / 60), mins % 60) or (mins .. 'm'),
      r.clients or '',
      models
    )
  elseif by == 'model' then
    return ('%d session%s'):format(r.sessions or 0, r.sessions == 1 and '' or 's')
  end
  return models
end

local function clean(s)
  return ((s or ''):gsub('[\t\r\n]+', ' '))
end

-- -- search -------------------------------------------------------------------------------------------------------

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local limit = tonumber(opts.l or opts.limit) or 300
  local p = plan(query)
  local g = GROUPS[p.by]
  if opts.header then
    out(
      ('\t\27[1m%s %s  %s\27[0m\t\t'):format(
        pad(p.by, g.width),
        headings(),
        p.by == 'session' and 'start, length, client, models' or p.by == 'model' and 'sessions' or 'models'
      )
    )
  end
  if #p.errors > 0 then
    out('\t\27[31m' .. clean(table.concat(p.errors, '; ')) .. '\27[0m\t\t')
    return
  end
  local rows, err = grouped(p.where, p.by, p.sort)
  if not rows then
    out('\t\27[31m' .. clean(err) .. '\27[0m\t\t')
    return
  end
  local total, terr = sql(('SELECT %s FROM token_usage_events WHERE %s'):format(AGG, table.concat(p.where, ' AND ')))
  total = not terr and total[1] or {}
  out(
    ('\t\27[33m%s %s\27[0m  \27[2m%s · %d rows · by:%s sort:%s\27[0m\t\t'):format(pad('Total', g.width), numbers(total), range_label(p), #rows, p.by, p.sort)
  )
  if #rows == 0 then
    out '\t\27[33mNo requests match\27[0m\t\t'
  end
  for i = 1, math.min(#rows, limit) do
    local r = rows[i]
    local label = p.by == 'session' and r.k:sub(1, 8) or key_label(p.by, r.k) -- a session by the start of its id, as Claude Code's
    local display = ('\27[1m%s\27[0m %s  \27[2m%s\27[0m'):format(pad(label, g.width), numbers(r), clean(extra(p.by, r)))
    out(('%s:%s\t%s\t\t%s'):format(p.by, clean(r.k), display, clean(('%s %s · %d req · %s'):format(p.by, label, r.n, money(r.cost)))))
  end
end

-- -- show ---------------------------------------------------------------------------------------------------------

local function show(opts, rest)
  local id = rest[1]
  local kind, key = (id or ''):match '^(%a+):(.+)$'
  local filter = kind and key_filter(kind, key)
  if not filter then
    return -- e.g. a hint line of fzf
  end
  local p = plan(opts.match or '')
  local where = vim.deepcopy(p.where)
  if GROUPS[kind].time then
    -- a time row stands for its own time: the range of the query does not cut it
    where = vim.tbl_filter(function(w)
      return not w:match '^created_at_ms'
    end, where)
  end
  table.insert(where, filter)
  local plain = opts.plain
  local bold, dim, yellow, reset = '\27[1m', '\27[2m', '\27[33m', '\27[0m'
  if plain then
    bold, dim, yellow, reset = '', '', '', ''
  end
  local lines = {}
  local function add(s)
    table.insert(lines, s)
  end
  local function heading(s)
    add ''
    add(plain and ('## ' .. s) or (bold .. s .. reset))
  end
  local total, err = sql(('SELECT %s FROM token_usage_events WHERE %s'):format(AGG, table.concat(where, ' AND ')))
  if not total then
    out(err)
    return
  end
  total = total[1] or {}
  local title = ('%s %s'):format(kind, key_label(kind, key))
  add(plain and ('# ' .. title) or (bold .. title .. reset))
  -- the query's filters that apply (by: and sort: only arrange the rows)
  local filters = vim.tbl_filter(function(t)
    return not t:match '^%-?by:' and not t:match '^%-?sort:'
  end, terms_of(opts.match or ''))
  local scope = #filters > 0 and ('within `' .. table.concat(filters, ' ') .. '`') or ''
  if total.n and total.n > 0 then
    add(
      ('%s%s → %s%s  %s'):format(
        dim,
        os.date('%Y-%m-%d %H:%M', math.floor(total.first / 1000)),
        os.date('%Y-%m-%d %H:%M', math.floor(total.last / 1000)),
        reset,
        scope
      )
    )
  end
  if plain then
    add ''
    add '```'
  end
  local w = 20
  add(('%s%s %s%s'):format(dim, pad('', w), headings(), reset))
  add(('%s%s %s%s'):format(yellow, pad('Total', w), numbers(total), reset))
  if plain then
    add '```'
  end
  -- the breakdowns: by model, and by day or by hour, client and session as fits the kind
  local breakdowns = { 'model' }
  if kind == 'day' then
    vim.list_extend(breakdowns, { 'hour', 'session', 'client' })
  elseif kind == 'hour' then
    vim.list_extend(breakdowns, { 'session' })
  elseif kind == 'session' then
    vim.list_extend(breakdowns, { 'hour' })
  else
    vim.list_extend(breakdowns, { 'day', 'session' })
  end
  for _, by in ipairs(breakdowns) do
    if by ~= kind then
      local rows = grouped(where, by, GROUPS[by].time and 'time' or 'cost') or {}
      if #rows > 1 or (#rows == 1 and by == 'model') then
        heading(('By %s (%d)'):format(by, #rows))
        if plain then
          add '```'
        end
        local shown = by == 'session' and 15 or 60
        for i = 1, math.min(#rows, shown) do
          local r = rows[i]
          local label = by == 'session' and r.k:sub(1, 8) or by == 'model' and short_model(r.k) or key_label(by, r.k)
          local more = by == 'session' and extra('session', r) or by == 'model' and '' or extra(by, r)
          add(('%s %s  %s%s%s'):format(pad(label, w), numbers(r), dim, clean(more), reset))
        end
        if #rows > shown then
          add(('%s… %d more%s'):format(dim, #rows - shown, reset))
        end
        if plain then
          add '```'
        end
      end
    end
  end
  -- a session's (or an hour's) requests, one by one
  if (kind == 'session' or kind == 'hour') and (total.n or 0) > 0 then
    local events = sql(
      ('SELECT created_at_ms, model, endpoint, input_tokens AS i, output_tokens AS o, cache_read_input_tokens AS cr, cache_creation_input_tokens AS cw, coalesce(total_cost_nanos, 0) / 1e9 AS cost, coalesce(total_nano_aiu, 0) / 1e9 AS aiu FROM token_usage_events WHERE %s ORDER BY created_at_ms DESC LIMIT 300'):format(
        table.concat(where, ' AND ')
      )
    ) or {}
    heading(('Requests (%d%s), newest first'):format(total.n, total.n > #events and (', the last ' .. #events) or ''))
    if plain then
      add '```'
    end
    for _, e in ipairs(events) do
      e.n = 1
      add(
        ('%s %s  %s%s %s%s'):format(
          pad(os.date('%m-%d %H:%M:%S', math.floor(e.created_at_ms / 1000)), w),
          numbers(e),
          dim,
          short_model(e.model),
          e.endpoint,
          reset
        )
      )
    end
    if plain then
      add '```'
    end
  end
  out(table.concat(lines, '\n'))
end

-- -- complete -----------------------------------------------------------------------------------------------------

local PREFIXES = {
  { 'by:', 'what a row is: day hour week month model session client endpoint' },
  { 'since:', 'from: 7d 2w 1M 12h, a date, or all' },
  { 'on:', 'a day, a month or a range: today yesterday 3d 2026-11-05 2026-11 11-01..11-15' },
  { 'model:', 'a part of the model' },
  { 'client:', 'a part of the client (user agent)' },
  { 'endpoint:', 'messages, responses, ...' },
  { 'session:', 'a part of the session id' },
  { 'sort:', 'time cost requests tokens' },
  { '-model:', 'without the model' },
  { '-client:', 'without the client' },
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
  local context, candidates = 'field', {}
  local function add(insert, detail)
    table.insert(candidates, { display = insert, insert = insert .. ' ', cursor_offset = vim.fn.strchars(insert) + 1, kind = 'value', detail = detail or '' })
  end
  local sign, key, value = term:match '^(%-?)(%a+):(.*)$'
  if key then
    context = 'value'
    local fixed = {
      by = GROUP_NAMES,
      sort = { 'time', 'cost', 'requests', 'tokens' },
      since = { '12h', '1d', '7d', '2w', '1M', '3M', 'all' },
      on = { 'today', 'yesterday', '2d', '3d', os.date '%Y-%m', os.date('%Y-%m', month_start(os.date('*t').year, os.date('*t').month - 1)) },
    }
    if fixed[key] then
      for _, v in ipairs(fixed[key]) do
        if v:sub(1, #value) == value then
          add(sign .. key .. ':' .. v)
        end
      end
    elseif FILTERS[key] then
      -- the values seen in the last 90 days, the most used first
      local column = key == 'client' and CLIENT or key == 'session' and 'session_id' or FILTERS[key]
      local rows = sql(
        ('SELECT %s AS v, count(*) AS n, max(created_at_ms) AS last FROM token_usage_events WHERE created_at_ms >= %d AND %s GROUP BY v ORDER BY %s LIMIT %d'):format(
          column,
          (os.time() - 90 * DAY) * 1000,
          value == '' and '1' or contains(column, value),
          key == 'session' and 'last DESC' or 'n DESC',
          MAX_CANDIDATES
        )
      ) or {}
      for _, r in ipairs(rows) do
        if r.v and r.v ~= '' then
          add(
            sign .. key .. ':' .. (r.v:find '%s' and ('"' .. r.v .. '"') or r.v),
            ('%d requests, last %s'):format(r.n, os.date('%m-%d', math.floor(r.last / 1000)))
          )
        end
      end
    end
  elseif term == '' or term:match '^%-?%a*$' then
    for _, p in ipairs(PREFIXES) do
      if p[1]:sub(1, #term) == term and p[1] ~= term then
        table.insert(candidates, { display = p[1], insert = p[1], cursor_offset = vim.fn.strchars(p[1]), kind = 'field', detail = p[2] })
      end
    end
  end
  out(vim.json.encode { context = context, prefix = term, replace_start = start, replace_end = finish, candidates = candidates })
end

local function terms()
  out '[]'
end

local commands = { search = search, show = show, complete = complete, terms = terms }
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
