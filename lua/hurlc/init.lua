-- hurlc: Postman-style request collections on top of hurl.nvim.
--
-- A collection is a directory under the root (default ~/patches/juniper/curl); a request is a hurl entry headed by
-- `# @name: ...`. Environments are <root>/envs/<env>.env; the active one is <root>/vars.env, written by
-- `refreshHurlToken` (bin/juniper.sh) and found by hurl.nvim from any subdirectory (it walks up to the git root).
--
--   require('hurlc').pick()        fzf-lua picker over every request: run, edit, copy as curl, import, duplicate
--   require('hurlc').run_cursor()  run the request under the cursor (recorded in the history)
--   require('hurlc').switch_env()  pick an environment, refresh its IAM token, rewrite vars.env
--   require('hurlc').history()     past responses of the request under the cursor
--
-- Each response hurl.nvim shows for a request started here is also saved to
-- stdpath('state')/hurlc/history/<collection file>/<request>/<time>.json (last HISTORY_KEEP per request), by wrapping
-- hurl.nvim's `history.update_history`, the one place every response passes through.
--
-- KINDS is the seam for other request types: a gRPC kind (grpcurl) needs a `parse` returning the same entry shape;
-- indexing, preview, edit, env and history do not care which kind an entry is. `run_here` still calls HurlRunnerAt
-- directly, so it has to dispatch on `e.kind` when a second kind arrives.

local M = {}

local HISTORY_KEEP = 50
local METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }
local JWT_MASK = [[sed -E 's/(eyJ[A-Za-z0-9_-]{6})[A-Za-z0-9._-]+/\1…/g']]

M.root = vim.fn.expand '~/patches/juniper/curl'
M.history_dir = vim.fn.stdpath 'state' .. '/hurlc/history'

local function notify(msg, level)
  vim.notify('hurlc: ' .. msg, level or vim.log.levels.INFO)
end

