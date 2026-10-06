-- Keep a wrapped render-markdown table row formatted while the cursor sits on it.
--
-- With pipe_table.wrap, render-markdown draws a row that doesn't fit the window by hiding
-- the source line (`conceal_lines`) and showing virtual lines in its place. Virtual lines
-- can't hold the cursor, so the plugin always reveals the raw line under the cursor
-- (core/ui.lua, "virtual row -> no editable screen cells -> must hide").
--
-- This keeps that raw line visible (the cursor needs it) but paints the rendered row over
-- it: fragment i is overlaid on the i-th screen row of the soft-wrapped source line, padded
-- to the full text width so no raw text shows through. Conceal can't be used instead,
-- because Neovim still reserves the full wrapped height for concealed text. Fragments that
-- don't fit in the line's screen rows go into virtual lines below; if the line has more
-- screen rows than fragments, the extra rows get empty cells.
--
-- Only applies in modes listed in anti_conceal.disabled_modes (n/c/t here); in insert mode
-- the raw row is left alone so it can be edited.
--
-- Hooks render-markdown's internal Updater (core/ui.lua), so a plugin update that renames
-- display/clear will silently turn this off rather than error.
local M = {}

local ns = vim.api.nvim_create_namespace 'render-markdown-cursor-row'

---@param chunks [string, string|string[]][]
---@return integer
local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(chunk[1])
  end
  return width
end

-- A table border line (┌─┬─┐ / └─┴─┘) that render-markdown folded into the row's lines.
---@param chunks [string, string|string[]][]
---@param bar string
local function is_border(chunks, bar)
  local text = ''
  for _, chunk in ipairs(chunks) do
    text = text .. chunk[1]
  end
  return not text:find(bar, 1, true) and vim.trim(text) ~= ''
end

-- Same row with every cell emptied, for screen rows that have no fragment left.
---@param chunks [string, string|string[]][]
---@param bar string
local function blank(chunks, bar)
  return vim.tbl_map(function(chunk)
    local text = chunk[1]:gsub('[%z\1-\127\194-\244][\128-\191]*', function(char)
      return char == bar and char or string.rep(' ', vim.fn.strdisplaywidth(char))
    end)
    return { text, chunk[2] }
  end, chunks)
end

-- 0-based byte column where each visible screen row of buffer line `row` starts.
---@param win integer
---@param row integer
---@return integer[]
local function screen_row_starts(win, row)
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), row, row + 1, false)[1] or ''
  local starts, last = {}, nil
  for _, byte in ipairs(vim.str_utf_pos(line)) do
    local pos = vim.fn.screenpos(win, row + 1, byte)
    if pos.row == 0 then
      break -- rest of the line is scrolled out of view
    end
    if pos.row ~= last then
      starts[#starts + 1] = byte - 1
      last = pos.row
    end
  end
  return #starts > 0 and starts or { 0 }
end

---@param updater table render-markdown's core/ui Updater instance
local function paint(updater)
  local buf, win = updater.buf, updater.win
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end

  local config = updater.config
  local anti = config.anti_conceal
  local env = require 'render-markdown.lib.env'
  if anti.enabled and not env.mode.is(updater.mode, anti.disabled_modes) then
    return
  end

  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local lines
  for _, extmark in ipairs(updater.decorator.marks or {}) do
    local mark = extmark:get()
    if mark.replace and mark.start_row == row then
      lines = mark.replace
      break
    end
  end
  if not lines then
    return
  end

  local bar = config.pipe_table.border[10]
  local above, fragments, below = {}, {}, {}
  for _, chunks in ipairs(lines) do
    if is_border(chunks, bar) then
      table.insert(#fragments == 0 and above or below, chunks)
    else
      fragments[#fragments + 1] = chunks
    end
  end
  if #fragments == 0 then
    return
  end

  local text_width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  local starts = screen_row_starts(win, row)
  for i, col in ipairs(starts) do
    local chunks = vim.deepcopy(fragments[i] or blank(fragments[1], bar))
    local pad = text_width - chunks_width(chunks)
    if pad > 0 then
      chunks[#chunks + 1] = { string.rep(' ', pad) }
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
      virt_text = chunks,
      virt_text_win_col = 0,
      priority = 4096,
    })
  end

  local extra = vim.list_slice(fragments, #starts + 1)
  vim.list_extend(extra, below)
  if #above > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = above, virt_lines_above = true })
  end
  if #extra > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = extra })
  end
end

function M.setup()
  local ok, ui = pcall(require, 'render-markdown.core.ui')
  local Updater = ok and ui.updater
  if not Updater or type(Updater.display) ~= 'function' or type(Updater.clear) ~= 'function' then
    return
  end

  local display, clear = Updater.display, Updater.clear
  Updater.display = function(self, ...)
    display(self, ...)
    local painted, err = pcall(paint, self)
    if not painted then
      vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
      vim.notify_once('render_markdown_cursor_row: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
  Updater.clear = function(self, ...)
    clear(self, ...)
    vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  end
end

return M
