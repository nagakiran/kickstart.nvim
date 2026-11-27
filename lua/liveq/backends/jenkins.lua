-- The Jenkins backend of liveq, run with `nvim -l`: the builds of a chain of jobs (by default Security Director's
-- `baas-sb-build` → `sb-build` → `ems-nightly`, `fs-build`, `sb-nightly`), each build under the one that started it.
-- Jenkins' JSON API through curl; children are joined to parents by their BuildUpstreamCause, so no console is parsed.
--
--   nvim -l jenkins.lua search -f fzf -l LIMIT [--header] [--tree] -- QUERY   a row per build (tree: roots + children)
--   nvim -l jenkins.lua show [--plain] -- JOB#N        the build: params, chain, stages, history on its branch, log tail
--   nvim -l jenkins.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l jenkins.lua url -- JOB#N  ·  log -- JOB#N (the whole console)  ·  refresh [--full]  ·  terms -- QUERY
--
-- The builds are cached (~/.cache/liveq/jenkins/HOST/builds.json), so typing makes no HTTP call, and they are kept
-- after Jenkins rotates them out (sb-build keeps ~100 builds; baas-sb-build all since 2024). A search older than
-- LIVEQ_JENKINS_TTL (60s) starts a detached `refresh` (the newest 60 builds of each job; the first one fetches all of
-- them, ~20s for baas-sb-build) and waits up to 4s for it; fzf kills a reload on each keystroke, the refresh survives.
--
-- The query (all parts optional):
--   words                 a part of the branch, job or user
--   branch:X              the branch (exactly, when X is a known branch; else a part of it)   -branch:X excludes
--   job:sb-nightly        the rows are this job's builds (also its short name: nightly; a list: job:fs,ems; job:all)
--                         default: the first job of the chain; in the tree, a match lifts to its root's whole chain
--   result:success|failure|aborted|unstable|running   (a list: result:failure,aborted; -result: excludes)
--   user:X  mode:sanity  version:26.4.1  since:7d|2w|DATE  on:today|yesterday|DATE|A..B
--   per:branch            the newest matching build of each branch (per job)
--
-- Environment: LIVEQ_JENKINS_URL (https://sspt-nm-jenkins.juniper.net), LIVEQ_JENKINS_JOBS (the chain, root first,
-- space separated), LIVEQ_JENKINS_SHORT (`job=short ...`), LIVEQ_JENKINS_TTL; LIVEQ_JENKINS_USER and
-- LIVEQ_JENKINS_TOKEN (an API token) when the server needs a login, else ~/.netrc, else anonymous. The token reaches
-- curl on stdin (`-K -`), never in argv.

local HOME = os.getenv 'HOME' or ''
local URL = (os.getenv 'LIVEQ_JENKINS_URL' or 'https://sspt-nm-jenkins.juniper.net'):gsub('/+$', '')
local JOBS = vim.split(os.getenv 'LIVEQ_JENKINS_JOBS' or 'baas-sb-build sb-build ems-nightly fs-build sb-nightly', '[%s,]+', { trimempty = true })
local TTL = tonumber(os.getenv 'LIVEQ_JENKINS_TTL') or 60
local RECENT = 60 -- builds of each job a refresh fetches
local WAIT_MS = 4000 -- how long a search waits for the refresh it started
local DAY = 24 * 3600
local UNITS = { h = 3600, d = DAY, w = 7 * DAY, M = 30 * DAY, y = 365 * DAY }
local MAX_CANDIDATES = 100
local SCRIPT = vim.fn.fnamemodify(_G.arg[0] or debug.getinfo(1, 'S').source:sub(2), ':p')

local HOST = URL:match '^%a+://([^/:]+)' or 'jenkins'
local CACHE_DIR = (os.getenv 'XDG_CACHE_HOME' or (HOME .. '/.cache')) .. '/liveq/jenkins/' .. HOST
local DB_FILE = CACHE_DIR .. '/builds.json'
local LOCK = CACHE_DIR .. '/refresh.lock'
local DETAILS = CACHE_DIR .. '/details'

local JOB_ORDER = {}
for i, j in ipairs(JOBS) do
  JOB_ORDER[j] = i
end
local SHORT = { ['sb-build'] = 'sb', ['ems-nightly'] = 'ems', ['fs-build'] = 'fs', ['sb-nightly'] = 'nightly', ['baas-sb-build'] = 'baas' }
for pair in (os.getenv 'LIVEQ_JENKINS_SHORT' or ''):gmatch '%S+' do
  local k, v = pair:match '^(.-)=(.+)$'
  if k then
    SHORT[k] = v
  end
end

local function out(text)
  io.stdout:write(text, '\n')
end

local function fail(message, code)
  io.stderr:write('liveq-jenkins: ' .. message .. '\n')
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
    elseif a == '--plain' or a == '--header' or a == '--tree' or a == '--full' then
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

local function clean(s)
  return (tostring(s or ''):gsub('[\t\r\n]+', ' '))
end

