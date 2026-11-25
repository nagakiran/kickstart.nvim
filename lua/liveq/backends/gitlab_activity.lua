-- The GitLab activity backend of liveq (the events of GitLab's dashboard/activity page), run with `nvim -l`; it talks
-- to GitLab through `glab api`, so it uses glab's login and host.
--
--   nvim -l gitlab_activity.lua search -f fzf -l LIMIT [--tree] -- QUERY   a row per event (tree: grouped by MR/branch)
--   nvim -l gitlab_activity.lua show [--plain] -- ID          an event (a number), or a group of the tree (g:...)
--   nvim -l gitlab_activity.lua complete -f json [-c CURSOR] -- QUERY
--   nvim -l gitlab_activity.lua url -- ID
--   nvim -l gitlab_activity.lua saved -f tsv / save [--label NAME] -- QUERY
--
-- The query:
--   user:@me|NAME (several: any of them; default: you)   -user:NAME (hide)   project:PATH (several: any of them; all
--   its users, unless user: narrows them: then the users' feeds are read, and their events in other projects dropped)
--   type:push|merge|issue|comment|wiki|design|team (the tabs of the page; several: any of them)   -type:push (hide)
--   action:approved|closed|commented|created|destroyed|expired|joined|left|merged|pushed|reopened|updated   -action:
--   mr:11096 (events on that MR: opened, comments, approvals, pushes, merge; read from the MR itself, of everyone
--   unless user: is given, in project: or the default project)   branch:NAME (pushes to it)
--   since:7d|4h|today|yesterday|DATE   before:DATE   on:DATE|today|yesterday   sort:asc (oldest first)
--   any other word must appear in the title, the comment, the commit title, the branch, the author or the project.
--
-- GitLab filters by user (or project), one action or type, and dates; the rest is filtered here, so more pages are
-- read for such queries. GitLab has no endpoint for one event, so each listed event is kept in the cache for `show`.
--
-- Environment: LIVEQ_GITLAB_HOST (default: glab's host), LIVEQ_GITLAB_PROJECT (default project of the completion of
-- users: sd/security_director).

local C = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'gitlab_common.lua'))
C.name = 'liveq-gitlab-activity'
local out, fail, encode, DAY = C.out, C.fail, C.encode, C.DAY

local DEFAULT_PROJECT = os.getenv 'LIVEQ_GITLAB_PROJECT' or 'sd/security_director'
local SAVED_FILE = C.CONFIG_DIR .. '/gitlab-activity-saved.tsv'
local PER_PAGE, MAX_REQUESTS = 100, 20

local PREFIXES = {
  { 'user:', 'whose activity (@me for you); several: any of them' },
  { '-user:', 'hide this user' },
  { 'project:', 'all activity in a project' },
  { 'type:', 'push, merge, issue, comment, wiki, design, team' },
  { '-type:', 'hide a type, e.g. -type:push' },
  { 'action:', 'approved, commented, created, merged, pushed, closed, ...' },
  { '-action:', 'hide an action' },
  { 'mr:', 'events on one merge request (its iid)' },
  { 'branch:', 'pushes to a branch' },
  { 'since:', '7d, 4h, today, yesterday or a date' },
  { 'before:', 'a date' },
  { 'on:', 'a date, today or yesterday' },
  { 'sort:', 'desc (newest first) or asc' },
}

-- the tabs of the activity page: what GitLab can filter by (`action`, `target_type`), and the test of an event
local TYPES = {
  push = {
    action = 'pushed',
    test = function(e)
      return e.push_data ~= nil
    end,
  },
  merge = {
    target_type = 'merge_request',
    test = function(e)
      return e.target_type == 'MergeRequest'
    end,
  },
  issue = {
    target_type = 'issue',
    test = function(e)
      return e.target_type == 'Issue' or e.target_type == 'WorkItem'
    end,
  },
  comment = {
    action = 'commented',
    test = function(e)
      return e.note ~= nil
    end,
  },
  wiki = {
    test = function(e)
      return (e.target_type or ''):match '^WikiPage' ~= nil
    end,
  },
  design = {
    test = function(e)
      return (e.target_type or ''):match '^DesignManagement' ~= nil
    end,
  },
  team = {
    test = function(e)
      return e.action_name == 'joined' or e.action_name == 'left' or e.action_name == 'expired'
    end,
  },
}
local TYPE_NAMES = { 'push', 'merge', 'issue', 'comment', 'wiki', 'design', 'team' }

