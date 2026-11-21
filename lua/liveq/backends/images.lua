-- Images in liveq's previews and galleries, shared by the backends that have them (teams.lua, notmuch.lua), loaded
-- with dofile (they run with `nvim -l`).
--
-- Drawn by kitten (kitty's unicode placeholders: real pixels that fzf scrolls with the text, through tmux too, with
-- allow-passthrough) when fzf runs straight in kitty or Ghostty, else by chafa as coloured block characters, which
-- fzf shows anywhere, Neovim's :terminal (fzf-lua's picker) included. LIVEQ_IMAGE_FORMAT forces one: symbols, kitty,
-- sixels or iterm (the last two need a terminal and an fzf that pass them, never Neovim's).

local M = {}

function M.format()
  local forced = os.getenv 'LIVEQ_IMAGE_FORMAT' or os.getenv 'LIVEQ_TEAMS_IMAGE_FORMAT'
  if forced and forced ~= '' then
    return forced
  end
  local kitty = os.getenv 'KITTY_WINDOW_ID' or os.getenv 'GHOSTTY_RESOURCES_DIR' or (os.getenv 'TERM' or ''):match 'kitty'
  -- Neovim's terminal (fzf-lua) drops the kitty protocol, though the variables say kitty
  if kitty and not os.getenv 'NVIM' and vim.fn.executable 'kitten' == 1 then
    return 'kitty'
  end
  return vim.fn.executable 'chafa' == 1 and 'symbols' or nil
end

--- The lines of kitten's unicode-placeholder output as fzf can show them: the image's transmission ahead of the first
--- line, the colour that carries the image's id on every line, no cursor moves.
function M.kitty_lines(output)
  local transmit, rest = output:match '^\r?(.*\27\\)(.*)$'
  if not transmit then
    return nil
  end
  local colour = rest:match '\27%[38[:;][%d:;]*m'
  if not colour then
    return nil
  end
  colour = colour:gsub(':', ';')
  rest = rest:gsub('\27%[38[:;][%d:;]*m', ''):gsub('\27%[39m', ''):gsub('\27[78]', ''):gsub('\27%[%d*;?%d*H', '')
  local lines = {}
  for line in vim.gsplit(rest, '\n', { plain = true }) do
    line = line:gsub('\r', ''):gsub('\27%[%d*C', '')
    if line ~= '' then
      table.insert(lines, colour .. line .. '\27[39m')
    end
  end
  if #lines > 0 then
    lines[1] = transmit .. lines[1]
  end
  return lines
end

--- Starts drawing `file` into `cols` x `rows` cells (kept in proportion) in `format`; finish() takes the job.
--- `font_ratio`: a cell's width/height, for chafa (e.g. '9/19').
function M.start(file, cols, rows, format, font_ratio)
  local cmd = format == 'kitty'
      and {
        'kitten',
        'icat',
        '--stdin=no',
        '--unicode-placeholder',
        -- a stream, not shared memory, so fzf can send it again when the preview scrolls back to it
        '--transfer-mode=stream',
        '--background=white', -- behind transparent pixels
        -- kitten's own conversion (0.46) turns some white areas of screenshots black; ImageMagick's does not
        vim.fn.executable 'magick' == 1 and '--engine=magick' or '--engine=auto',
        ('--place=%dx%d@0x0'):format(cols, rows),
        file,
      }
    or {
      'chafa',
      '-f',
      format,
      '-s',
      ('%dx%d'):format(cols, rows),
      '--animate=off',
      '--polite=on',
      '--font-ratio=' .. (font_ratio or '1/2'),
      file,
    }
  local ok, job = pcall(vim.system, cmd, { text = true })
  return ok and job or nil
end

--- The lines of a drawing that start() started; nil when it failed (kitten does where there is no terminal to ask
--- the size of a cell: draw again with 'symbols').
function M.finish(job, format)
  local result = job:wait(10000)
  local output = result.code == 0 and result.stdout or ''
  local lines
  if format == 'kitty' then
    lines = M.kitty_lines(output)
  elseif output ~= '' then
    lines = vim.split(output:gsub('\n$', ''), '\n', { plain = true })
  end
  return lines and #lines > 0 and lines or nil
end

--- Draws one image as large as fzf's preview (for a gallery), as lines; with kitty's fallback to block art.
function M.draw_big(file)
  local width = tonumber(os.getenv 'FZF_PREVIEW_COLUMNS') or tonumber(os.getenv 'LIVEQ_WIDTH') or 80
  local rows = math.max(8, (tonumber(os.getenv 'FZF_PREVIEW_LINES') or 30) - 1)
  local format = M.format()
  if not format then
    return { '(no image viewer: kitten or chafa)' }
  end
  local job = M.start(file, math.max(8, width - 1), rows, format)
  local lines = job and M.finish(job, format)
  if not lines and format == 'kitty' and vim.fn.executable 'chafa' == 1 then
    job = M.start(file, math.max(8, width - 1), rows, 'symbols')
    lines = job and M.finish(job, 'symbols')
  end
  return lines or { '(could not draw ' .. file .. ')' }
end

--- The file as PNG (the clipboard's format), converted (sips on macOS, else ImageMagick) when it is not one.
function M.as_png(file)
  local f = io.open(file, 'rb')
  local head = f and f:read(8)
  if f then
    f:close()
  end
  if head == '\137PNG\r\n\26\n' then
    return file
  end
  local png = file .. '.png'
  if vim.uv.fs_stat(png) then
    return png
  end
  local cmd = vim.fn.has 'mac' == 1 and { 'sips', '-s', 'format', 'png', file, '--out', png } or { 'magick', file, 'png:' .. png }
  local ok, job = pcall(vim.system, cmd, { text = true })
  return ok and job:wait(20000).code == 0 and png or nil
end

--- The image as a .png file, for what goes by the extension (a viewer, kitty's open actions): a hard link to it when
--- it is a PNG, else a conversion.
function M.link_file(file)
  local png = file .. '.png'
  if vim.uv.fs_stat(png) then
    return png
  end
  local converted = M.as_png(file)
  if converted == file then
    return vim.uv.fs_link(file, png) and png or nil
  end
  return converted
end

--- Puts the image on the clipboard as PNG (macOS, or Wayland/X11 with wl-copy/xclip); nil and an error otherwise.
function M.copy(file)
  local png = M.as_png(file)
  if not png then
    return nil, 'could not convert the image to PNG'
  end
  local cmd
  if vim.fn.has 'mac' == 1 then
    cmd = { 'osascript', '-e', ('set the clipboard to (read (POSIX file "%s") as «class PNGf»)'):format(png) }
  elseif os.getenv 'WAYLAND_DISPLAY' and vim.fn.executable 'wl-copy' == 1 then
    cmd = { 'sh', '-c', 'wl-copy --type image/png < "$1"', 'sh', png }
  elseif os.getenv 'DISPLAY' and vim.fn.executable 'xclip' == 1 then
    cmd = { 'xclip', '-selection', 'clipboard', '-t', 'image/png', '-i', png }
  else
    return nil, 'no clipboard for images here (macOS, or wl-copy / xclip with a display)'
  end
  local result = vim.system(cmd, { text = true }):wait(10000)
  if result.code ~= 0 then
    return nil, 'copying failed: ' .. vim.trim(result.stderr or '')
  end
  return true
end

--- Opens the image in the system's image viewer (which goes by the file's extension).
function M.open(file)
  local shown = M.link_file(file) or file
  vim.system(vim.fn.has 'mac' == 1 and { 'open', shown } or { 'xdg-open', shown }, { detach = true })
end

return M