local function uri(s)
  return (s:gsub('[^%w%-_.~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

local function job_path(job, n)
  return '/job/' .. uri(job) .. '/' .. (n and (n .. '/') or '')
end

-- -- http ---------------------------------------------------------------------------------------------------------

--- Starts curl on a path of the server; `extra` are more curl arguments. Returns the vim.system handle.
local function fetch(path, extra)
  local args = { 'curl', '-sS', '-g', '--fail', '--compressed', '--netrc-optional', '-m', '180' }
  local stdin
  local user, token = os.getenv 'LIVEQ_JENKINS_USER', os.getenv 'LIVEQ_JENKINS_TOKEN'
  if user and user ~= '' and token and token ~= '' then
    vim.list_extend(args, { '-K', '-' })
    stdin = ('user = "%s:%s"\n'):format(user, token)
  end
  vim.list_extend(args, extra or {})
  table.insert(args, URL .. path)
  return vim.system(args, { text = true, stdin = stdin or false })
end

local function decode(text)
  local ok, v = pcall(vim.json.decode, text or '', { luanil = { object = true, array = true } })
  return ok and v or nil
end

--- Waits for a fetch; the decoded JSON, or nil and the error.
local function json_of(handle, timeout)
  local r = handle:wait(timeout or 200000)
  if r.code ~= 0 then
    return nil, vim.trim((r.stderr or '') ~= '' and r.stderr or ('curl exit ' .. r.code))
  end
  local v = decode(r.stdout)
  if not v then
    return nil, 'not JSON (a login page?)'
  end
  return v
end

-- -- cache --------------------------------------------------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local s = f:read '*a'
  f:close()
  return s
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.' .. vim.uv.os_getpid() .. '.tmp'
  local f = assert(io.open(tmp, 'w'))
  f:write(text)
  f:close()
  os.rename(tmp, path)
end

local DB_VERSION = 2 -- 2: why a build stopped (aborted_by, cancelled, stopped)

local function load_db()
  local db = decode(read_file(DB_FILE)) or {}
  db.builds = db.builds or {}
  db.full = db.full or {}
  if (db.v or 0) < DB_VERSION then
    db.full, db.tried, db.v = {}, 0, DB_VERSION -- refetch every build for the fields a newer version keeps
  end
  return db
end

local FIELDS =
  'number,result,building,timestamp,duration,estimatedDuration,actions[causes[_class,upstreamProject,upstreamBuild,userId,shortDescription],parameters[name,value]]'

--- A build of the API as the cache keeps it: { job, n, status, ts, dur, est, branch, user, up = 'JOB#N', params,
--- aborted_by, cancelled, stopped }. Why it stopped comes from its InterruptedBuildAction: aborted_by is the user who
--- pressed abort on it (UserInterruption), cancelled that its calling pipeline was cancelled (an abort above it, or a
--- fail-fast of a sibling), stopped any other reason (a timeout). A DownstreamFailureCause only repeats a child's fail.
local function compact(job, b)
  local e = {
    job = job,
    n = b.number,
    ts = math.floor((b.timestamp or 0) / 1000),
    dur = math.floor((b.duration or 0) / 1000),
    est = b.estimatedDuration and b.estimatedDuration > 0 and math.floor(b.estimatedDuration / 1000) or nil,
    -- a running pipeline may already report a result (SUCCESS while it is still building)
    status = b.building and 'RUNNING' or b.result or 'UNKNOWN',
  }
  for _, a in ipairs(b.actions or {}) do
    for _, c in ipairs(a.causes or {}) do
      -- a cause from the job itself is a rebuild/replay, not a parent
      if c.upstreamProject and c.upstreamProject ~= job and c.upstreamBuild and not e.up then
        e.up = c.upstreamProject .. '#' .. c.upstreamBuild
      end
      if c.userId and not e.user then
        e.user = c.userId
      end
      local cls = c._class or ''
      if cls:find 'UserInterruption$' then
        e.aborted_by = e.aborted_by or (c.shortDescription or ''):match '^Aborted by (.+)$' or '?'
      elseif cls:find 'BuildTriggerCancelledCause$' then
        e.cancelled = true
      elseif cls:find 'CauseOfInterruption' or cls:find 'ExceededTimeout' then
        e.stopped = e.stopped or c.shortDescription
      end
    end
    for _, p in ipairs(a.parameters or {}) do
      if p.name == 'BRANCH' then
        e.branch = p.value
      elseif p.value ~= nil and p.value ~= false and p.value ~= '' then
        e.params = e.params or {}
        e.params[p.name] = p.value
      end
    end
  end
  return e
end

local function lock_age()
  local st = vim.uv.fs_stat(LOCK)
  return st and (os.time() - st.mtime.sec) or nil
end

--- Fetches the newest builds of every job of the chain (all of them for a job not fetched in full yet, or with
--- `full`) and merges them into the cache. Returns the errors.
local function refresh(full)
  vim.fn.mkdir(CACHE_DIR, 'p')
  local age = lock_age()
  if age and age < 300 then
    return { 'a refresh is already running' }
  end
  os.remove(LOCK)
  local fd = vim.uv.fs_open(LOCK, 'wx', 420)
  if not fd then
    return { 'a refresh is already running' }
  end
  vim.uv.fs_close(fd)
  local ok, errors = pcall(function()
    local db = load_db()
    local pending = {}
    for _, job in ipairs(JOBS) do
      local all = full or not db.full[job]
      local tree = all and ('allBuilds[%s]'):format(FIELDS) or ('builds[%s]{0,%d}'):format(FIELDS, RECENT)
      table.insert(pending, { job = job, all = all, h = fetch(job_path(job) .. 'api/json?tree=' .. tree) })
    end
    local errors = {}
    for _, p in ipairs(pending) do
      local data, err = json_of(p.h)
      if data then
        for _, b in ipairs(data.allBuilds or data.builds or {}) do
          local e = compact(p.job, b)
          db.builds[p.job .. '#' .. e.n] = e
        end
        if p.all then
          db.full[p.job] = true
        end
      else
        table.insert(errors, p.job .. ': ' .. err)
      end
    end
    db.tried = os.time()
    if #errors < #pending then
      db.fetched = os.time()
    end
    db.errors = errors
    write_file(DB_FILE, vim.json.encode(db))
    return errors
  end)
  os.remove(LOCK)
  if not ok then
    return { tostring(errors) }
  end
  return errors
end

--- The cache, refreshed first when it is older than the TTL; and a note for the user (refreshing, offline) or nil.
local function fresh_db()
  local db = load_db()
  if os.time() - (db.tried or 0) < TTL then
    return db, (db.errors and #db.errors > 0) and ('offline: ' .. db.errors[1]) or nil
  end
  local first = next(db.builds) == nil
  if not lock_age() or lock_age() >= 300 then
    pcall(vim.system, { vim.v.progpath, '-l', SCRIPT, 'refresh' }, { detach = true, stdout = false, stderr = false })
    vim.uv.sleep(50)
  end
  if first then
    return db, 'fetching the build history (the first time takes ~20s); type to reload'
  end
  -- wait for the refresh (the lock goes away), without killing it: a detached process outlives this one
  local deadline = vim.uv.now() + WAIT_MS
  while lock_age() and vim.uv.now() < deadline do
    vim.uv.sleep(100)
  end
  if lock_age() then
    return db, 'refreshing…'
  end
  return load_db()
end

-- -- the builds as a graph ----------------------------------------------------------------------------------------

local function index(db)
  local all, by_id, kids = {}, {}, {}
  for id, b in pairs(db.builds) do
    b.id = id
    table.insert(all, b)
    by_id[id] = b
  end
  for _, b in ipairs(all) do
    if b.up and by_id[b.up] then
      kids[b.up] = kids[b.up] or {}
      table.insert(kids[b.up], b)
    end
  end
  for _, list in pairs(kids) do
    table.sort(list, function(a, b)
      local oa, ob = JOB_ORDER[a.job] or 99, JOB_ORDER[b.job] or 99
      if oa ~= ob then
        return oa < ob
      end
      return a.n < b.n
    end)
  end
  table.sort(all, function(a, b)
    if a.ts ~= b.ts then
      return a.ts > b.ts
    end
    return a.id > b.id
  end)
  local function root_of(b)
    local seen = 0
    while b.up and by_id[b.up] and seen < 20 do
      b, seen = by_id[b.up], seen + 1
    end
    return b
  end
  return { all = all, by_id = by_id, kids = kids, root_of = root_of }
end

--- The build's descendants in tree order, each with its depth below it.
local function descendants(g, b, depth, acc)
  acc = acc or {}
  depth = depth or 0
  for _, k in ipairs(g.kids[b.id] or {}) do
    table.insert(acc, { b = k, depth = depth + 1 })
    descendants(g, k, depth + 1, acc)
  end
  return acc
end

local function user_of(g, b)
  local u = b.user or g.root_of(b).user
  return u and (u:gsub('@.*$', '')) or nil
end

-- -- formatting ---------------------------------------------------------------------------------------------------

local PLAIN = false

local function color(code, s)
  if PLAIN then
    return s
  end
  return ('\27[%sm%s\27[0m'):format(code, s)
end

local ICON = {
  SUCCESS = { '✔', '32' },
  FAILURE = { '✘', '31' },
  ABORTED = { '⊘', '90' },
  UNSTABLE = { '!', '33' },
  RUNNING = { '◐', '33;1' },
  NOT_BUILT = { '·', '90' },
  UNKNOWN = { '?', '90' },
}

local function icon(status)
  local i = ICON[status] or ICON.UNKNOWN
  return color(i[2], i[1])
end

local function width(s)
  return vim.fn.strdisplaywidth((s:gsub('\27%[[%d;]*m', '')))
end

local function pad(s, w)
  s = s or ''
  local n = width(s)
  if n > w then
    return vim.fn.strcharpart(s, 0, w - 1) .. '…'
  end
  return s .. (' '):rep(w - n)
end

local function lpad(s, w)
  return (' '):rep(math.max(0, w - width(s))) .. s
end

local function hms(sec)
  sec = math.max(0, math.floor(sec or 0))
  if sec < 60 then
    return sec .. 's'
  elseif sec < 3600 then
    return ('%dm%02ds'):format(math.floor(sec / 60), sec % 60)
  end
  return ('%dh%02dm'):format(math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function ago(ts)
  local d = os.time() - ts
  if d < 3600 then
    return ('%dm ago'):format(math.floor(d / 60))
  elseif d < DAY then
    return ('%dh ago'):format(math.floor(d / 3600))
  elseif d < 60 * DAY then
    return ('%dd ago'):format(math.floor(d / DAY))
  end
  return ('%dmo ago'):format(math.floor(d / (30 * DAY)))
end

local function started(ts)
  if os.date('%Y', ts) ~= os.date '%Y' then
    return os.date('%Y-%m-%d', ts)
  end
  return os.date('%m-%d %H:%M', ts)
end

local function took(b)
  if b.status == 'RUNNING' then
    return color('33', hms(os.time() - b.ts) .. '…')
  end
  return hms(b.dur)
end

local function short(job)
  return SHORT[job] or job
end

--- Who or what stopped the build: (text, user) — the user who aborted it or the build above it that cancelled it,
--- else for a fail-fast the sibling whose failure cancelled it (user nil). nil for a build nothing stopped.
local function stopper(g, b)
  if b.aborted_by then
    return b.aborted_by, b.aborted_by
  end
  if b.cancelled then
    local from, p = b, b.up and g.by_id[b.up]
    while p do
      if p.aborted_by then
        return ('%s (on %s #%d)'):format(p.aborted_by, short(p.job), p.n), p.aborted_by
      end
      if not p.cancelled then
        for _, k in ipairs(g.kids[p.id] or {}) do
          if k ~= from and (k.status == 'FAILURE' or k.status == 'UNSTABLE') then
            return ('%s #%d failed, %s #%d cancelled the rest'):format(short(k.job), k.n, short(p.job), p.n)
          end
        end
        return ('%s #%d cancelled it (%s)'):format(short(p.job), p.n, p.stopped or p.status)
      end
      from, p = p, p.up and g.by_id[p.up]
    end
    return 'its calling pipeline was cancelled'
  end
  return b.stopped
end

local function url_of(b)
  return URL .. job_path(b.job, b.n)
end

-- -- the query ----------------------------------------------------------------------------------------------------

local RESULTS = { 'success', 'failure', 'aborted', 'unstable', 'running', 'not_built' }

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

local function midnight(t)
  local d = os.date('*t', t)
  return os.time { year = d.year, month = d.month, day = d.day, hour = 0 }
end

--- A day or month as [start, finish): today, yesterday, 3d (three days ago), 2026-11-05, 11-05, 2026-11.
local function period(v)
  local today = midnight(os.time())
  if v == 'today' then
    return today, today + DAY
  elseif v == 'yesterday' then
    return today - DAY, today
  end
  local n = v:match '^(%d+)d$'
  if n then
    local s = today - tonumber(n) * DAY
    return s, s + DAY
  end
  local y, m, d = v:match '^(%d%d%d%d)-(%d%d?)-(%d%d?)$'
  if not y then
    m, d = v:match '^(%d%d?)-(%d%d?)$'
    y = m and os.date '%Y'
  end
  if y then
    local s = os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 }
    return s, s + DAY
  end
  y, m = v:match '^(%d%d%d%d)-(%d%d?)$'
  if y then
    return os.time { year = tonumber(y), month = tonumber(m), day = 1, hour = 0 }, os.time { year = tonumber(y), month = tonumber(m) + 1, day = 1, hour = 0 }
  end
end

local function since(v)
  local n, u = v:match '^(%d+)(%a)$'
  if n and UNITS[u] then
    return os.time() - tonumber(n) * UNITS[u]
  end
  return (period(v))
end

--- The job a name means: the job, its short name, or the only job containing it.
local function job_named(name)
  for _, j in ipairs(JOBS) do
    if j == name or SHORT[j] == name then
      return j
    end
  end
  local found
  for _, j in ipairs(JOBS) do
    if j:find(name, 1, true) then
      if found then
        return nil
      end
      found = j
    end
  end
  return found
end

local function lower(s)
  return (s or ''):lower()
end

--- The query as { tests = {fn(b, g)}, jobs = set|nil ('all' = every job), per, errors }.
local function plan(query, branches)
  local p = { tests = {}, errors = {} }
  local function test(negated, fn)
    table.insert(p.tests, negated and function(b, g)
      return not fn(b, g)
    end or fn)
  end
  for _, t in ipairs(terms_of(query or '')) do
    local negated = t:sub(1, 1) == '-' and #t > 1
    local body = negated and t:sub(2) or t
    local key, value = body:match '^(%a+):(.*)$'
    value = value and value:gsub('^"(.*)"$', '%1')
    if key and value == '' then
      -- a prefix still being typed: ignored
    elseif key == 'branch' then
      local v = lower(value)
      if branches[value] then
        test(negated, function(b)
          return b.branch == value
        end)
      else
        test(negated, function(b)
          return lower(b.branch):find(v, 1, true) ~= nil
        end)
      end
    elseif key == 'job' then
      if value == 'all' then
        p.jobs = 'all'
      else
        local set = {}
        for name in value:gmatch '[^,]+' do
          local j = job_named(name)
          if j then
            set[j] = true
          else
            table.insert(p.errors, 'job: no job ' .. name .. ' (' .. table.concat(JOBS, ' ') .. ', all)')
          end
        end
        if negated then
          test(false, function(b)
            return not set[b.job]
          end)
          p.jobs = 'all'
        else
          p.jobs = set
        end
      end
    elseif key == 'result' or key == 'is' then
      local set = {}
      for name in value:gmatch '[^,]+' do
        local found
        for _, r in ipairs(RESULTS) do
          if r:sub(1, #name) == lower(name) then
            found = r:upper()
            break
          end
        end
        if found then
          set[found] = true
        else
          table.insert(p.errors, 'result: ' .. table.concat(RESULTS, '|'))
        end
      end
      test(negated, function(b)
        return set[b.status]
      end)
    elseif key == 'user' then
      local v = lower(value)
      test(negated, function(b, g)
        return lower(user_of(g, b)):find(v, 1, true) ~= nil
      end)
    elseif key == 'mode' or key == 'version' then
      local param, v = key == 'mode' and 'MODE' or 'RELEASE_VERSION', lower(value)
      test(negated, function(b, g)
        local params = b.params or {}
        local r = (params[param] and params) or g.root_of(b).params or {}
        return lower(tostring(r[param] or '')):find(v, 1, true) ~= nil
      end)
    elseif key == 'since' then
      local s = since(value)
      if s then
        test(negated, function(b)
          return b.ts >= s
        end)
      else
        table.insert(p.errors, 'since: 7d 2w 1M 12h or a date')
      end
    elseif key == 'on' then
      local a, z = value:match '^(.-)%.%.(.+)$'
      local s, f
      if a then
        s = period(a)
        f = select(2, period(z))
      else
        s, f = period(value)
      end
      if s and f then
        test(negated, function(b)
          return b.ts >= s and b.ts < f
        end)
      else
        table.insert(p.errors, 'on: today yesterday 3d 2026-11-05 11-05 2026-11 or A..B')
      end
    elseif key == 'per' then
      if value == 'branch' then
        p.per = true
      else
        table.insert(p.errors, 'per: branch')
      end
    elseif key then
      table.insert(p.errors, 'unknown prefix ' .. key .. ': (branch job result user mode version since on per)')
    else
      local v = lower(body)
      test(negated, function(b, g)
        return lower(b.branch):find(v, 1, true) ~= nil or b.job:find(v, 1, true) ~= nil or lower(user_of(g, b)):find(v, 1, true) ~= nil
      end)
    end
  end
  return p
end

--- The builds matching the plan, newest first.
local function matching(g, p)
  local jobs = p.jobs or { [JOBS[1]] = true }
  local rows, seen = {}, {}
  for _, b in ipairs(g.all) do
    local ok = jobs == 'all' or jobs[b.job]
    for _, t in ipairs(p.tests) do
      if not ok then
        break
      end
      ok = t(b, g)
    end
    if ok and p.per then
      local key = b.job .. '\0' .. (b.branch or '')
      ok = not seen[key]
      seen[key] = true
    end
    if ok then
      table.insert(rows, b)
    end
  end
  return rows
end

-- -- search -------------------------------------------------------------------------------------------------------

local W = { job = 14, n = 6, branch = 44, started = 11, took = 8, user = 10 }

local function headings(tree)
  return ('  %s %s %s %s %s %s %s'):format(
    pad('job', W.job),
    lpad('#', W.n),
    pad('branch', W.branch),
    pad('started', W.started),
    lpad('took', W.took),
    pad('user', W.user),
    tree and '' or 'chain'
  )
end

--- The statuses of a build's descendants, e.g. `sb✔ ems✔ fs✔ nightly✘`.
local function chain(g, b)
  local parts = {}
  for _, d in ipairs(descendants(g, b)) do
    table.insert(parts, short(d.b.job) .. icon(d.b.status))
  end
  return table.concat(parts, ' ')
end

--- A row: `id \t display \t url \t title [\t depth]`. In the tree the branches go at \037, before the job, whose
--- column shrinks by their width (2 per level + 1) so that the columns after it stay aligned.
local function row(g, b, opts)
  local depth = opts.depth
  local job_w = W.job - (depth and depth > 0 and (2 * depth + 1) or 0)
  local dim = opts.dim
  local job = dim and color('2', pad(short(b.job), job_w)) or color('1', pad(short(b.job), job_w))
  local branch = (depth and depth > 0) and '' or (b.branch or '')
  local _, aborter = stopper(g, b)
  local tail = depth and '' or chain(g, b)
  if aborter then
    tail = tail .. (tail ~= '' and '  ' or '') .. color('31', '⊘ ' .. aborter)
  end
  local display = ('%s %s%s %s %s %s %s %s %s'):format(
    icon(b.status),
    depth and '\31' or '',
    job,
    color('36', lpad(tostring(b.n), W.n)),
    pad(branch, W.branch),
    color('2', pad(started(b.ts), W.started)),
    lpad(took(b), W.took),
    color('35', pad((depth and depth > 0) and '' or (user_of(g, b) or ''), W.user)),
    tail
  )
  if dim then
    display = display:gsub('\27%[0m', '\27[0m\27[2m')
  end
  local fields = { b.id, display, url_of(b), clean(('%s · %s'):format(b.branch or '', b.status)) }
  if depth then
    table.insert(fields, tostring(depth))
  end
  return table.concat(fields, '\t')
end

local function hint(text, code)
  out(('\t%s\t\t'):format(color(code or '33', clean(text))))
end

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local limit = tonumber(opts.l or opts.limit) or 200
  if opts.header then
    out(('\t%s\t\t'):format(color('1', headings(opts.tree))))
  end
  local db, note = fresh_db()
  local g = index(db)
  local branches = {}
  for _, b in ipairs(g.all) do
    if b.branch then
      branches[b.branch] = true
    end
  end
  local p = plan(query, branches)
  if #p.errors > 0 then
    hint(table.concat(p.errors, '; '), '31')
    return
  end
  local rows = matching(g, p)
  if note then
    hint(note)
  end
  if #rows == 0 and next(db.builds) then
    hint 'No builds match'
  end
  if not opts.tree then
    for i = 1, math.min(#rows, limit) do
      out(row(g, rows[i], {}))
    end
    return
  end
  -- the tree: each match lifted to its root, whose whole chain is shown; with job:, the builds that did not match
  -- are dimmed
  local matched, roots, seen = {}, {}, {}
  for _, b in ipairs(rows) do
    matched[b.id] = true
    local r = g.root_of(b)
    if not seen[r.id] then
      seen[r.id] = true
      table.insert(roots, r)
    end
  end
  local filtered = p.jobs ~= nil
  for i = 1, math.min(#roots, limit) do
    local r = roots[i]
    out(row(g, r, { depth = 0, dim = filtered and not matched[r.id] }))
    for _, d in ipairs(descendants(g, r)) do
      out(row(g, d.b, { depth = d.depth, dim = filtered and not matched[d.b.id] }))
    end
  end
end

-- -- show ---------------------------------------------------------------------------------------------------------

--- The last lines of a console that say something: without the pipeline's `[Pipeline]` steps.
local function tail_lines(text, count)
  local lines = {}
  for line in (text or ''):gmatch '[^\n]*' do
    line = line:gsub('\r', ''):gsub('\27%[[%d;]*m', '')
    -- the message of a Java exception says enough; its stack frames (`\tat ...`, `... 17 more`) bury the log
    local body = line:gsub('^%[[%d%-T:.Z]+%]%s?', '')
    if line ~= '' and not line:match '^%[Pipeline%]' and not body:match '^%s+at [%w_$.<>/]+%(' and not body:match '^%s*%.%.%. %d+ more$' then
      table.insert(lines, line)
    end
  end
  return vim.list_slice(lines, math.max(1, #lines - count + 1))
end

--- The build's details from the server: { build, stages, tail }, cached once the build is over.
local function details(job, n)
  local file = ('%s/%s-%d.json'):format(DETAILS, uri(job), n)
  local cached = decode(read_file(file))
  if cached then
    return cached
  end
  local hb = fetch(job_path(job, n) .. 'api/json?tree=' .. FIELDS)
  local hs = fetch(job_path(job, n) .. 'wfapi/describe')
  local hz = fetch(job_path(job, n) .. 'logText/progressiveText?start=999999999999', { '-D', '-', '-o', '/dev/null' })
  local d = {}
  local raw = json_of(hb, 30000)
  d.build = raw and compact(job, raw)
  local stages = json_of(hs, 30000)
  if stages and stages.stages then
    d.stages = {}
    for _, s in ipairs(stages.stages) do
      table.insert(
        d.stages,
        { name = vim.trim(s.name or ''), status = s.status, dur = math.floor((s.durationMillis or 0) / 1000), error = s.error and s.error.message }
      )
    end
  end
  local z = hz:wait(30000)
  local size = z.code == 0 and tonumber((z.stdout or ''):lower():match 'x%-text%-size:%s*(%d+)')
  if size and d.build and d.build.status ~= 'SUCCESS' then
    local r = fetch(job_path(job, n) .. 'logText/progressiveText?start=' .. math.max(0, size - 65536)):wait(30000)
    if r.code == 0 then
      d.tail = tail_lines(r.stdout, 40)
    end
  end
  if d.build and d.build.status ~= 'RUNNING' and d.stages then
    write_file(file, vim.json.encode(d))
  end
  return d
end

local STAGE_STATUS =
  { SUCCESS = 'SUCCESS', FAILED = 'FAILURE', ABORTED = 'ABORTED', UNSTABLE = 'UNSTABLE', IN_PROGRESS = 'RUNNING', NOT_EXECUTED = 'NOT_BUILT' }

local function show(opts, rest)
  local id = rest[1] or ''
  local job, n = id:match '^(.+)#(%d+)$'
  if not job then
    return -- e.g. a hint line of fzf
  end
  n = tonumber(n)
  PLAIN = opts.plain
  local db = load_db()
  local g = index(db)
  local d = details(job, n)
  local b = d.build or g.by_id[id]
  if not b then
    out('No build ' .. id .. (next(db.builds) and '' or ' (no cache yet)'))
    return
  end
  b.id = id
  if g.by_id[id] then
    -- keep the graph's links (children, root) with the fresh status
    for k, v in pairs(b) do
      g.by_id[id][k] = v
    end
    b = g.by_id[id]
  end
  local lines = {}
  local function add(s)
    table.insert(lines, s or '')
  end
  local function section(title)
    add ''
    add(PLAIN and ('## ' .. title) or color('1;4', title))
  end
  local function field(k, v)
    if v and v ~= '' then
      add(PLAIN and ('- **%s**: %s'):format(k, v) or ('%s %s'):format(color('2', pad(k, 8)), v))
    end
  end
  local head = ('%s #%d  %s'):format(b.job, b.n, b.status)
  add(PLAIN and ('# ' .. head) or (icon(b.status) .. ' ' .. color('1', head)))
  field('branch', b.branch)
  local when = ('%s (%s)'):format(os.date('%Y-%m-%d %H:%M', b.ts), ago(b.ts))
  if b.status == 'RUNNING' then
    when = when .. ' · running for ' .. hms(os.time() - b.ts) .. (b.est and (' of ~' .. hms(b.est)) or '')
  else
    when = when .. ' · took ' .. hms(b.dur)
  end
  field('started', when)
  local root = g.root_of(b)
  local via = {}
  local up = b.up and g.by_id[b.up]
  while up do
    table.insert(via, 1, up.job .. ' #' .. up.n)
    up = up.up and g.by_id[up.up]
  end
  field('by', (user_of(g, b) or '?') .. (#via > 0 and ('  (via ' .. table.concat(via, ' → ') .. ')') or ''))
  local why, aborter = stopper(g, b)
  if why then
    field(aborter and 'aborted' or 'stopped', aborter and ('by ' .. why) or why)
  end
  local params = {}
  for k, v in pairs(b.params or root.params or {}) do
    if not tostring(v):match '^https?://' then
      table.insert(params, v == true and k or (k .. '=' .. tostring(v)))
    end
  end
  table.sort(params)
  field('params', table.concat(params, '  '))
  field('url', url_of(b))

  -- the whole chain, this build marked
  if g.kids[root.id] then
    section 'Chain'
    if PLAIN then
      add '```'
    end
    local function line(x, depth)
      local mark = (x.aborted_by and color('31', '  ⊘ ' .. x.aborted_by) or '') .. (x.id == b.id and color('1;33', ' ◀') or '')
      add(
        ('%s%s %s #%d  %s  %s%s'):format(
          ('  '):rep(depth),
          PLAIN and (ICON[x.status] or ICON.UNKNOWN)[1] or icon(x.status),
          x.job,
          x.n,
          started(x.ts),
          took(x),
          mark
        )
      )
    end
    line(root, 0)
    for _, x in ipairs(descendants(g, root)) do
      line(x.b, x.depth)
    end
    if PLAIN then
      add '```'
    end
  end

  if d.stages and #d.stages > 0 then
    section 'Stages'
    if PLAIN then
      add '```'
    end
    for _, s in ipairs(d.stages) do
      local st = STAGE_STATUS[s.status] or 'UNKNOWN'
      add(
        ('%s %s %s%s'):format(
          PLAIN and (ICON[st] or ICON.UNKNOWN)[1] or icon(st),
          pad(s.name, 44),
          lpad(hms(s.dur), 8),
          s.error and ('  ' .. color('31', clean(s.error))) or ''
        )
      )
    end
    if PLAIN then
      add '```'
    end
  end

  -- the job's builds on this branch: when it last passed
  if b.branch then
    local history, last_ok = {}, nil
    for _, x in ipairs(g.all) do
      if x.job == b.job and x.branch == b.branch then
        table.insert(history, x)
        if not last_ok and x.status == 'SUCCESS' then
          last_ok = x
        end
      end
    end
    if #history > 1 or last_ok then
      section(('%s on this branch (%d builds)'):format(b.job, #history))
      if last_ok then
        add(('last success: #%d  %s (%s)'):format(last_ok.n, os.date('%Y-%m-%d %H:%M', last_ok.ts), ago(last_ok.ts)))
      else
        add 'never succeeded (in the cache)'
      end
      if PLAIN then
        add '```'
      end
      for i = 1, math.min(#history, 10) do
        local x = history[i]
        add(('%s #%-6d %s  %s'):format(PLAIN and (ICON[x.status] or ICON.UNKNOWN)[1] or icon(x.status), x.n, started(x.ts), took(x)))
      end
      if PLAIN then
        add '```'
      end
    end
  end

  if d.tail and #d.tail > 0 then
    section 'Console (end)'
    if PLAIN then
      add '```'
    end
    for _, l in ipairs(d.tail) do
      if not PLAIN and (l:match 'ERROR' or l:match 'FAIL' or l:match 'Exception') then
        l = color('31', l)
      end
      add(l)
    end
    if PLAIN then
      add '```'
    end
  end
  out(table.concat(lines, '\n'))
end

-- -- complete -----------------------------------------------------------------------------------------------------

local PREFIXES = {
  { 'branch:', 'the branch (exact when complete, else a part)' },
  { 'job:', 'the rows: ' .. table.concat(JOBS, ' ') .. ' all' },
  { 'result:', table.concat(RESULTS, ' ') },
  { 'user:', 'who started the chain' },
  { 'since:', '7d 2w 1M or a date' },
  { 'on:', 'today yesterday 3d 2026-11-05 11-05 2026-11 A..B' },
  { 'mode:', 'MODE: sanity ...' },
  { 'version:', 'RELEASE_VERSION' },
  { 'per:', 'branch: the newest build of each branch' },
  { '-branch:', 'without the branch' },
  { '-result:', 'without the result' },
  { '-user:', 'without the user' },
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
      result = RESULTS,
      is = RESULTS,
      per = { 'branch' },
      since = { '1d', '3d', '7d', '2w', '1M', '3M' },
      on = { 'today', 'yesterday', '2d', '3d', os.date '%Y-%m' },
      job = vim.list_extend(vim.deepcopy(JOBS), { 'all' }),
    }
    if fixed[key] then
      local list = fixed[key]
      local done, last = value:match '^(.*,)([^,]*)$' -- a list: job:fs,ems
      done, last = done or '', last or value
      for _, v in ipairs(list) do
        if v:sub(1, #last) == last then
          add(sign .. key .. ':' .. done .. v, key == 'job' and SHORT[v] and ('short: ' .. SHORT[v]) or nil)
        end
      end
    else
      -- values from the cache: the most recent first
      local g = index(load_db())
      local seen, v = {}, lower(value)
      for _, b in ipairs(g.all) do
        local x
        if key == 'branch' then
          x = b.branch
        elseif key == 'user' then
          x = b.user and (b.user:gsub('@.*$', ''))
        elseif key == 'mode' then
          x = b.params and b.params.MODE
        elseif key == 'version' then
          x = b.params and b.params.RELEASE_VERSION
        end
        x = x and tostring(x)
        if x and not seen[x] and lower(x):find(v, 1, true) then
          seen[x] = { n = 1, last = b }
          table.insert(seen, x)
        elseif x and type(seen[x]) == 'table' then
          seen[x].n = seen[x].n + 1
        end
      end
      for i = 1, math.min(#seen, MAX_CANDIDATES) do
        local x = seen[i]
        local info = seen[x]
        add(
          sign .. key .. ':' .. (x:find '%s' and ('"' .. x .. '"') or x),
          ('%d builds, last %s %s'):format(info.n, started(info.last.ts), info.last.status:lower())
        )
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

-- -- the rest -----------------------------------------------------------------------------------------------------

local function url(_, rest)
  local job, n = (rest[1] or ''):match '^(.+)#(%d+)$'
  if job then
    out(URL .. job_path(job, n))
  end
end

local function log(_, rest)
  local job, n = (rest[1] or ''):match '^(.+)#(%d+)$'
  if not job then
    fail 'expected JOB#N'
  end
  local r = fetch(job_path(job, n) .. 'consoleText'):wait(120000)
  if r.code ~= 0 then
    fail(vim.trim(r.stderr or ''))
  end
  io.stdout:write((r.stdout:gsub('\27%[[%d;]*m', '')))
end

local function refresh_cmd(opts)
  local errors = refresh(opts.full)
  local db = load_db()
  local n = 0
  for _ in pairs(db.builds) do
    n = n + 1
  end
  if #errors > 0 then
    io.stderr:write(table.concat(errors, '\n') .. '\n')
  end
  out(('%d builds cached'):format(n))
  if #errors > 0 then
    os.exit(1)
  end
end

local commands = {
  search = search,
  show = show,
  complete = complete,
  url = url,
  log = log,
  refresh = refresh_cmd,
  terms = function()
    out '[]'
  end,
}
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](parse(vim.list_slice(_G.arg, 2)))