-- GitLab's actions, and the `action_name`s of the events they stand for
local ACTIONS = {
  approved = { 'approved' },
  closed = { 'closed' },
  commented = { 'commented on', 'commented' },
  created = { 'opened', 'created' },
  destroyed = { 'destroyed', 'deleted' },
  expired = { 'expired' },
  joined = { 'joined' },
  left = { 'left' },
  merged = { 'accepted', 'merged' },
  pushed = { 'pushed to', 'pushed new', 'deleted' },
  reopened = { 'reopened' },
  updated = { 'updated' },
}
local ACTION_NAMES = vim.tbl_keys(ACTIONS)
table.sort(ACTION_NAMES)
local DATES = { 'today', 'yesterday', '4h', '1d', '2d', '7d', '2w', '1M', '3M' }

-- -- time ---------------------------------------------------------------------------------------------------------

local LOCAL_OFFSET = os.time() - os.time(os.date '!*t')

--- The Unix time of an ISO 8601 time of GitLab: 2026-11-24T01:35:39.011-08:00 (or ...Z).
local function epoch(iso)
  local y, mo, d, h, mi, s, tz = (iso or ''):match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[.%d]*(.*)$'
  if not y then
    return 0
  end
  local t = os.time { year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }
  local sign, oh, om = tz:match '^([+-])(%d%d):?(%d%d)$'
  local offset = sign and (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == '-' and -1 or 1) or 0
  return t + LOCAL_OFFSET - offset
end

local function ago(t)
  local d = os.time() - t
  if d < 3600 then
    return math.max(1, math.floor(d / 60)) .. 'm'
  elseif d < DAY then
    return math.floor(d / 3600) .. 'h'
  elseif d < 30 * DAY then
    return math.floor(d / DAY) .. 'd'
  end
  return math.floor(d / (30 * DAY)) .. 'mo'
end

--- The local midnight starting the day of a date (YYYY-MM-DD, today or yesterday), or nil.
local function day_start(value)
  local now = os.date '*t'
  if value == 'today' or value == 'yesterday' then
    local t = os.time { year = now.year, month = now.month, day = now.day, hour = 0 }
    return value == 'today' and t or t - DAY
  end
  local y, m, d = value:match '^(%d%d%d%d)-(%d%d?)-(%d%d?)$'
  return y and os.time { year = y, month = m, day = d, hour = 0 } or nil
end

local function date(t)
  return os.date('%Y-%m-%d', t)
end

-- -- cache of events and projects ---------------------------------------------------------------------------------

local EVENT_DIR = C.CACHE_DIR .. '/' .. C.host() .. '-events'

local function event_file(id)
  return EVENT_DIR .. '/' .. id .. '.json'
end

local function group_file(key)
  return EVENT_DIR .. '/g-' .. key:gsub('[^%w%-_.!#@]', '_') .. '.json'
end

--- Events never change, so each is written once; the files older than a month go, once a day.
local function keep_events(events)
  vim.fn.mkdir(EVENT_DIR, 'p')
  for _, e in ipairs(events) do
    local path = event_file(e.id)
    if not vim.uv.fs_stat(path) then
      C.write_json(path, e)
    end
  end
  local marker = EVENT_DIR .. '/.pruned'
  local stat = vim.uv.fs_stat(marker)
  if stat and os.time() - stat.mtime.sec < DAY then
    return
  end
  for name in vim.fs.dir(EVENT_DIR) do
    local path = EVENT_DIR .. '/' .. name
    local s = vim.uv.fs_stat(path)
    if s and os.time() - s.mtime.sec > 30 * DAY then
      os.remove(path)
    end
  end
  local f = io.open(marker, 'w')
  if f then
    f:close()
  end
end

--- The paths of the projects of IDS (a set of project ids), from the cache or GitLab (in parallel).
local function project_paths(ids)
  local paths = C.cache_get('project-paths', 365 * DAY) or {}
  local pending = {}
  for id in pairs(ids) do
    if not paths[tostring(id)] then
      pending[tostring(id)] = C.api_async('projects/' .. id .. '?simple=true')
    end
  end
  if next(pending) then
    for id, wait in pairs(pending) do
      local p = wait()
      paths[id] = p and p.path_with_namespace or ('project-' .. id)
    end
    C.cache_set('project-paths', paths)
  end
  return paths
end

-- -- events -------------------------------------------------------------------------------------------------------

local function base_url(e)
  return ('https://%s/%s'):format(C.host(), e._path or '')
end

