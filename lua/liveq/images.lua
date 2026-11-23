-- Real images over fzf's preview, for sources whose `show --images` draws images (`images = true`).
--
-- fzf-lua runs fzf in a Neovim :terminal, which drops the kitty graphics protocol, so a preview can only draw images
-- as coloured block characters (chafa). Neovim itself can show real ones, through image.nvim. The backend gets the
-- file named by $LIVEQ_IMAGE_FILE (and the cell's shape, $LIVEQ_FONT_RATIO, so its block art has the image's shape):
-- it puts a caption `[image K/N]` above each image it draws and writes a line per image to the file,
-- `K \t columns \t rows \t path`. While the picker is open, the captions on fzf's screen (the terminal buffer) are
-- looked for a few times a second, and image.nvim draws each image over the block art below its caption, cropped at
-- the bottom of the window; one whose caption has scrolled out of sight stays block art.
--
-- Needs image.nvim with a backend that can draw (kitty, also through tmux with allow-passthrough); without it the
-- preview just keeps the block art.

local M = {}

local INTERVAL = 120 -- ms between looks at the screen

--- The cell's size in pixels when image.nvim can draw, else nil.
local function cell_size()
  local ok, image = pcall(require, 'image')
  if not ok or not (image.is_enabled and image.is_enabled()) then
    return nil
  end
  local ok_term, term = pcall(require, 'image.utils.term')
  local size = ok_term and term.get_size()
  if not size or not size.cell_width or size.cell_width == 0 then
    return nil
  end
  return size
end

--- The environment for the preview command (a shell prefix), or '' when image.nvim cannot draw here.
function M.env(layout_file)
  local size = cell_size()
  if not size then
    return ''
  end
  return ('LIVEQ_IMAGE_FILE=%s LIVEQ_FONT_RATIO=%d/%d '):format(vim.fn.shellescape(layout_file), size.cell_width, size.cell_height)
end

local function read_layout(path)
  local layout = {}
  local file = io.open(path, 'r')
  if not file then
    return layout
  end
  for line in file:lines() do
    local k, cols, rows, img = line:match '^(%d+)\t(%d+)\t(%d+)\t(.+)$'
    if k then
      layout[tonumber(k)] = { cols = tonumber(cols), rows = tonumber(rows), path = img }
    end
  end
  file:close()
  return layout
end

--- Watches the picker's terminal buffer `buf` and draws the images of `layout_file` over their block art.
function M.attach(buf, layout_file)
  if not cell_size() then
    return
  end
  local image_api = require 'image'
  local shown = {} -- key (path and place) -> image
  local timer = assert(vim.uv.new_timer())

  local function clear(keep)
    for key, img in pairs(shown) do
      if not (keep and keep[key]) then
        pcall(img.clear, img)
        shown[key] = nil
      end
    end
  end

  local function scan()
    if not vim.api.nvim_buf_is_valid(buf) then
      clear()
      -- both a pending timer tick and the BufWipeout autocmd can land here: close once
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      return
    end
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
      return clear() -- hidden (fzf-lua's alt-esc): back when it is unhidden
    end
    local top, bottom = vim.fn.line('w0', win), vim.fn.line('w$', win)
    local lines = vim.api.nvim_buf_get_lines(buf, top - 1, bottom, false)
    local layout, want = nil, {}
    for i, line in ipairs(lines) do
      local start, _, k = line:find '%[image (%d+)/%d+%]'
      if start then
        layout = layout or read_layout(layout_file)
        local entry = layout[tonumber(k)]
        if entry then
          -- the image starts on the row below its caption (rows are 0-based from the window's top)
          local x, y = vim.fn.strdisplaywidth(line:sub(1, start - 1)), i
          if y < #lines then
            want[('%s@%d,%d'):format(entry.path, x, y)] = { path = entry.path, x = x, y = y, cols = entry.cols, rows = entry.rows }
          end
        end
      end
    end
    clear(want)
    for key, g in pairs(want) do
      if not shown[key] then
        local ok, img = pcall(image_api.from_file, g.path, {
          window = win,
          x = g.x,
          y = g.y,
          width = g.cols,
          height = g.rows,
          max_width_window_percentage = 100,
          max_height_window_percentage = 100,
        })
        if ok and img then
          pcall(img.render, img)
          shown[key] = img
        end
      end
    end
  end

  timer:start(INTERVAL, INTERVAL, vim.schedule_wrap(scan))
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(scan) -- the buffer is gone: clears and stops
    end,
  })
end

return M
