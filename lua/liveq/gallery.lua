-- The gallery of an item's images (alt-g of liveq's picker, for sources with `gallery = true`): a picker of the rows
-- of the backend's `images -f fzf -- ID` (`KEY \t display \t\t title`), the image under the cursor in the preview
-- (`image -- KEY`, as large as the preview), `enter` copying it to the clipboard (`image --copy`) and ctrl-o opening
-- it in the image viewer (`image --open`). In Neovim's terminal the preview is block art; in the shell's `lq` (and its
-- tmux window, alt-w) real images.

local util = require 'liveq.util'

local M = {}

local function run(source, args, done)
  local cmd = util.cmd(source)
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify(vim.trim((result.stderr or '') .. (result.stdout or '')), vim.log.levels.ERROR, { title = source.title })
      elseif done then
        done()
      end
    end)
  end)
end

function M.open(source, id, opts)
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    return
  end
  local backend = util.shell_cmd(source)
  local action = function(flag)
    return function(selected)
      local key = selected[1] and vim.split(selected[1], '\t', { plain = true })[1]
      if key and key ~= '' then
        run(source, { 'image', flag, '--', key }, function()
          if flag == '--copy' then
            vim.notify('Image copied to the clipboard', vim.log.levels.INFO, { title = source.title })
          end
        end)
      end
    end
  end
  -- opts.back: the query of the search the gallery was opened from (alt-g), which esc goes back to
  fzf.fzf_exec(
    backend .. ' images -f fzf -- ' .. vim.fn.shellescape(id),
    require('liveq.picker').back_to_search(source, (opts or {}).back, {
      prompt = 'images> ',
      winopts = { title = ' Images ', preview = { layout = 'vertical', vertical = 'down:75%' } },
      preview = backend .. ' image -- {1}',
      fzf_opts = { ['--ansi'] = true, ['--delimiter'] = '\t', ['--with-nth'] = '2', ['--no-sort'] = true, ['--header'] = 'enter copy · ^o open' },
      actions = { ['enter'] = action '--copy', ['ctrl-o'] = action '--open' },
    })
  )
end

return M