local function url_of(e)
  local base = base_url(e)
  local n = e.note
  if n then
    local anchor = '#note_' .. n.id
    if n.noteable_type == 'MergeRequest' then
      return ('%s/-/merge_requests/%s%s'):format(base, n.noteable_iid, anchor)
    elseif n.noteable_type == 'Issue' then
      return ('%s/-/issues/%s%s'):format(base, n.noteable_iid, anchor)
    elseif n.noteable_type == 'WorkItem' then
      return ('%s/-/work_items/%s%s'):format(base, n.noteable_iid, anchor)
    elseif n.noteable_type == 'Commit' and n.commit_id then
      return ('%s/-/commit/%s%s'):format(base, n.commit_id, anchor)
    end
    return base
  end
  local p = e.push_data
  if p then
    if p.action == 'removed' then
      return base .. '/-/branches'
    elseif p.action == 'created' or not p.commit_from then
      return ('%s/-/tree/%s'):format(base, p.ref or '')
    elseif p.commit_count == 1 then
      return ('%s/-/commit/%s'):format(base, p.commit_to)
    end
    return ('%s/-/compare/%s...%s'):format(base, p.commit_from, p.commit_to)
  end
  local t = e.target_type
  if t == 'MergeRequest' then
    return ('%s/-/merge_requests/%s'):format(base, e.target_iid)
  elseif t == 'Issue' then
    return ('%s/-/issues/%s'):format(base, e.target_iid)
  elseif t == 'WorkItem' then
    return ('%s/-/work_items/%s'):format(base, e.target_iid)
  elseif t == 'Milestone' then
    return ('%s/-/milestones/%s'):format(base, e.target_iid)
  elseif t and t:match '^WikiPage' then
    return ('%s/-/wikis/%s'):format(base, (e.target_title or ''):gsub(' ', '-'))
  end
  return base
end

--- What the event is about: its MR, issue, commit or branch. KEY groups the events of the tree (project id and the
--- thing), REF names it (`path!iid`, `path#iid`, `path@branch`), SHORT is the part shown in a row, TITLE its title.
local function target_of(e)
  local n, p = e.note, e.push_data
  local kind, iid
  if n and (n.noteable_type == 'MergeRequest' or n.noteable_type == 'Issue' or n.noteable_type == 'WorkItem') then
    kind, iid = n.noteable_type == 'MergeRequest' and '!' or '#', n.noteable_iid
  elseif e.target_type == 'MergeRequest' then
    kind, iid = '!', e.target_iid
  elseif e.target_type == 'Issue' or e.target_type == 'WorkItem' then
    kind, iid = '#', e.target_iid
  end
  if kind then
    return {
      key = e.project_id .. kind .. iid,
      ref = (e._path or '') .. kind .. iid,
      short = kind .. iid,
      title = e.target_title or '',
      url = ('%s/-/%s/%s'):format(base_url(e), kind == '!' and 'merge_requests' or 'issues', iid),
    }
  elseif p then
    return {
      key = e.project_id .. '@' .. (p.ref or ''),
      ref = (e._path or '') .. '@' .. (p.ref or ''),
      short = p.ref or '',
      title = p.ref or '',
      branch = true,
      url = ('%s/-/tree/%s'):format(base_url(e), p.ref or ''),
    }
  elseif n and n.noteable_type == 'Commit' and n.commit_id then
    local sha = n.commit_id:sub(1, 8)
    return {
      key = e.project_id .. '^' .. sha,
      ref = (e._path or '') .. '@' .. sha,
      short = sha,
      title = e.target_title or '',
      url = ('%s/-/commit/%s'):format(base_url(e), n.commit_id),
    }
  end
  local title = e.target_title or e._path or ''
  return {
    key = e.project_id .. '~' .. (e.target_type or 'project') .. '~' .. (e.target_id or e.id),
    ref = e._path or '',
    short = '',
    title = title,
    url = url_of(e),
  }
end

local function first_line(text)
  return vim.trim(((text or ''):gsub('\r', '')):match '^%s*([^\n]*)' or '')
end

