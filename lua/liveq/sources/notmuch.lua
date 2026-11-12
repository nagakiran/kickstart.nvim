-- notmuch sources of liveq: a mailbox searched with notmuch queries; items are threads.
--
--   require('liveq.sources.notmuch') { title = 'Mail (HPE)', config = '~/rcfiles/.notmuch-hpe', ... }
--
-- Options: `title`, `prompt`, `primary`, `config` (the NOTMUCH_CONFIG of the mailbox; notmuch's default when nil), `url` (a
-- template for a link to a message, `%s` being its message id; e.g. Gmail's), `commands` and `keymaps`.

local backend = vim.fs.normalize(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'backends', 'notmuch.lua'))

local function syntax()
  vim.cmd [[
    syntax case ignore
    syntax keyword notmuchQueryKeyword and or not
    syntax match notmuchQueryPrefix /\<\(from\|to\|subject\|tag\|is\|date\|folder\|path\|attachment\|mimetype\|body\|id\|thread\|query\|property\):/
    syntax region notmuchQueryString start=/"/ skip=/""/ end=/"/ oneline
    highlight default link notmuchQueryKeyword Keyword
    highlight default link notmuchQueryPrefix Identifier
    highlight default link notmuchQueryString String
  ]]
end

return function(opts)
  opts = opts or {}
  local env = {}
  if opts.config then
    table.insert(env, 'NOTMUCH_CONFIG=' .. vim.fs.normalize(opts.config))
  end
  if opts.url then
    table.insert(env, 'LIVEQ_MAIL_URL=' .. opts.url)
  end

  local web
  if opts.url then
    -- the web client's link (e.g. Gmail), since ctrl-o opens the local HTML page
    web = {
      desc = 'web',
      fn = function(items, source)
        for _, item in ipairs(items) do
          require('liveq.show').open(source, item.id)
        end
      end,
    }
  end

  local spec = {
    title = opts.title or 'Mail',
    prompt = opts.prompt or 'mail> ',
    item_name = 'thread id',
    cmd = function()
      local cmd = #env > 0 and vim.list_extend({ 'env' }, env) or {}
      return vim.list_extend(cmd, { vim.v.progpath, '-l', backend })
    end,
    limit = opts.limit or 100,

    saved = true, -- notmuch's named queries (query.NAME); usable as `query:NAME` in any query
    url = opts.url ~= nil,

    id_pattern = '^thread:%x+$',
    cursor_id_pattern = 'thread:%x+',

    filetype = 'notmuchquery',
    extension = 'nmq',
    trigger_characters = { ' ', ':', '(' },
    keyword_pattern = [[\%(\k\|[:.@_-]\)\+]],
    split_clauses = function(query)
      return (query:gsub('%s+([Aa][Nn][Dd])%s+', '\n%1 '):gsub('%s+([Oo][Rr])%s+', '\n%1 '))
    end,
    syntax = syntax,

    actions = {
      -- like neomutt's <F7> (viewhtmlmsg): the thread rendered as a local HTML page, inline images included
      ['ctrl-o'] = {
        desc = 'browser',
        fn = function(items, source)
          for _, item in ipairs(items) do
            local path = require('liveq.util').run(source, { 'html', '--', item.id })
            if path and vim.trim(path) ~= '' then
              vim.ui.open(vim.trim(path))
            end
          end
        end,
      },
      ['alt-o'] = web,
      ['ctrl-x'] = {
        desc = 'tag',
        fn = function(items, source)
          if #items == 0 then
            return
          end
          vim.ui.input({ prompt = 'Tags (+add -remove): ' }, function(changes)
            if changes and vim.trim(changes) ~= '' then
              local args = { 'tag', '--', changes }
              vim.list_extend(
                args,
                vim.tbl_map(function(i)
                  return i.id
                end, items)
              )
              if require('liveq.util').run(source, args) then
                vim.notify(('Tagged %d thread(s): %s'):format(#items, changes))
              end
            end
          end)
        end,
      },
    },

    -- the source whose completion a bare `.nmq` file gets, when several mailboxes are registered
    primary = opts.primary,
    commands = opts.commands,
    keymaps = opts.keymaps,
  }
  return spec
end
