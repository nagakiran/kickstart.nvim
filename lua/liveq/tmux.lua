-- The shell's picker (`lq`, ~/rcfiles/.zsh/liveq.zsh) in a tmux window of its own, for sources with `tmux`: alt-w in
-- liveq's picker moves the search there (images on), the `tmux` keymap opens it straight away, and with
-- `tmux = 'default'` the search command and keymap open it instead of liveq's picker.
--
-- A tmux window is a real terminal, not Neovim's :terminal, so fzf's preview can show what Neovim's cannot: real
-- images through the kitty protocol (Teams). Unlike a tmux popup, which takes every key, it leaves tmux's prefix
-- working, so one can switch away and back. `enter` there picks the item: the window closes, Neovim's comes back and
-- the source's `enter` action runs here with it (e.g. Teams opens the chat in a buffer). Neovim learns that the window
-- is done through `tmux wait-for` on a channel of its own, which the window's shell signals when it exits, however it
-- exits (killed included), so no socket is needed. Only when Neovim runs inside tmux and liveq.zsh is there.
--
-- The window runs a non-interactive zsh (~70ms, where an interactive one loads all of .zshrc): Neovim's environment
-- reaches it through a file of mode 600 that it sources and deletes, not through tmux's argv. NVIM is left out, so the
-- backend does not take itself to be in Neovim's terminal.

local M = {}

local ZSH_FILE = vim.env.LIVEQ_ZSH or vim.fs.joinpath(vim.env.HOME, 'rcfiles', '.zsh', 'liveq.zsh')
local SKIP = {
  PWD = true,
  OLDPWD = true,
  SHLVL = true,
  _ = true,
  TMUX_PANE = true,
  NVIM = true,
  NVIM_LISTEN_ADDRESS = true,
  NVIM_LOG_FILE = true,
  VIMRUNTIME = true,
  VIM = true,
  MYVIMRC = true,
  COLUMNS = true,
  LINES = true,
}

function M.available(source)
  return source.tmux and vim.env.TMUX ~= nil and vim.fn.executable 'tmux' == 1 and vim.fn.executable 'zsh' == 1 and vim.uv.fs_stat(ZSH_FILE) ~= nil
end

local function env_file()
  local lines = {}
  for k, v in pairs(vim.fn.environ()) do
    if not SKIP[k] and k:match '^[%a_][%w_]*$' then
      table.insert(lines, ('export %s=%s'):format(k, vim.fn.shellescape(v)))
    end
  end
  local path = vim.fn.tempname()
  local file = assert(io.open(path, 'w'))
  vim.uv.fs_chmod(path, tonumber('600', 8))
  file:write(table.concat(lines, '\n'), '\n')
  file:close()
  return path
end

local function is_id(source, id)
  local patterns = type(source.id_pattern) == 'table' and source.id_pattern or { source.id_pattern }
  if #patterns == 0 then
    return true
  end
  for _, pattern in ipairs(patterns) do
    if id:match(pattern) then
      return true
    end
  end
  return false
end

--- Opens `lq SOURCE QUERY` in a new tmux window; the picked items go to the source's `enter` action. opts.images:
--- start with the preview's images on (sources with `images`).
function M.search(source, query, opts)
  opts = opts or {}
  local env, out = env_file(), vim.fn.tempname()
  local channel = ('liveq-%d-%d'):format(vim.uv.os_getpid(), vim.uv.hrtime())
  -- the EXIT trap tells Neovim the window is done; zsh runs it on a signal only when the signal's own trap exits (a
  -- killed window sends SIGHUP)
  -- `id \t title` for each item picked (lq prints only ids unless told), into a file: the window has no stdout here
  local script = ("trap 'tmux wait-for -S %s' EXIT; trap 'exit 129' HUP TERM; . %s; rm -f %s; source %s && %sLQ_ACCEPT_NTH=1,4 lq %s %s > %s"):format(
    channel,
    vim.fn.shellescape(env),
    vim.fn.shellescape(env),
    vim.fn.shellescape(ZSH_FILE),
    (opts.images and source.images) and 'LQ_IMAGES=1 ' or '',
    vim.fn.shellescape(source.name),
    vim.fn.shellescape(query or ''),
    vim.fn.shellescape(out)
  )
  local opened = vim.system({ 'tmux', 'new-window', '-n', source.name, '-c', vim.fn.getcwd(), 'zsh', '-c', script }, { text = true }):wait(5000)
  if opened.code ~= 0 then
    os.remove(env)
    vim.notify('liveq: cannot open a tmux window: ' .. vim.trim(opened.stderr or ''), vim.log.levels.ERROR)
    return require('liveq.picker').search(source, query)
  end
  local cmd = { 'tmux', 'wait-for', channel }
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      os.remove(env)
      local items = {}
      local file = io.open(out, 'r')
      if file then
        for line in file:lines() do
          local id, title = line:match '^([^\t]+)\t?(.*)$'
          if id and is_id(source, id) then
            table.insert(items, { id = id, title = title ~= '' and title or id })
          end
        end
        file:close()
      end
      os.remove(out)
      local enter = source.actions and source.actions.enter
      if #items > 0 and enter then
        -- back to Neovim's window (closing the picker's goes to tmux's last window, which may be another one)
        if vim.env.TMUX_PANE then
          vim.system { 'tmux', 'select-window', '-t', vim.env.TMUX_PANE }
        end
        enter.fn(items, source)
      end
    end)
  end)
end

return M