--- The action as the page says it, with its icon and colour.
local function action_of(e)
  local a = e.action_name or ''
  local p = e.push_data
  if p then
    if p.action == 'created' then
      return '+', 'pushed new', '32'
    elseif p.action == 'removed' then
      return '✗', 'deleted', '31'
    end
    return '↑', 'pushed to', '36'
  end
  if e.note then
    return '✎', 'commented', '34'
  end
  local icons = {
    approved = { '✓', '32' },
    unapproved = { '✗', '33' },
    ['pushed to'] = { '↑', '36' },
    accepted = { '⇢', '35' },
    merged = { '⇢', '35' },
    opened = { '●', '32' },
    created = { '●', '32' },
    closed = { '✗', '31' },
    reopened = { '↺', '33' },
    updated = { '~', '33' },
    joined = { '→', '2' },
    left = { '←', '2' },
    expired = { '←', '2' },
    destroyed = { '✗', '31' },
  }
  local i = icons[a] or { '·', '0' }
  return i[1], a == 'accepted' and 'merged' or a, i[2]
end

--- The text of the event: the comment, or the commit title of a push.
local function body_of(e)
  if e.note then
    return ((e.note.body or ''):gsub('<br%s*/?>', '\n'))
  elseif e.push_data then
    return e.push_data.commit_title or ''
  end
  return e._summary or ''
end

-- -- query --------------------------------------------------------------------------------------------------------

local mr_events

