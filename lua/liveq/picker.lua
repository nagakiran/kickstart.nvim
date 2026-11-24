-- The live search of a source with fzf-lua: the prompt is the query, and the results reload as it is edited.

local util = require 'liveq.util'

local M = {}

--- The path of the generic command-line helper, run with `nvim -l`.
local function cli_path()
  return vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'cli.lua')
end

--- The awk filter that draws the branches of a threaded search (`search --tree`).
local function tree_awk()
  return vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)), 'tree.awk')
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

--- The key hints of the fzf header, joined with ' · ' and wrapped onto as many lines as the picker's width needs.
local function wrap_header(hints)
  local width = require('fzf-lua.config').globals.winopts.width or 0.8
  if width <= 1 then
    width = math.floor(vim.o.columns * width)
  end
  width = width - 6 -- the border, fzf's pointer gutter and some slack
  local lines, line = {}, ''
  for _, hint in ipairs(hints) do
    local candidate = line == '' and hint or line .. ' · ' .. hint
    if line ~= '' and vim.fn.strdisplaywidth(candidate) > width then
      table.insert(lines, line)
      line = hint
    else
      line = candidate
    end
  end
  table.insert(lines, line)
  return table.concat(lines, '\n')
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
    ['alt-b'] = {
      desc = 'buffer',
      fn = function(items, _, q)
        -- each in its own buffer; the last one is left in the window, at the first match of the query (n/N for the next)
        for _, item in ipairs(items) do
          vim.api.nvim_set_current_win(origin_win)
          require('liveq.show').buffer(source, item.id, { query = q })
        end
      end,
    },
    ['ctrl-v'] = {
      desc = 'show',
      fn = function(items, _, q)
        if items[1] then
          require('liveq.show').show(source, items[1].id, { query = q })
        end
      end,
    },
  }
  if source.url == false then
    -- neither the results nor the backend have links (e.g. a mailbox without a web client)
    actions['ctrl-o'] = nil
  end
  -- a source whose backend lists an item's images (`images -f fzf`, `image`): their gallery (gallery.lua)
  if source.gallery then
    actions['alt-g'] = {
      desc = 'gallery',
      fn = function(items)
        if items[1] then
          require('liveq.gallery').open(source, items[1].id)
        end
      end,
    }
  end
  for key, action in pairs(source.actions or {}) do
    actions[key] = action
  end

  local fzf_actions = {}
  for key, action in pairs(actions) do
    fzf_actions[key] = function(selected, opts)
      action.fn(util.items(source, selected), source, last_query(opts))
    end
  end
  -- the actions on the query rather than on the items; alt-e, since ctrl-e is fzf's end-of-line
  fzf_actions['alt-e'] = function(_, opts)
    require('liveq.buffer').open(source, last_query(opts))
  end
  -- a source with `tmux` moves the search to the shell's picker in a tmux window (tmux.lua), images on: alt-w
  local in_window = require('liveq.tmux').available(source)
  if in_window then
    fzf_actions['alt-w'] = function(_, opts)
      require('liveq.tmux').search(source, last_query(opts), { images = true })
    end
  end
  if source.saved then
    fzf_actions['ctrl-r'] = function(_, opts)
      M.saved(source, { back = last_query(opts) })
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
  -- keys that toggle a flag of the preview's `show` (e.g. folding quoted mail); the state lives in a file that the
  -- preview command tests, so it survives reopening the picker within this session
  local preview_flags = ''
  local fzf_keymap = { ['tab'] = complete, ['ctrl-space'] = 'toggle' }
  source.toggle_state = source.toggle_state or {}
  local toggle_keys = vim.tbl_keys(source.preview_toggles or {})
  table.sort(toggle_keys)
  for _, key in ipairs(toggle_keys) do
    local toggle = source.preview_toggles[key]
    source.toggle_state[key] = source.toggle_state[key] or vim.fn.tempname()
    local state = vim.fn.shellescape(source.toggle_state[key])
    preview_flags = preview_flags .. (' $([ -e %s ] && printf %%s %s)'):format(state, vim.fn.shellescape(toggle.flag))
    fzf_keymap[key] = ('execute-silent([ -e %s ] && rm -f %s || touch %s)+refresh-preview'):format(state, state, state)
    table.insert(header, (key:gsub('^ctrl%-', '^')) .. ' ' .. toggle.desc)
  end
  -- a source whose `show` takes `--match QUERY` highlights the query's words in the preview and writes the lines that
  -- have them to a file; the preview then scrolls to the first one (sent to fzf through --listen, since fzf only takes
  -- a scroll offset once the preview is complete), and alt-n/alt-p go to the next and previous ones
  local preview_prefix, preview_match, preview_suffix = '', '', ''
  if source.match then
    source.match_state = source.match_state or vim.fn.tempname()
    local state = vim.fn.shellescape(source.match_state)
    local cli = ('%s -l %s'):format(vim.fn.shellescape(vim.v.progpath), vim.fn.shellescape(cli_path()))
    preview_prefix = 'LIVEQ_MATCH_FILE=' .. state .. ' '
    preview_match = ' --match {q}'
    preview_suffix = ('; %s scroll %s >/dev/null 2>&1 &'):format(cli, state)
    fzf_keymap['alt-n'] = ('transform(%s match next %s)'):format(cli, state)
    fzf_keymap['alt-p'] = ('transform(%s match prev %s)'):format(cli, state)
    -- a new item's preview starts at the top until its scroll arrives, not at the offset of the previous item's match
    fzf_keymap['focus'] = 'change-preview-window(+1)+change-preview-label()'
    table.insert(header, 'alt-n/p match')
  end
  -- a source whose `show --images` draws images gets them drawn for real over its block art, by image.nvim (images.lua)
  local image_env, on_create = '', nil
  if source.images then
    source.image_state = source.image_state or vim.fn.tempname()
    image_env = require('liveq.images').env(source.image_state)
    if image_env ~= '' then
      on_create = function(e)
        require('liveq.images').attach(e.bufnr, source.image_state)
      end
    end
  end
  -- alt-x opens the links of the preview: a copy of it is kept in a file (`tee`), and `cli.lua links` opens the link of
  -- the message at the current match when it has just one, else lists them all on the terminal, nearest first
  source.preview_state = source.preview_state or vim.fn.tempname()
  -- not ending in the quoted path: fzf-lua takes a preview that starts and ends with a quote as quoted as a whole
  local preview_tee = ' | tee ' .. vim.fn.shellescape(source.preview_state) .. ' 2>/dev/null'
  fzf_keymap['alt-x'] = ('execute(%s -l %s links %s %s)'):format(
    vim.fn.shellescape(vim.v.progpath),
    vim.fn.shellescape(cli_path()),
    vim.fn.shellescape(source.preview_state),
    source.match_state and vim.fn.shellescape(source.match_state) or "''"
  )
  table.insert(header, 'alt-x links')
  -- a source with `tree` shows its items threaded (mail: the messages of each thread; Jira: subtasks under their
  -- parent) when alt-t is on: `search --tree`, whose rows tree.awk draws branches for; the state lives in a file that
  -- the search command tests, like the preview toggles
  local tree_flag, tree_filter = '', ''
  if source.tree then
    source.tree_state = source.tree_state or vim.fn.tempname()
    local state = source.tree_state
    tree_flag = (' $([ -e %s ] && printf %%s --tree)'):format(vim.fn.shellescape(state))
    tree_filter = ' | awk -f ' .. vim.fn.shellescape(tree_awk())
    fzf_actions['alt-t'] = {
      fn = function()
        if vim.uv.fs_stat(state) then
          os.remove(state)
        else
          local f = io.open(state, 'w')
          if f then
            f:close()
          end
        end
      end,
      reload = true,
    }
    table.insert(header, 'alt-t tree')
  end
  -- a source with `views` (e.g. Jira: which columns the rows show) cycles through them with alt-c: each view is a
  -- list of arguments of `search`, written to a file that the search command reads; the prompt names the view
  local view_set, view_args, prompt = '', '', source.prompt or (source.name .. '> ')
  if source.views and #source.views > 0 then
    source.view_index = source.view_index or 1
    source.view_state = source.view_state or vim.fn.tempname()
    local args_file, prompt_file = source.view_state, source.view_state .. '.prompt'
    local function write(path, text)
      local f = io.open(path, 'w')
      if f then
        f:write(text)
        f:close()
      end
    end
    local function prompt_of(index)
      local name = source.views[index].name
      if index == 1 then
        return prompt
      end
      -- `jql> ` becomes `jql [people]> `
      local head, tail = prompt:match '^(.-)(>?%s*)$'
      return ('%s [%s]%s'):format(head, name, tail)
    end
    local function apply(index)
      source.view_index = index
      -- quoted for the shell, which reads them back with `eval "set -- ..."`, so they can have spaces (`Story Points`)
      write(args_file, table.concat(vim.tbl_map(vim.fn.shellescape, source.views[index].args or {}), ' '))
      write(prompt_file, prompt_of(index))
    end
    apply(source.view_index)
    prompt = prompt_of(source.view_index)
    view_set = ('eval "set -- $(cat %s 2>/dev/null)"; '):format(vim.fn.shellescape(args_file))
    view_args = ' "$@"'
    fzf_actions['alt-c'] = {
      fn = function()
        apply(source.view_index % #source.views + 1)
      end,
      reload = true,
      postfix = ('transform-prompt(cat %s)'):format(vim.fn.shellescape(prompt_file)),
    }
    table.insert(header, 'alt-c columns')
  end
  -- alt-f switches the prompt between the query, which reloads the results from the server, and a filter of the
  -- results already listed, fuzzy over the whole row, like fzf-lua's live grep ↔ fuzzy toggle. Entering the filter keeps
  -- the query in a file and unbinds `change` so nothing reloads; leaving it puts the query and the prompt back (the
  -- prompt of the current view, after alt-c) and rebinds `change`, which runs the query once more (fzf fires `change`
  -- after the whole chain, so it cannot be restored before the rebind).
  local filter_mode, filter_query = vim.fn.tempname(), vim.fn.tempname()
  local filter_prompt = source.view_state and (source.view_state .. '.prompt') or vim.fn.tempname()
  if not source.view_state then
    local f = io.open(filter_prompt, 'w')
    if f then
      f:write(prompt)
      f:close()
    end
  end
  local m, q, p = vim.fn.shellescape(filter_mode), vim.fn.shellescape(filter_query), vim.fn.shellescape(filter_prompt)
  fzf_keymap['alt-f'] = table.concat({
    ('transform:if [ -e %s ]; then rm -f %s;'):format(m, m),
    ('echo "transform-query(cat %s)+rebind(change)+disable-search+transform-prompt(cat %s)";'):format(q, p),
    ('else : > %s; printf %%s {q} > %s;'):format(m, q),
    'echo "unbind(change)+clear-query+enable-search+change-prompt(filter> )"; fi',
  }, ' ')
  table.insert(header, 'alt-f filter')
  -- a source with `sort` lists ways to sort its results (`sort -f tsv`: label, then the query with its sort replaced);
  -- alt-s picks one on the terminal and it becomes the query, so the server sorts, and saved queries keep the order
  if source.sort then
    local sort_tmp = vim.fn.tempname()
    local sort_cmd = ('%s -l %s sort --cmd %s%s -- {q}'):format(
      vim.fn.shellescape(vim.v.progpath),
      vim.fn.shellescape(cli_path()),
      vim.fn.shellescape(backend),
      source.view_state and (' --args-file ' .. vim.fn.shellescape(source.view_state)) or ''
    )
    fzf_keymap['alt-s'] = ('execute(%s > %s || printf %%s {q} > %s)+transform-query(cat %s)'):format(sort_cmd, sort_tmp, sort_tmp, sort_tmp)
    table.insert(header, 'alt-s sort')
  end
  -- a source with `header_row` prints a line of column headings first (`search --header`), which fzf keeps on top
  local header_flag = source.header_row and ' --header' or ''
  vim.list_extend(header, { 'alt-e edit' })
  if in_window then
    table.insert(header, 'alt-w window')
  end
  if source.saved then
    vim.list_extend(header, { '^r saved', '^s save' })
  end
  table.insert(header, '^q buffer')

  -- the query is written to a file at each reload, so that resume() reopens the picker where it was left
  source.query_state = source.query_state or vim.fn.tempname()
  M.last_source = source
  local record = ('printf %%s <query> > %s; '):format(vim.fn.shellescape(source.query_state))
  local search_cmd = ('{ %s%s search -f fzf -l %d%s%s%s -- <query>; } 2>&1%s'):format(
    view_set,
    backend,
    source.limit or 100,
    tree_flag,
    header_flag,
    view_args,
    tree_filter
  )
  fzf.fzf_live(record .. 'sleep 0.3; ' .. search_cmd, {
    liveq_source = source.name, -- tells resume() that fzf-lua's last picker is this one
    prompt = prompt,
    query = query,
    search = query,
    exec_empty_query = true,
    keymap = { fzf = fzf_keymap },
    winopts = { title = ' ' .. source.title .. ' ', preview = { layout = 'vertical', vertical = 'down:50%' }, on_create = on_create },
    preview = image_env .. preview_prefix .. backend .. ' show' .. preview_flags .. preview_match .. ' -- {1}' .. preview_tee .. preview_suffix,
    fzf_opts = {
      ['--listen'] = source.match and true or nil, -- exports $FZF_PORT to the preview command
      ['--ansi'] = true,
      ['--delimiter'] = '\t',
      ['--with-nth'] = '2',
      ['--multi'] = true,
      ['--header'] = wrap_header(header),
      ['--header-lines'] = source.header_row and 1 or nil,
    },
    actions = fzf_actions,
  })
end

--- Reopens the last search of a source (of the last searched source, when nil). A picker hidden with fzf-lua's
--- <M-Esc> comes back as it was, cursor and selection included; otherwise the search runs again with the last query.
function M.resume(source)
  source = source or M.last_source
  if not source then
    vim.notify('liveq: no search to resume', vim.log.levels.WARN)
    return
  end
  local ok, win = pcall(require, 'fzf-lua.win')
  local data = ok and require('fzf-lua.config').__resume_data
  local hidden = ok and win.__SELF()
  if hidden and hidden:hidden() and data and data.opts and data.opts.liveq_source == source.name then
    hidden:unhide()
    return
  end
  local query
  local file = source.query_state and io.open(source.query_state, 'r')
  if file then
    query = (file:read '*a'):gsub('\n+$', '')
    file:close()
  end
  M.search(source, query)
end

--- Picks a saved query (`<backend> saved -f tsv`: label, query, key, origin) and searches with it. opts.back: the
--- query of the search it was opened from (ctrl-r), which esc goes back to instead of closing.
function M.saved(source, opts)
  opts = opts or {}
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
    -- the `hide` profile of fzf-lua replaces the esc action with hiding the picker, so without no_hide esc would not go
    -- back to the search; esc is mapped in the window so that the `<Esc><Esc>` terminal mapping does not hold it back
    no_hide = opts.back ~= nil,
    winopts = {
      title = ' Saved: ' .. source.title .. ' ',
      height = 0.4,
      on_create = opts.back and function(e)
        vim.keymap.set('t', '<Esc>', '<Esc>', { buffer = e.bufnr, nowait = true })
      end or nil,
    },
    fzf_opts = { ['--ansi'] = true, ['--delimiter'] = '\t', ['--with-nth'] = '2,3' },
    actions = {
      ['enter'] = function(selected)
        if query_of(selected) then
          M.search(source, query_of(selected))
        end
      end,
      ['alt-e'] = function(selected)
        if query_of(selected) then
          require('liveq.buffer').open(source, query_of(selected))
        end
      end,
      ['esc'] = opts.back and function()
        M.search(source, opts.back)
      end or nil,
    },
  })
end

return M
