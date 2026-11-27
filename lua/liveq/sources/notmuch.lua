-- notmuch sources of liveq: a mailbox searched with notmuch queries; items are threads.
--
--   require('liveq.sources.notmuch') { title = 'Mail (HPE)', config = '~/rcfiles/.notmuch-hpe', ... }
--
-- Options: `title`, `prompt`, `primary`, `config` (the NOTMUCH_CONFIG of the mailbox; notmuch's default when nil), `url` (a
-- template for a link to a message, `%s` being its message id; e.g. Gmail's), `sync` (the command that fetches new mail
-- and indexes it, run by alt-u; it should touch `<database>/.last-sync` when done, the time the picker shows), `outlook`
-- (a command that prints a mail's Outlook link given its Message-ID, run by alt-o, e.g. ~/rcfiles/bin/mail/outlook-link.py),
-- `outlook_app` (alt-o opens the mail in Outlook for Mac, falling back to the web), `outlook_pwa` (the Chrome app id of
-- the Outlook PWA, whose window alt-o opens the web link in when it is installed),
-- `commands` and `keymaps`.

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

  -- alt-u: fetches new mail in the background (a sync takes from seconds to minutes), then searches again
  local sync
  if opts.sync and vim.fn.executable(vim.fn.expand(opts.sync[1])) == 1 then
    sync = {
      desc = 'sync',
      fn = function(_, source)
        local title = opts.title or 'Mail'
        vim.notify('Syncing mail…', vim.log.levels.INFO, { title = title })
        local cmd = vim.tbl_map(vim.fn.expand, opts.sync)
        local ok, err = pcall(vim.system, cmd, { text = true, timeout = 900000 }, function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              local msg = vim.trim((result.stderr or '') .. (result.stdout or ''))
              local lines = vim.split(msg, '\n')
              msg = table.concat(vim.list_slice(lines, math.max(1, #lines - 4)), '\n') -- the end says why
              vim.notify(msg ~= '' and msg or ('sync failed (exit ' .. result.code .. ')'), vim.log.levels.ERROR, { title = title })
              return
            end
            vim.notify('Mail synced', vim.log.levels.INFO, { title = title })
            local has_fzf, fzf = pcall(require, 'fzf-lua')
            require('liveq').search(source.name, has_fzf and fzf.get_last_query() or '')
          end)
        end)
        if not ok then
          vim.notify(tostring(err), vim.log.levels.ERROR, { title = title })
        end
      end,
    }
  end

  -- Opens a mail's Outlook links (`outlook --app` prints the desktop app's, then the web's): in Outlook for Mac when
  -- `outlook_app` is set and the app takes the link (a universal link: `open` would give it to the browser), else in
  -- the Outlook PWA's own window when Chrome has it installed (`outlook_pwa`, its app id; a link handed to Chrome from
  -- outside lands in a tab even with "Open supported links" on), else in the browser.
  local universal_link = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), '..', 'universal_link.js')
  local function open_web(url)
    local id = opts.outlook_pwa
    local installed = id
      and vim.fn.has 'mac' == 1
      and #vim.fn.glob(vim.fs.joinpath(vim.env.HOME, 'Library/Application Support/Google/Chrome/*/Web Applications/Manifest Resources', id), false, true) > 0
    if installed then
      vim.system { 'open', '-na', 'Google Chrome', '--args', '--app-id=' .. id, '--app-launch-url-for-shortcuts-menu-item=' .. url }
    else
      vim.ui.open(url)
    end
  end
  local function open_outlook(app_url, web_url)
    if not app_url then
      return open_web(web_url)
    end
    vim.system({ 'osascript', '-l', 'JavaScript', universal_link, app_url }, { text = true, timeout = 15000 }, function(result)
      if vim.trim(result.stdout or '') ~= 'ok' then
        vim.schedule(function()
          open_web(web_url)
        end)
      end
    end)
  end
  local use_app = opts.outlook_app and vim.fn.has 'mac' == 1 and vim.uv.fs_stat '/Applications/Microsoft Outlook.app' ~= nil

  -- alt-o with `outlook`: the mail in Outlook (the app, or on the web), looked up on the server by its Message-ID; a thread opens at
  -- its newest message
  if opts.outlook and vim.fn.executable(vim.fn.expand(opts.outlook[1])) == 1 then
    web = {
      desc = 'outlook',
      fn = function(items)
        local item = items[1]
        if not item then
          return
        end
        local title = opts.title or 'Mail'
        local id = item.id
        if not id:match '^id:' then
          local cmd = { 'notmuch', 'search', '--output=messages', '--sort=newest-first', '--limit=1', id }
          local env = opts.config and { NOTMUCH_CONFIG = vim.fs.normalize(opts.config) } or nil
          id = vim.trim(vim.system(cmd, { text = true, env = env }):wait(10000).stdout or '')
        end
        if id == '' then
          vim.notify('No message in ' .. item.id, vim.log.levels.WARN, { title = title })
          return
        end
        local cmd = vim.tbl_map(vim.fn.expand, opts.outlook)
        if use_app then
          table.insert(cmd, '--app')
        end
        table.insert(cmd, id)
        local ok, err = pcall(vim.system, cmd, { text = true, timeout = 60000 }, function(result)
          vim.schedule(function()
            local urls = vim.split(vim.trim(result.stdout or ''), '\n')
            if result.code ~= 0 or not urls[#urls]:match '^https?://' then
              local msg = vim.trim((result.stderr or '') .. (result.stdout or ''))
              vim.notify(msg ~= '' and msg or ('lookup failed (exit ' .. result.code .. ')'), vim.log.levels.ERROR, { title = title })
              return
            end
            open_outlook(#urls > 1 and urls[1] or nil, urls[#urls])
          end)
        end)
        if not ok then
          vim.notify(tostring(err), vim.log.levels.ERROR, { title = title })
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

    match = true, -- `show --match QUERY` highlights the query's words and `terms -- QUERY` lists them
    saved = true, -- notmuch's named queries (query.NAME); usable as `query:NAME` in any query
    url = opts.url ~= nil,

    id_pattern = { '^thread:%x+$', '^id:%S+$' }, -- threads, and messages in the threaded view
    tree = true, -- `search --tree`: alt-t shows the messages of each thread, as mutt does
    cursor_id_pattern = 'thread:%x+',

    filetype = 'notmuchquery',
    extension = 'nmq',
    trigger_characters = { ' ', ':', '(' },
    keyword_pattern = [[\%(\k\|[:.@_-]\)\+]],
    split_clauses = function(query)
      return (query:gsub('%s+([Aa][Nn][Dd])%s+', '\n%1 '):gsub('%s+([Oo][Rr])%s+', '\n%1 '))
    end,
    syntax = syntax,

    -- alt-h in the picker hides the quoted history of each reply in the preview (`show --fold`)
    -- alt-i draws the mail's images in the preview, inline ones where the text says [image] (`show --images`): block
    -- art here, with the real image over it by image.nvim where it can draw (liveq/images.lua)
    preview_toggles = {
      ['alt-h'] = { flag = '--fold', desc = 'fold quotes' },
      ['alt-i'] = { flag = '--images', desc = 'images' },
    },
    images = true,
    gallery = true, -- alt-g: the thread's images, inline and attached, one at a time (`images`/`image`, gallery.lua)

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
      ['alt-u'] = sync,
      -- reply with Claude Code's mail-reply skill (~/rcfiles/.claude/skills/mail-reply): an interactive `claude` in a
      -- tmux window, in the main codebase ($LIVEQ_MAIL_REPLY_DIR, default ~/stormbreaker/security_director), which reads
      -- the thread and asks there for the points to make; it drafts and, on approval, saves the reply as an Outlook draft
      ['alt-r'] = {
        desc = 'Claude reply',
        fn = function(items)
          local item = items[1]
          if not item then
            return
          end
          if not vim.env.TMUX or vim.fn.executable 'claude' ~= 1 then
            vim.notify('Needs tmux and the `claude` command (Claude Code)', vim.log.levels.WARN)
            return
          end
          local what = item.id:match '^id:' and ('the mail with Message-ID <%s>'):format(item.id:sub(4)) or ('the newest mail of %s'):format(item.id)
          local prompt = ('/mail-reply Reply to %s ("%s"). I have not given the points yet: read the thread, then ask me what I want to say.'):format(
            what,
            item.title or ''
          )
          local dir = vim.env.LIVEQ_MAIL_REPLY_DIR or vim.fs.joinpath(vim.env.HOME, 'stormbreaker', 'security_director')
          dir = vim.uv.fs_stat(dir) and dir or vim.fn.getcwd()
          vim.system { 'tmux', 'new-window', '-n', 'mail-reply', '-c', dir, 'claude', prompt }
        end,
      },
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