local function plan(query, limit)
  local f = { users = {}, not_users = {}, types = {}, not_types = {}, actions = {}, not_actions = {}, projects = {}, words = {}, mrs = {}, branches = {} }
  local params = {}
  for _, term in ipairs(C.terms_of(query)) do
    local key, value = term:match '^(%-?[%a_]+):(.*)$'
    key = key and key:lower()
    if key and value ~= '' then
      local list = ({ type = TYPE_NAMES, ['-type'] = TYPE_NAMES, action = ACTION_NAMES, ['-action'] = ACTION_NAMES, sort = { 'asc', 'desc' } })[key]
      if list and not vim.tbl_contains(list, value) then
        return nil, ('%s: must be one of %s'):format(key, table.concat(list, ', '))
      end
      if key == 'user' then
        table.insert(f.users, C.user(value))
      elseif key == '-user' then
        f.not_users[C.user(value)] = true
      elseif key == 'project' then
        table.insert(f.projects, value)
      elseif key == 'type' then
        table.insert(f.types, value)
      elseif key == '-type' then
        table.insert(f.not_types, value)
      elseif key == 'action' then
        table.insert(f.actions, value)
      elseif key == '-action' then
        table.insert(f.not_actions, value)
      elseif key == 'mr' then
        local iid = value:match '^!?(%d+)$'
        if not iid then
          return nil, 'mr: takes the number of a merge request (mr:11096)'
        end
        f.mrs[tonumber(iid)] = true
        f.has_mr = true
      elseif key == 'branch' then
        table.insert(f.branches, value)
      elseif key == 'since' or key == 'before' or key == 'on' then
        local span = C.span(value)
        local start = span and (os.time() - span) or day_start(value)
        if not start then
          return nil, key .. ': takes 7d, 4h, today, yesterday or a date (2026-11-01)'
        end
        if key == 'since' then
          f.since = start
        elseif key == 'before' then
          f.before = start
        else
          f.since, f.before = start, start + DAY
        end
      elseif key == 'sort' then
        params.sort = value
      else
        table.insert(f.words, term:lower())
      end
    else
      table.insert(f.words, term:lower())
    end
  end

  -- what GitLab can filter by: one action and one target type; dates by day (after/before are exclusive)
  if #f.actions == 1 then
    params.action = f.actions[1]
    f.server_action = true
  end
  if #f.types == 1 then
    local t = TYPES[f.types[1]]
    if t.action and not params.action then
      params.action, f.server_type = t.action, true
    elseif t.target_type then
      params.target_type, f.server_type = t.target_type, true
    end
  end
  if f.since then
    params.after = date(f.since - DAY)
  end
  if f.before then
    params.before = date(f.before + DAY) -- whole days: the exact time is checked here
  end

  local client_only = #f.words > 0
    or next(f.not_users) ~= nil
    or #f.not_types > 0
    or #f.not_actions > 0
    or (#f.types > 0 and not f.server_type)
    or (#f.actions > 1)
    or (#f.projects > 0 and #f.users > 0)
    or f.has_mr
    or #f.branches > 0
  -- with users, their own feeds (which reach further back for one person than the project's), the projects checked
  -- here; else the projects' feeds, every user in them
  local endpoints = {}
  if #f.users > 0 then
    local me = C.me()
    for _, u in ipairs(f.users) do
      table.insert(endpoints, u == me and 'events' or ('users/' .. encode(u) .. '/events'))
    end
  elseif #f.projects > 0 then
    for _, p in ipairs(f.projects) do
      table.insert(endpoints, 'projects/' .. encode(p) .. '/events')
    end
  else
    table.insert(endpoints, 'events')
  end
  local pages = math.ceil(limit / PER_PAGE) * (client_only and 3 or 1)
  pages = math.max(1, math.min(pages, math.floor(MAX_REQUESTS / #endpoints)))

  local paths = {}
  for _, endpoint in ipairs(endpoints) do
    for page = 1, pages do
      local qs = { 'per_page=' .. PER_PAGE, 'page=' .. page }
      for k, v in pairs(params) do
        table.insert(qs, encode(k) .. '=' .. encode(v))
      end
      table.sort(qs)
      table.insert(paths, endpoint .. '?' .. table.concat(qs, '&'))
    end
  end
  f.sort = params.sort or 'desc'
  return paths, nil, f
end

local function matches(e, f)
  local t = epoch(e.created_at)
  e._time = t
  if (f.since and t < f.since) or (f.before and t >= f.before) then
    return false
  end
  local author = e.author_username or (e.author and e.author.username) or ''
  if f.not_users[author] then
    return false
  end
  if f.has_mr and #f.users > 0 and not vim.tbl_contains(f.users, author) then
    return false
  end
  if #f.users > 0 and #f.projects > 0 and not vim.tbl_contains(f.projects, e._path) then
    return false
  end
  local function any_type(list)
    for _, name in ipairs(list) do
      if TYPES[name].test(e) then
        return true
      end
    end
    return false
  end
  if #f.types > 0 and not f.server_type and not any_type(f.types) then
    return false
  end
  if #f.not_types > 0 and any_type(f.not_types) then
    return false
  end
  local function any_action(list)
    for _, name in ipairs(list) do
      if vim.tbl_contains(ACTIONS[name], e.action_name) then
        return true
      end
    end
    return false
  end
  if #f.actions > 0 and not f.server_action and not any_action(f.actions) then
    return false
  end
  if #f.not_actions > 0 and any_action(f.not_actions) then
    return false
  end
  if f.has_mr then
    local target = target_of(e)
    local iid = target.short:match '^!(%d+)$'
    if not (iid and f.mrs[tonumber(iid)]) then
      return false
    end
  end
  if #f.branches > 0 and not (e.push_data and vim.tbl_contains(f.branches, e.push_data.ref)) then
    return false
  end
  if #f.words > 0 then
    local hay = table
      .concat({ e.target_title or '', body_of(e), e.push_data and e.push_data.ref or '', author, e.author and e.author.name or '', e._path or '' }, '\n')
      :lower()
    for _, w in ipairs(f.words) do
      if not hay:find(w, 1, true) then
        return false
      end
    end
  end
  return true
end

-- -- search -------------------------------------------------------------------------------------------------------

local function hint(text, colour)
  out(('\t\27[%sm%s\27[0m\t\t'):format(colour or '2', (text:gsub('[\t\n]', ' '))))
end

--- The display of an event. In the tree its group shows the MR (or branch), so the row leaves it out.
local function display(e, in_tree, many_projects)
  local icon, action, colour = action_of(e)
  local author = e.author_username or (e.author and e.author.username) or ''
  local when = os.date('%m-%d %H:%M', e._time)
  local target = target_of(e)
  local parts = {
    '\27[2m' .. when .. '\27[0m',
    ('\27[33m%s\27[0m'):format(C.truncate(author, 12)),
    ('\27[%sm%s %s\27[0m'):format(colour, icon, C.truncate(action, 10)),
  }
  if not in_tree then
    if target.short ~= '' then
      table.insert(parts, ('\27[%sm%s\27[0m'):format(target.branch and '36' or '35', target.short))
    end
    if not target.branch and target.title ~= '' then
      table.insert(parts, target.title)
    end
  end
  local body = first_line(body_of(e))
  if e.push_data and (e.push_data.commit_count or 0) > 1 and e.push_data.action == 'pushed' then
    body = ('(%d) %s'):format(e.push_data.commit_count, body)
  end
  if body ~= '' then
    table.insert(parts, '\27[2m— ' .. body .. '\27[0m')
  end
  if many_projects and not in_tree then
    table.insert(parts, '\27[2m· ' .. (e._path or ''):match '[^/]*$' .. '\27[0m')
  end
  return table.concat(parts, ' ')
end

local function row(id, disp, url, title, depth)
  local function clean(s)
    return (s or ''):gsub('[\t\n]', ' ')
  end
  out(('%s\t%s\t%s\t%s%s'):format(id, clean(disp), url, clean(title), depth and ('\t' .. depth) or ''))
end

-- what the system notes of an MR stand for in the activity feed; other system notes (assigned, review requested,
-- description changed, ...) are not events of the feed, so they are left out
local SYSTEM_ACTIONS = {
  { '^approved this merge request', 'approved' },
  { '^unapproved this merge request', 'unapproved' },
  { '^merged', 'accepted' },
  { '^closed', 'closed' },
  { '^reopened', 'reopened' },
  { '^added %d+ commit', 'pushed to' },
}

--- The events of the MRs of an `mr:` query, made from each MR and its notes: the feeds hold only a few hours of a busy
--- project, and a user's feed only that user's events, so filtering them misses most of an MR's history.
--- Ids are `n` + the note id (or `m` + the MR id for its opening), so they never clash with the ids of events.
mr_events = function(f)
  local projects = #f.projects > 0 and f.projects or { DEFAULT_PROJECT }
  local jobs = {}
  for _, project in ipairs(projects) do
    for iid in pairs(f.mrs) do
      local base = ('projects/%s/merge_requests/%d'):format(encode(project), iid)
      table.insert(jobs, { mr = C.api_async(base), base = base })
    end
  end
  local events = {}
  for _, job in ipairs(jobs) do
    local mr = job.mr()
    if mr and mr.iid then
      local function event(id, created_at, author, action, note)
        return {
          id = id,
          created_at = created_at,
          project_id = mr.project_id,
          author = author,
          author_username = author and author.username,
          action_name = action,
          target_type = 'MergeRequest',
          target_iid = mr.iid,
          target_title = mr.title,
          note = note,
        }
      end
      table.insert(events, event('m' .. mr.id, mr.created_at, mr.author, 'opened'))
      for page = 1, MAX_REQUESTS do
        local notes, err = C.api(('%s/notes?per_page=%d&page=%d&sort=asc'):format(job.base, PER_PAGE, page))
        if not notes then
          return nil, err
        end
        for _, n in ipairs(notes) do
          if not n.system then
            n.noteable_type, n.noteable_iid = 'MergeRequest', mr.iid
            table.insert(events, event('n' .. n.id, n.created_at, n.author, 'commented on', n))
          else
            for _, rule in ipairs(SYSTEM_ACTIONS) do
              if (n.body or ''):match(rule[1]) then
                local e = event('n' .. n.id, n.created_at, n.author, rule[2])
                e._summary = rule[2] == 'pushed to' and ((n.body or ''):match '^[^\n<]*') or nil
                table.insert(events, e)
                break
              end
            end
          end
        end
        if #notes < PER_PAGE then
          break
        end
      end
    end
  end
  return events
end

local function search(opts, rest)
  local query = vim.trim(table.concat(rest, ' '))
  local fzf = (opts.f or opts.format) == 'fzf'
  local limit = tonumber(opts.l or opts.limit) or 100
  local paths, invalid, f = plan(query, limit)
  if not paths then
    if fzf then
      return hint(invalid, '31')
    end
    fail(invalid)
  end
  local waits = f.has_mr and {
    function()
      return mr_events(f)
    end,
  } or vim.tbl_map(C.api_async, paths)
  local seen, events = {}, {}
  for _, wait in ipairs(waits) do
    local data, err = wait()
    if not data then
      if fzf then
        return hint(err, '31')
      end
      fail(err)
    end
    for _, e in ipairs(data) do
      if not seen[e.id] then
        seen[e.id] = true
        table.insert(events, e)
      end
    end
  end

  local ids = {}
  for _, e in ipairs(events) do
    ids[e.project_id or 0] = true
  end
  local project_path = project_paths(ids)
  local found, projects = {}, {}
  for _, e in ipairs(events) do
    e._path = project_path[tostring(e.project_id)] or ''
    if matches(e, f) then
      table.insert(found, e)
      projects[e._path] = true
    end
  end
  table.sort(found, function(a, b)
    if a._time == b._time then
      return f.sort == 'asc' and a.id < b.id or a.id > b.id
    end
    return f.sort == 'asc' and a._time < b._time or a._time > b._time
  end)
  found = vim.list_slice(found, 1, limit)
  keep_events(found)

  if not fzf then
    for _, e in ipairs(found) do
      local _, action = action_of(e)
      out(('%s\t%s\t%s\t%s\t%s\t%s'):format(e.id, e.created_at, e.author_username or '', action, target_of(e).ref, url_of(e)))
    end
    return
  end
  if query == '' then
    hint 'Your activity. Filter with user:NAME project:PATH type:push|merge|issue|comment -type:push mr:N since:7d words…  tab: complete · alt-t: by MR'
  end
  if #found == 0 then
    hint 'No events match the query'
  end
  local many = vim.tbl_count(projects) > 1

  if not opts.tree then
    for _, e in ipairs(found) do
      local target = target_of(e)
      local _, action = action_of(e)
      row(e.id, display(e, false, many), url_of(e), ('%s %s %s %s'):format(e.author_username or '', action, target.ref, target.title))
    end
    return
  end

  -- the tree: a row per MR (issue, branch, ...) in the order of its latest event, its events under it
  local groups, order = {}, {}
  for _, e in ipairs(found) do
    local target = target_of(e)
    local g = groups[target.key]
    if not g then
      g = { target = target, events = {}, path = e._path, people = {}, order = {} }
      groups[target.key] = g
      table.insert(order, g)
    end
    table.insert(g.events, e)
    local who = e.author_username or ''
    if not g.people[who] then
      g.people[who] = 0
      table.insert(g.order, who)
    end
    g.people[who] = g.people[who] + 1
  end
  for _, g in ipairs(order) do
    local t = g.target
    local people = vim.tbl_map(function(who)
      return g.people[who] > 1 and (who .. '×' .. g.people[who]) or who
    end, g.order)
    local head = ('\27[1;%sm%s\27[0m \27[1m%s\27[0m'):format(t.branch and '36' or '35', t.short ~= '' and t.short or '·', t.branch and '' or t.title)
    local id = 'g:' .. t.key
    row(
      id,
      ('%s \27[2m· %s · %s\27[0m'):format(
        head,
        many and (g.path:match '[^/]*$') or #g.events .. (#g.events == 1 and ' event' or ' events'),
        table.concat(people, ' ')
      ),
      t.url,
      t.ref .. ' ' .. t.title,
      0
    )
    C.write_json(
      group_file(t.key),
      { ref = t.ref, title = t.title, url = t.url, path = g.path, ids = vim.tbl_map(function(e)
        return e.id
      end, g.events) }
    )
    for _, e in ipairs(g.events) do
      local _, action = action_of(e)
      row(e.id, display(e, true, many), url_of(e), ('%s %s %s %s'):format(e.author_username or '', action, t.ref, t.title), 1)
    end
  end
end

-- -- show ---------------------------------------------------------------------------------------------------------

local function load_event(id)
  local e = C.read_json(event_file(id))
  if e then
    e._time = epoch(e.created_at)
  end
  return e
end

local function styles(plain)
  if plain then
    return { bold = '', dim = '', reset = '', h1 = '# ', h2 = '## ' }
  end
  return { bold = '\27[1m', dim = '\27[2m', reset = '\27[0m', h1 = '', h2 = '' }
end

--- The lines of one event: who did what when, where, and its comment or commits.
local function event_lines(e, s, plain, with_target)
  local _, action = action_of(e)
  local author = e.author and e.author.name or e.author_username or ''
  local target = target_of(e)
  local when = os.date('%Y-%m-%d %H:%M', e._time) .. ' (' .. ago(e._time) .. ' ago)'
  local lines = {}
  local what = ('%s%s%s (@%s) %s'):format(s.bold, author, s.reset, e.author_username or '', action)
  if with_target then
    what = what .. ' ' .. (target.short ~= '' and target.short or '') .. (target.branch and '' or (' ' .. (target.title or '')))
  end
  table.insert(lines, (plain and '### ' or '') .. what)
  table.insert(lines, ('%s%s · %s%s'):format(s.dim, e._path or '', when, s.reset))
  local n, p = e.note, e.push_data
  if n and n.position then
    local pos = n.position
    local line = pos.new_line or pos.old_line
    table.insert(lines, ('%s%s%s%s'):format(s.dim, pos.new_path or pos.old_path or '', line and (':' .. line) or '', s.reset))
  end
  if n and n.resolvable then
    table.insert(lines, s.dim .. (n.resolved and 'resolved' or 'unresolved') .. s.reset)
  end
  if p then
    table.insert(lines, ('%sbranch%s %s'):format(s.dim, s.reset, p.ref or ''))
    if p.commit_count and p.action ~= 'created' then
      table.insert(lines, ('%scommits%s %d'):format(s.dim, s.reset, p.commit_count))
    end
    if p.commit_to then
      table.insert(lines, ('%shead%s %s'):format(s.dim, s.reset, p.commit_to:sub(1, 12)))
    end
  end
  table.insert(lines, s.dim .. url_of(e) .. s.reset)
  local body = vim.trim(body_of(e))
  if body ~= '' then
    table.insert(lines, '')
    vim.list_extend(lines, vim.split(body, '\n', { plain = true }))
  end
  return lines
end

local function show(opts, rest)
  local id = rest[1] or ''
  local s = styles(opts.plain)
  if id:match '^g:' then
    local g = C.read_json(group_file(id:sub(3)))
    if not g then
      return
    end
    out(('%s%s%s %s%s'):format(s.h1, s.bold, g.ref, g.title ~= g.ref:match '@(.*)$' and g.title or '', s.reset))
    out(s.dim .. g.url .. s.reset)
    -- oldest first: the conversation as it happened
    for i = #g.ids, 1, -1 do
      local e = load_event(g.ids[i])
      if e then
        out ''
        out(opts.plain and '' or (s.dim .. string.rep('─', 40) .. s.reset))
        for _, line in ipairs(event_lines(e, s, opts.plain, false)) do
          out(line)
        end
      end
    end
    return
  end
  if not id:match '^[nm]?%d+$' then
    return -- e.g. a hint line of fzf
  end
  local e = load_event(id)
  if not e then
    return out 'This event is no longer in the cache; search again.'
  end
  local target = target_of(e)
  if target.title ~= '' and not target.branch then
    out(('%s%s%s %s%s'):format(s.h1, s.bold, target.ref, target.title, s.reset))
    out ''
  end
  for _, line in ipairs(event_lines(e, s, opts.plain, false)) do
    out(line)
  end
end

local function url(_, rest)
  local id = rest[1] or ''
  if id:match '^g:' then
    local g = C.read_json(group_file(id:sub(3)))
    if g then
      out(g.url)
    end
  elseif id:match '^[nm]?%d+$' then
    local e = load_event(id)
    if e then
      out(url_of(e))
    end
  end
end

-- -- complete -----------------------------------------------------------------------------------------------------

local function values_for(key, typed, project)
  local static = ({
    type = TYPE_NAMES,
    ['-type'] = TYPE_NAMES,
    action = ACTION_NAMES,
    ['-action'] = ACTION_NAMES,
    since = DATES,
    on = { 'today', 'yesterday' },
    before = { 'today', 'yesterday' },
    sort = { 'asc', 'desc' },
  })[key]
  if static then
    return vim.tbl_map(function(v)
      return { v }
    end, C.matching(static, typed))
  elseif key == 'user' or key == '-user' then
    return C.users(project, typed)
  elseif key == 'project' then
    return C.projects(typed, { { DEFAULT_PROJECT, 'default' } })
  elseif key == 'branch' then
    local branches = C.api(('projects/%s/repository/branches?per_page=100&sort=updated_desc&search=%s'):format(encode(project), encode(typed))) or {}
    return vim.tbl_map(function(b)
      return { b.name }
    end, branches)
  end
  return {}
end

local function complete(opts, rest)
  local text = rest[1] or ''
  local cursor = tonumber(opts.c or opts.cursor) or vim.fn.strchars(text)
  local start, finish, term = C.term_at(text, cursor)
  local key, value = term:match '^(%-?[%a_]+):(.*)$'
  local context, candidates = 'field', {}
  if not key then
    for _, p in ipairs(PREFIXES) do
      if term == '' or p[1]:sub(1, #term):lower() == term:lower() then
        table.insert(candidates, C.candidate(p[1], p[1], 'field', p[2]))
      end
    end
  else
    context = 'value'
    value = value:gsub('^"', '')
    local project = text:match 'project:(%S+)' or DEFAULT_PROJECT
    for _, v in ipairs(values_for(key:lower(), value, project)) do
      table.insert(candidates, C.candidate(v[1], key .. ':' .. C.quote(v[1]) .. ' ', 'value', v[2]))
    end
  end
  out(vim.json.encode { context = context, prefix = term, replace_start = start, replace_end = finish, candidates = candidates })
end

local commands = {
  search = search,
  show = show,
  complete = complete,
  url = url,
  saved = function()
    C.saved(SAVED_FILE)
  end,
  save = function(opts, rest)
    C.save(SAVED_FILE, opts, rest)
  end,
}
local command = _G.arg[1]
if not commands[command] then
  fail('unknown command: ' .. tostring(command) .. ' (expected: ' .. table.concat(vim.tbl_keys(commands), ', ') .. ')', 2)
end
commands[command](C.parse(vim.list_slice(_G.arg, 2)))
