-- liveq: live, query-driven search of anything that has a query language (Jira/JQL, notmuch, GitLab MRs, ...).
--
-- The frontend lives here (fzf-lua picker, nvim-cmp completion, query buffer, details float); each source is a
-- backend command that implements a small CLI contract (see README.md). Usage:
--
--   require('liveq').setup { sources = { jira = require 'liveq.sources.jira' } }
--   -- and in the nvim-cmp config: require('liveq').setup_cmp(cmp)
--
-- Commands: :Liveq {source} [query] · :LiveqSaved {source} · :LiveqQuery {source} [query] · :LiveqShow {source} [id]
-- A source can also define its own command names and keymaps (see sources/jira.lua).

local M = { sources = {} }

--- The source of a buffer: the one that opened it as its query buffer, or else the one of its filetype (the primary
--- one when several sources share it).
function M.for_buffer(buf)
  local name = vim.b[buf or 0].liveq_source
  if name and M.sources[name] then
    return M.sources[name]
  end
  local filetype = vim.bo[buf or 0].filetype
  local found
  for _, spec in pairs(M.sources) do
    if spec.filetype == filetype then
      if spec.primary then
        return spec
      end
      found = found or spec
    end
  end
  return found
end

local function get(name)
  local spec = M.sources[name]
  if not spec then
    vim.notify('liveq: unknown source ' .. tostring(name), vim.log.levels.ERROR)
  end
  return spec
end

function M.search(name, query)
  local spec = get(name)
  if spec then
    require('liveq.picker').search(spec, query)
  end
end

function M.saved(name)
  local spec = get(name)
  if spec then
    require('liveq.picker').saved(spec)
  end
end

function M.query(name, query)
  local spec = get(name)
  if spec then
    require('liveq.buffer').open(spec, query)
  end
end

function M.show(name, id)
  local spec = get(name)
  if spec then
    require('liveq.show').show(spec, id)
  end
end

function M.open(name, id)
  local spec = get(name)
  if spec then
    require('liveq.show').open(spec, id)
  end
end

--- Adds a source. `spec` is described in README.md; `name` is how commands refer to it.
function M.register(name, spec)
  spec.name = name
  spec.title = spec.title or name
  M.sources[name] = spec

  if spec.filetype then
    if spec.extension then
      vim.filetype.add { extension = { [spec.extension] = spec.filetype } }
    end
    vim.api.nvim_create_autocmd('FileType', {
      pattern = spec.filetype,
      group = vim.api.nvim_create_augroup('liveq_' .. name, { clear = true }),
      callback = function()
        if spec.syntax then
          spec.syntax()
        end
        vim.opt_local.wrap = true
      end,
    })
  end

  local commands = spec.commands or {}
  local define = function(cmd, fn, desc, nargs)
    if cmd then
      vim.api.nvim_create_user_command(cmd, function(o)
        fn(name, o.args)
      end, { nargs = nargs, desc = desc })
    end
  end
  define(commands.search, M.search, spec.title .. ': live search', '?')
  define(commands.saved, M.saved, spec.title .. ': saved queries', 0)
  define(commands.query, M.query, spec.title .. ': query buffer', '?')
  define(commands.show, M.show, spec.title .. ': show item', '?')

  local keymaps = spec.keymaps or {}
  local map = function(lhs, fn, desc)
    if lhs then
      vim.keymap.set('n', lhs, function()
        fn(name)
      end, { desc = desc })
    end
  end
  map(keymaps.search, M.search, spec.title .. ': search')
  map(keymaps.saved, M.saved, spec.title .. ': saved queries')
  map(keymaps.query, M.query, spec.title .. ': query buffer')
  map(keymaps.show, M.show, spec.title .. ': show item under cursor')
  map(keymaps.open, M.open, spec.title .. ': open item under cursor in browser')
end

function M.setup(opts)
  for name, spec in pairs((opts or {}).sources or {}) do
    M.register(name, spec)
  end
  local complete_sources = function()
    return vim.tbl_keys(M.sources)
  end
  local generic = {
    { 'Liveq', M.search, 'liveq: live search' },
    { 'LiveqSaved', M.saved, 'liveq: saved queries' },
    { 'LiveqQuery', M.query, 'liveq: query buffer' },
    { 'LiveqShow', M.show, 'liveq: show item' },
  }
  for _, g in ipairs(generic) do
    vim.api.nvim_create_user_command(g[1], function(o)
      local name, rest = o.args:match '^(%S+)%s*(.*)$'
      g[2](name, rest)
    end, { nargs = '+', desc = g[3], complete = complete_sources })
  end
end

--- Registers the completion of the queries with nvim-cmp; call it from the nvim-cmp config.
function M.setup_cmp(cmp)
  require('liveq.cmp').setup(cmp, M)
end

return M