local function rel(path)
  local root = M.root .. '/'
  return path:sub(1, #root) == root and path:sub(#root + 1) or vim.fn.fnamemodify(path, ':~')
end

local function slug(s)
  return (s:gsub('[^%w%-_.]+', '_'))
end

--- key=value pairs of an env file (comments and blank lines skipped).
local function read_env(path)
  local vars = {}
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      local k, v = line:match '^%s*([%w_%-.]+)=(.*)$'
      if k and not line:match '^%s*#' then
        vars[k] = v
      end
    end
  end
  return vars
end

function M.active_env()
  return read_env(M.root .. '/vars.env').env
end

--- The entries of a hurl file given as LINES: { name, method, target, start, lnum, stop, index }. `start` is the first
--- of the comment lines directly above the method line (where `# @name:` lives), `stop` the last non-blank line before
--- the next entry's `start`, `index` the entry's 1-based position (hurl's --from-entry).
local function parse_hurl(lines)
  local entries = {}
  for i, line in ipairs(lines) do
    local method, target = line:match '^(%u+)%s+(%S+)'
    if method and METHODS[method] then
      local start, name = i, nil
      while start > 1 and lines[start - 1]:match '^%s*#' do
        start = start - 1
        name = name or lines[start]:match '^%s*#%s*@name:%s*(.-)%s*$'
      end
      for j = start, i - 1 do -- the nearest @name wins if there are several
        name = lines[j]:match '^%s*#%s*@name:%s*(.-)%s*$' or name
      end
      table.insert(entries, { name = name, method = method, target = target, start = start, lnum = i, index = #entries + 1 })
    end
  end
  for k, e in ipairs(entries) do
    local stop = k < #entries and entries[k + 1].start - 1 or #lines
    while stop > e.lnum and vim.trim(lines[stop]) == '' do
      stop = stop - 1
    end
    e.stop = stop
    -- unnamed entries fall back to their path, so a file that was never curated still lists usefully
    e.name = e.name or (e.target:gsub('^https?://[^/]+', ''):gsub('%?.*', ''))
  end
  return entries
end

M.KINDS = {
  hurl = { glob = '**/*.hurl', parse = parse_hurl },
}

--- Every request under the root, ordered by file then position.
function M.index()
  local items = {}
  for kind, spec in pairs(M.KINDS) do
    local files = vim.fn.globpath(M.root, spec.glob, false, true)
    table.sort(files)
    for _, file in ipairs(files) do
      if not file:find('/envs/', 1, true) then
        for _, e in ipairs(spec.parse(vim.fn.readfile(file))) do
          e.kind, e.file, e.rel = kind, file, rel(file)
          table.insert(items, e)
        end
      end
    end
  end
  return items
end

--- The entry of the current buffer that contains the cursor (or the first one below it).
local function entry_at_cursor()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entries = parse_hurl(lines)
  for _, e in ipairs(entries) do
    if row <= e.stop then
      e.file = vim.api.nvim_buf_get_name(0)
      e.rel, e.kind = rel(e.file), 'hurl'
      return e
    end
  end
end

local function open(e)
  vim.cmd('drop ' .. vim.fn.fnameescape(e.file))
  vim.api.nvim_win_set_cursor(0, { e.lnum, 0 })
  vim.cmd 'normal! zz'
end

local function block(e)
  return vim.list_slice(vim.fn.readfile(e.file), e.start, e.stop)
end

-- ── running and history ────────────────────────────────────────────────────────────────────────────────────────────

local function run_here(e)
  if vim.bo.modified then
    vim.cmd 'write' -- hurl reads the file on disk; an unsaved buffer would shift the entry index
  end
  if vim.api.nvim_win_get_cursor(0)[1] < e.lnum then
    vim.api.nvim_win_set_cursor(0, { e.lnum, 0 }) -- HurlRunnerAt wants the cursor inside the request, not its comments
  end
  M._ctx = { rel = e.rel, name = e.name, env = M.active_env(), time = os.time() }
  vim.cmd 'HurlRunnerAt'
end

function M.run(e)
  open(e)
  run_here(e)
end

function M.run_cursor()
  local e = entry_at_cursor()
  if not e then
    return notify('no request under the cursor', vim.log.levels.WARN)
  end
  run_here(e)
end

local function record(response, type)
  local ctx = M._ctx
  M._ctx = nil
  if not ctx or os.time() - ctx.time > 600 then
    return -- a run not started here (e.g. HurlRunner over a whole file): nothing to attribute it to
  end
  local dir = ('%s/%s/%s'):format(M.history_dir, slug(ctx.rel), slug(ctx.name))
  vim.fn.mkdir(dir, 'p')
  local doc = {
    time = os.date '%Y-%m-%d %H:%M:%S',
    env = ctx.env,
    request = ctx.name,
    file = ctx.rel,
    method = response.method,
    url = response.url,
    status = type == 'error' and 'error' or response.status,
    response_time = response.response_time,
    headers = response.headers,
    body = response.body,
    captures = response.captures,
  }
  vim.fn.writefile({ vim.json.encode(doc) }, ('%s/%s.json'):format(dir, os.date '%Y%m%d-%H%M%S'))
  local runs = vim.fn.glob(dir .. '/*.json', false, true)
  table.sort(runs)
  for i = 1, #runs - HISTORY_KEEP do
    vim.fn.delete(runs[i])
  end
end

--- Wraps hurl.nvim's history so each response of a request run from here is also saved to disk.
function M.setup(opts)
  opts = opts or {}
  M.root = opts.root and vim.fn.expand(opts.root) or M.root
  local ok, history = pcall(require, 'hurl.history')
  if ok and not history._hurlc_wrapped then
    local update = history.update_history
    history.update_history = function(response, type)
      pcall(record, response, type)
      return update(response, type)
    end
    history._hurlc_wrapped = true
  end
end

local function scratch(lines, ft, name)
  vim.cmd 'vnew'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

local function response_lines(path)
  local doc = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  local body = doc.body or ''
  local pretty = vim.fn.system({ 'jq', '.' }, body)
  if vim.v.shell_error == 0 then
    body = pretty
  end
  return vim.split(body, '\n', { trimempty = true }), doc
end

--- Past responses of E (the request under the cursor when nil): enter opens one, two selected and ctrl-d diffs them.
function M.history(e)
  e = e or entry_at_cursor()
  if not e then
    return notify('no request under the cursor', vim.log.levels.WARN)
  end
  local dir = ('%s/%s/%s'):format(M.history_dir, slug(e.rel), slug(e.name))
  local runs = vim.fn.glob(dir .. '/*.json', false, true)
  if #runs == 0 then
    return notify('no history for ' .. e.name)
  end
  table.sort(runs, function(a, b)
    return a > b
  end)
  local lines = {}
  for _, path in ipairs(runs) do
    local ok, doc = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
    if ok then
      local status = tostring(doc.status or '?')
      local color = status:match '^2' and '32' or (status:match '^3' and '33' or '31')
      table.insert(
        lines,
        ('%s\t%s  \27[%sm%s\27[0m  %6s ms  \27[2m%s\27[0m'):format(
          path,
          doc.time or '?',
          color,
          status,
          tostring(math.floor(tonumber(doc.response_time) or 0)),
          doc.env or '-'
        )
      )
    end
  end
  local preview = [[jq -r '"\(.method) \(.url)\nstatus \(.status) · \(.response_time) ms · env \(.env)\n"' {1}; ]]
    .. [[jq -r '.body // ""' {1} | (jq -C . 2>/dev/null || jq -r '.body // ""' {1}) | ]]
    .. JWT_MASK
  require('fzf-lua').fzf_exec(lines, {
    prompt = 'history> ',
    winopts = { title = ' ' .. e.name .. ' ', preview = { layout = 'vertical', vertical = 'down:60%' } },
    preview = preview,
    fzf_opts = {
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '2',
      ['--multi'] = true,
      ['--header'] = 'enter open · tab select · ^d diff two',
    },
    actions = {
      ['enter'] = function(selected)
        for _, s in ipairs(selected) do
          local path = vim.split(s, '\t')[1]
          local body, doc = response_lines(path)
          scratch(body, 'json', ('hurlc://%s/%s'):format(e.name, doc.time or path))
        end
      end,
      ['ctrl-d'] = function(selected)
        if #selected ~= 2 then
          return notify('select two runs (tab) to diff', vim.log.levels.WARN)
        end
        vim.cmd 'tabnew'
        local first = true
        for _, s in ipairs(selected) do
          local path = vim.split(s, '\t')[1]
          local body, doc = response_lines(path)
          if first then
            vim.api.nvim_buf_set_lines(0, 0, -1, false, body)
            vim.bo.buftype, vim.bo.bufhidden, vim.bo.filetype = 'nofile', 'wipe', 'json'
            pcall(vim.api.nvim_buf_set_name, 0, ('hurlc://%s/%s'):format(e.name, doc.time))
            first = false
          else
            scratch(body, 'json', ('hurlc://%s/%s'):format(e.name, doc.time))
          end
          vim.cmd 'diffthis'
        end
      end,
    },
  })
end

-- ── environments ───────────────────────────────────────────────────────────────────────────────────────────────────

function M.envs()
  local names = {}
  for _, f in ipairs(vim.fn.glob(M.root .. '/envs/*.env', false, true)) do
    table.insert(names, vim.fn.fnamemodify(f, ':t:r'))
  end
  table.sort(names)
  return names
end

--- Picks an environment and runs `refreshHurlToken` for it, then calls ON_DONE (with the env) on success.
function M.switch_env(on_done)
  local current = M.active_env()
  vim.ui.select(M.envs(), {
    prompt = 'Environment' .. (current and (' (now ' .. current .. ')') or '') .. ': ',
  }, function(env)
    if not env then
      return
    end
    local stderr = {}
    local cmd = ('source ~/rcfiles/bin/juniper.sh && HURL_COLLECTIONS_ROOT=%s refreshHurlToken %s'):format(vim.fn.shellescape(M.root), vim.fn.shellescape(env))
    vim.fn.jobstart({ 'bash', '-c', cmd }, {
      stderr_buffered = true,
      on_stderr = function(_, data)
        stderr = data
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then
            notify('environment ' .. env)
            if on_done then
              on_done(env)
            end
          else
            notify(('could not switch to %s: %s'):format(env, vim.trim(table.concat(stderr, ' '))), vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end)
end

-- ── editing the collections ────────────────────────────────────────────────────────────────────────────────────────

--- E as curl on the clipboard, with {{variables}} filled from the active environment (vars.env).
function M.copy_curl(e)
  local vars = read_env(M.root .. '/vars.env')
  local text = table.concat(block(e), '\n'):gsub('{{%s*([%w_%-.]+)%s*}}', function(k)
    return vars[k]
  end)
  local out = vim.fn.system({ 'hurl2curl' }, text)
  if vim.v.shell_error ~= 0 then
    return notify('hurl2curl failed: ' .. out, vim.log.levels.ERROR)
  end
  vim.fn.setreg('+', out)
  notify('copied as curl: ' .. e.name)
end

--- Appends LINES to FILE (creating it and its directory), a blank line apart from what is there; returns the line
--- number of the first appended line.
local function append(file, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ':h'), 'p')
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #existing > 0 and vim.trim(existing[#existing]) == '' do
    table.remove(existing)
  end
  local at = #existing
  if at > 0 then
    table.insert(lines, 1, '')
  end
  vim.api.nvim_buf_set_lines(buf, at, -1, false, lines)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd 'silent write'
  end)
  return at + (at > 0 and 2 or 1)
end

local function choose_file(on_choice)
  local files = vim.tbl_map(rel, vim.fn.globpath(M.root, '**/*.hurl', false, true))
  table.sort(files)
  table.insert(files, '[new file]')
  vim.ui.select(files, { prompt = 'Collection file: ' }, function(choice)
    if choice == '[new file]' then
      vim.ui.input({ prompt = 'New file (collection/name.hurl): ' }, function(path)
        if path and path ~= '' then
          on_choice(M.root .. '/' .. (path:match '%.hurl$' and path or (path .. '.hurl')))
        end
      end)
    elseif choice then
      on_choice(M.root .. '/' .. choice)
    end
  end)
end

--- A new request from the curl command(s) on the clipboard (e.g. a browser's "Copy as cURL").
function M.import_clipboard()
  local clip = vim.fn.getreg '+'
  if not clip:match 'curl' then
    return notify('the clipboard holds no curl command', vim.log.levels.WARN)
  end
  vim.ui.input({ prompt = 'Request name (empty: from the URL): ' }, function(name)
    if name == nil then
      return
    end
    choose_file(function(file)
      local cmd = { 'python3', vim.fn.expand '~/rcfiles/bin/utils/curl_import.py', '--envs', M.root .. '/envs' }
      if name ~= '' then
        vim.list_extend(cmd, { '--name', name })
      end
      local result = vim.system(cmd, { stdin = clip, text = true }):wait()
      if result.code ~= 0 then
        return notify(vim.trim(result.stderr or 'import failed'), vim.log.levels.ERROR)
      end
      local first = append(file, vim.split(vim.trim(result.stdout), '\n'))
      vim.cmd('drop ' .. vim.fn.fnameescape(file))
      vim.api.nvim_win_set_cursor(0, { first, 0 })
      notify('imported into ' .. rel(file))
    end)
  end)
end

--- A copy of E right after it, under a new name.
function M.duplicate(e)
  vim.ui.input({ prompt = 'Name of the copy: ', default = e.name .. ' (copy)' }, function(name)
    if not name or name == '' then
      return
    end
    local lines, named = block(e), false
    for i, l in ipairs(lines) do
      if l:match '^%s*#%s*@name:' then
        lines[i], named = '# @name: ' .. name, true
      end
    end
    if not named then
      table.insert(lines, e.lnum - e.start + 1, '# @name: ' .. name)
    end
    open(e)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, e.stop, e.stop, false, vim.list_extend({ '' }, lines))
    vim.cmd 'silent write'
    vim.api.nvim_win_set_cursor(0, { e.stop + 2, 0 })
  end)
end

-- ── the picker ─────────────────────────────────────────────────────────────────────────────────────────────────────

local METHOD_COLOR = { GET = '32', POST = '33', PUT = '34', PATCH = '35', DELETE = '31' }

function M.pick()
  local items = M.index()
  if #items == 0 then
    return notify('no requests under ' .. M.root, vim.log.levels.WARN)
  end
  local w_rel, w_name = 0, 0
  for _, e in ipairs(items) do
    w_rel = math.min(math.max(w_rel, vim.fn.strchars((e.rel:gsub('%.hurl$', '')))), 32)
    w_name = math.min(math.max(w_name, vim.fn.strchars(e.name)), 48)
  end
  local by_key, lines = {}, {}
  for _, e in ipairs(items) do
    local key = e.file .. ':' .. e.lnum
    by_key[key] = e
    local coll = e.rel:gsub('%.hurl$', '')
    local path = e.target:gsub('^https?://', ''):gsub('^[^/]*', '')
    table.insert(
      lines,
      table.concat({
        e.file,
        e.start,
        e.stop,
        key,
        ('\27[36m%s\27[0m  %s  \27[%sm%-6s\27[0m \27[2m%s\27[0m'):format(
          coll .. string.rep(' ', w_rel - vim.fn.strchars(coll)),
          e.name .. string.rep(' ', w_name - vim.fn.strchars(e.name)),
          METHOD_COLOR[e.method] or '0',
          e.method,
          path
        ),
      }, '\t')
    )
  end
  local function each(fn)
    return function(selected)
      for _, s in ipairs(selected) do
        local e = by_key[vim.split(s, '\t')[4]]
        if e then
          fn(e)
        end
      end
    end
  end
  local function first(fn)
    return function(selected)
      local e = selected[1] and by_key[vim.split(selected[1], '\t')[4]]
      if e then
        fn(e)
      end
    end
  end
  local env = M.active_env()
  require('fzf-lua').fzf_exec(lines, {
    prompt = (env and ('[' .. env .. '] ') or '') .. 'requests> ',
    winopts = { title = ' API requests ', preview = { layout = 'vertical', vertical = 'down:55%' } },
    preview = 'sed -n {2},{3}p {1} | ' .. JWT_MASK,
    fzf_opts = {
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '5',
      ['--multi'] = true,
      ['--header'] = 'enter run · ^e/alt-e edit · ^y copy curl · alt-n new from clipboard · alt-d duplicate · ^x env · alt-h history · ^q quickfix',
    },
    actions = {
      ['enter'] = first(M.run),
      ['ctrl-e'] = first(open),
      ['alt-e'] = first(open),
      ['ctrl-y'] = first(M.copy_curl),
      ['alt-n'] = function()
        M.import_clipboard()
      end,
      ['alt-d'] = first(M.duplicate),
      ['alt-h'] = first(M.history),
      ['ctrl-x'] = function()
        M.switch_env(function()
          M.pick()
        end)
      end,
      ['ctrl-q'] = function(selected)
        local qf = {}
        each(function(e)
          table.insert(qf, { filename = e.file, lnum = e.lnum, text = e.rel .. ' › ' .. e.name })
        end)(selected)
        vim.fn.setqflist(qf, 'r')
        vim.cmd 'copen'
      end,
    },
  })
end

return M
