-- The live search of a source with fzf-lua: the prompt is the query, and the results reload as it is edited.

local util = require 'liveq.util'

local M = {}

--- The path of the generic command-line helper, run with `nvim -l`.
local function cli_path()
  return vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'cli.lua')
end

--- The shell command that completes the query `{q}` of fzf with a picker on the terminal, printing the new query.
--- A source whose backend has its own picker (`pick = true`) uses it; the others use the generic one of liveq.
function M.pick_command(source)
  local backend = util.shell_cmd(source)
  if source.pick then
    return backend .. ' pick -- {q}'
  end
  return ('%s -l %s pick --cmd %s -- {q}'):format(vim.fn.shellescape(vim.v.progpath), vim.fn.shellescape(cli_path()), vim.fn.shellescape(backend))
end

local function insert_text(win, text)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_put({ text }, 'c', true, true)
  end
end

local function results_buffer(source, items, query)
  vim.cmd 'botright new'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local lines = { ('<!-- %s: %s -->'):format(source.name, query or '') }
  for _, item in ipairs(items) do
    table.insert(lines, item.url ~= '' and ('- [%s](%s) %s'):format(item.id, item.url, item.title) or ('- %s %s'):format(item.id, item.title))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function id_title(items)
  return vim.tbl_map(function(i)
    return i.title ~= '' and (i.id .. ' - ' .. i.title) or i.id
  end, items)
end

function M.search(source, query)
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    vim.notify('fzf-lua is required', vim.log.levels.ERROR)
    return
  end
  local backend = util.shell_cmd(source)
  local last_query = function(opts)
    return (opts and opts.last_query) or fzf.get_last_query() or query or ''
  end
  -- the window that was current when the picker opened; ids are inserted there
  local origin_win = vim.api.nvim_get_current_win()
  -- tab runs a picker on the terminal (`execute`), and its result becomes the new query; when the picker is
  -- cancelled the query is kept as it is
  local tmp = vim.fn.tempname()
  local complete = ('execute(%s > %s || printf %%s {q} > %s)+transform-query(cat %s)'):format(M.pick_command(source), tmp, tmp, tmp)

  local actions = {
    ['enter'] = {
      desc = 'insert',
      fn = function(items)
        insert_text(
          origin_win,
          table.concat(
            vim.tbl_map(function(i)
              return i.id
            end, items),
            ', '
          )
        )
      end,
    },
    ['alt-enter'] = {
      desc = 'insert with title',
      fn = function(items)
        insert_text(origin_win, table.concat(id_title(items), ', '))
      end,
    },
    ['ctrl-o'] = {
      desc = 'browser',
      fn = function(items)
        for _, item in ipairs(items) do
          if item.url ~= '' then
            vim.ui.open(item.url)
          elseif source.url then
            -- the backend builds the link on demand (e.g. from the message id of a mail)
            require('liveq.show').open(source, item.id)
          end
        end
      end,
    },
    ['ctrl-y'] = {
      desc = 'yank',
      fn = function(items)
        local text = table.concat(id_title(items), '\n')
        vim.fn.setreg('+', text)
        vim.notify('Yanked: ' .. text)
      end,
    },
    ['ctrl-v'] = {
      desc = 'show',
      fn = function(items)
        if items[1] then
          require('liveq.show').show(source, items[1].id)
        end
      end,
    },
  }
  if source.url == false then
    -- neither the results nor the backend have links (e.g. a mailbox without a web client)
    actions['ctrl-o'] = nil
  end
  for key, action in pairs(source.actions or {}) do
    actions[key] = action
  end

  local fzf_actions = {}
  for key, action in pairs(actions) do
    fzf_actions[key] = function(selected)
      action.fn(util.items(source, selected), source)
    end
  end
  -- the actions on the query rather than on the items
  fzf_actions['ctrl-e'] = function(_, opts)
    require('liveq.buffer').open(source, last_query(opts))
  end
  if source.saved then
    fzf_actions['ctrl-r'] = function()
      M.saved(source)
    end
    fzf_actions['ctrl-s'] = function(_, opts)
      local q = last_query(opts)
      vim.ui.input({ prompt = 'Save query as: ' }, function(label)
        if label and label ~= '' and util.run(source, { 'save', '--label', label, '--', q }) then
          vim.notify('Saved: ' .. label)
        end
        M.search(source, q)
      end)
    end
  end
  fzf_actions['ctrl-q'] = {
    fn = function(selected, opts)
      results_buffer(source, util.items(source, selected), last_query(opts))
    end,
    prefix = 'select-all+',
  }

  local header = { 'tab complete', '^space select' }
  local keys = vim.tbl_keys(actions)
  table.sort(keys, function(a, b)
    -- enter first, then the rest by key
    if (a == 'enter') ~= (b == 'enter') then
      return a == 'enter'
    end
    return a < b
  end)
  for _, key in ipairs(keys) do
    if key ~= 'alt-enter' then
      table.insert(header, (key:gsub('^ctrl%-', '^')) .. ' ' .. actions[key].desc)
    end
  end
  vim.list_extend(header, { '^e edit' })
  if source.saved then
    vim.list_extend(header, { '^r saved', '^s save' })
  end
  table.insert(header, '^q buffer')

  fzf.fzf_live(('sleep 0.3; %s search -f fzf -l %d -- <query>'):format(backend, source.limit or 100), {
    prompt = source.prompt or (source.name .. '> '),
    query = query,
    search = query,
    exec_empty_query = true,
    keymap = { fzf = { ['tab'] = complete, ['ctrl-space'] = 'toggle' } },
    winopts = { title = ' ' .. source.title .. ' ', preview = { layout = 'vertical', vertical = 'down:50%' } },
    preview = backend .. ' show -- {1}',
    fzf_opts = {
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '2',
      ['--multi'] = true,
      ['--header'] = table.concat(header, ' · '),
    },
    actions = fzf_actions,
  })
end

--- Picks a saved query (`<backend> saved -f tsv`: label, query, key, origin) and searches with it.
function M.saved(source)
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    return
  end
  local out = util.run(source, { 'saved', '-f', 'tsv' })
  if not out then
    return
  end
  local entries = {}
  for _, line in ipairs(vim.split(vim.trim(out), '\n', { plain = true })) do
    local parts = vim.split(line, '\t', { plain = true })
    if parts[2] then
      table.insert(entries, ('%s\t\27[1m%s\27[0m \27[2m(%s)\27[0m\t%s'):format(parts[2], parts[1], parts[4] or '', parts[2]))
    end
  end
  local query_of = function(selected)
    return selected[1] and vim.split(selected[1], '\t', { plain = true })[1]
  end
  fzf.fzf_exec(entries, {
    prompt = 'saved> ',
    winopts = { title = ' Saved: ' .. source.title .. ' ', height = 0.4 },
    fzf_opts = { ['--ansi'] = true, ['--delimiter'] = '\t', ['--with-nth'] = '2,3' },
    actions = {
      ['enter'] = function(selected)
        if query_of(selected) then
          M.search(source, query_of(selected))
        end
      end,
      ['ctrl-e'] = function(selected)
        if query_of(selected) then
          require('liveq.buffer').open(source, query_of(selected))
        end
      end,
    },
  })
end

return M
