-- copilot-api usage as a liveq source, backed by backends/copilot.lua (`nvim -l`, the proxy's SQLite request log
-- read with `sqlite3`). A row is a group of requests (a day by default; `by:model`, `by:session`, ...) with its
-- requests, tokens, cost and credits; the first row is the total of the query.
--
--   require('liveq.sources.copilot') { commands = {...}, keymaps = {...} }
--
-- Keys: `enter` the row broken down in a buffer (by model, hour, session; a session's requests one by one), within
-- the query's filters · `alt-d` drill down: the query narrowed to the row (a day → its hours, a model → its days).

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'copilot.lua'))

local function syntax()
  vim.cmd [[
    syntax match copilotQueryPrefix /\(^\|\s\)\zs-\?\(by\|since\|on\|model\|client\|endpoint\|session\|sort\):/
    syntax region copilotQueryString start=/"/ end=/"/ oneline
    highlight default link copilotQueryPrefix Identifier
    highlight default link copilotQueryString String
  ]]
end

--- The query without its terms of the given prefixes.
local function without(query, prefixes)
  local kept = {}
  for _, t in ipairs(vim.split(query or '', '%s+', { trimempty = true })) do
    local key = t:match '^%-?(%a+):'
    if not (key and prefixes[key]) then
      table.insert(kept, t)
    end
  end
  return table.concat(kept, ' ')
end

local function quoted(v)
  return v:find '%s' and ('"' .. v .. '"') or v
end

--- The query that zooms into a row: a time row's own time one level finer, else its key as a filter by day.
local function drill(query, id)
  local kind, key = id:match '^(%a+):(.+)$'
  if not kind then
    return nil
  end
  local time = { on = true, since = true, by = true }
  local narrowed
  if kind == 'month' then
    narrowed = { without(query, time), 'on:' .. key, 'by:day' }
  elseif kind == 'week' then
    local y, m, d = key:match '^(%d+)-(%d+)-(%d+)$'
    local last = os.date('%Y-%m-%d', os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d) + 6, hour = 12 })
    narrowed = { without(query, time), ('on:%s..%s'):format(key, last), 'by:day' }
  elseif kind == 'day' then
    narrowed = { without(query, time), 'on:' .. key, 'by:hour' }
  elseif kind == 'hour' then
    return nil -- the finest; enter shows its requests
  else
    narrowed = { without(query, { by = true, [kind] = true }), kind .. ':' .. quoted(key), kind == 'session' and 'by:hour' or 'by:day' }
  end
  return vim.trim(table.concat(narrowed, ' '))
end

return function(opts)
  opts = opts or {}
  local spec
  spec = {
    title = opts.title or 'Copilot usage',
    prompt = opts.prompt or 'usage> ',
    item_name = 'usage row',
    cmd = function()
      return { vim.v.progpath, '-l', backend }
    end,
    limit = opts.limit or 500,

    -- `show --match QUERY` is how a row's breakdown gets the query's filters (nothing is highlighted)
    match = true,
    header_row = true,

    id_pattern = '^%a+:.+$',

    filetype = 'copilotusage',
    extension = 'cuq',
    trigger_characters = { ' ', ':' },
    keyword_pattern = [[\%(\k\|[:."/-]\)\+]],
    split_clauses = function(query)
      return query
    end,
    syntax = syntax,

    actions = {
      ['enter'] = {
        desc = 'breakdown',
        fn = function(items, _, q)
          for _, item in ipairs(items) do
            require('liveq.show').buffer(spec, item.id, { query = q })
          end
        end,
      },
      ['alt-d'] = {
        desc = 'drill down',
        fn = function(items, _, q)
          local narrowed = items[1] and drill(q, items[1].id)
          if narrowed then
            require('liveq').search(spec.name, narrowed)
          else
            vim.notify('Nothing finer than an hour: enter shows its requests', vim.log.levels.INFO)
          end
        end,
      },
    },

    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  return spec
end
