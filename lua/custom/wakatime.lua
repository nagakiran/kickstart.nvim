-- Current-project WakaTime "today" time for the statusline.
--
-- Calls `waka-today --project <project>` asynchronously and caches the result,
-- so lualine never blocks on rendering and the API is hit at most once per
-- refresh interval (not once per redraw).

local M = {}

M.text = ''

local SCRIPT = vim.fn.expand '~/.local/bin/waka-today'
local timer = nil

-- WakaTime derives the project name from the project/git root folder. vim-rooter
-- already sets cwd to that root, so its basename matches the WakaTime project.
local function current_project()
  return vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
end

function M.refresh()
  if vim.fn.executable(SCRIPT) == 0 then
    return
  end
  local project = current_project()
  if project == '' then
    return
  end
  vim.system({ SCRIPT, '--project', project }, { text = true }, function(obj)
    local out = (obj.code == 0 and obj.stdout or ''):gsub('%s+$', '')
    vim.schedule(function()
      M.text = out
      -- nudge lualine to repaint with the new value
      pcall(function()
        require('lualine').refresh()
      end)
    end)
  end)
end

function M.component()
  if M.text == '' then
    return ''
  end
  return '󰔠 ' .. M.text
end

-- Start a periodic refresh plus an immediate one, and refresh on project switch.
function M.start(interval_ms)
  if timer then
    return
  end
  M.refresh()
  timer = vim.uv.new_timer()
  timer:start(interval_ms or 120000, interval_ms or 120000, function()
    vim.schedule(M.refresh)
  end)
  vim.api.nvim_create_autocmd('DirChanged', {
    callback = function()
      M.text = ''
      M.refresh()
    end,
  })
end

return M
