return {
  {
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        -- Load luvit types when the `vim.uv` word is found
        { path = 'luvit-meta/library', words = { 'vim%.uv' } },
      },
    },
  },
  { 'Bilal2453/luvit-meta', lazy = true },
  {
    -- Main LSP Configuration
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'williamboman/mason.nvim', config = true }, -- NOTE: Must be loaded before dependants
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',
      { 'j-hui/fidget.nvim', opts = {} },
      'hrsh7th/cmp-nvim-lsp',
    },
    config = function()
      -- The default WARN level lets a misbehaving server write unboundedly: copilot's
      -- OrgCustomAgentClient 404s every 5 minutes and checkStatus returns HTTP 502 in a loop,
      -- which had grown lsp.log to 81MB. ERROR keeps genuine failures without the heartbeat spam.
      vim.lsp.log.set_level(vim.log.levels.ERROR)

      -- Servers outlive the buffers that started them: a tsserver was still resident 6 days after
      -- its last TypeScript buffer closed, holding 3.5GB. Stop any client left with no attachments.
      --
      -- One shared timer, restarted on each event, rather than `vim.defer_fn` per event: buffers
      -- are closed in bursts (`bufreap`'s sweep retired 278 in one go, `:%bwipeout` does the same),
      -- and a timer per buffer meant hundreds of live handles plus hundreds of redundant full
      -- client scans 5s later. Restarting one timer collapses a burst into a single scan.
      local idle_timer = vim.uv.new_timer()
      vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload' }, {
        group = vim.api.nvim_create_augroup('lsp-idle-shutdown', { clear = true }),
        desc = 'Stop LSP clients once nothing is attached to them',
        callback = function()
          idle_timer:stop()
          idle_timer:start(
            5000,
            0,
            vim.schedule_wrap(function()
              for _, client in ipairs(vim.lsp.get_clients()) do
                if next(client.attached_buffers or {}) == nil then
                  client:stop()
                end
              end
            end)
          )
        end,
      })

      vim.api.nvim_create_autocmd('VimLeavePre', {
        group = vim.api.nvim_create_augroup('lsp-idle-shutdown-teardown', { clear = true }),
        callback = function()
          idle_timer:stop()
          if not idle_timer:is_closing() then
            idle_timer:close()
          end
        end,
      })

      -- `textDocument/hover` renders whatever the server chooses to send, and tsserver/tsgo (like
      -- gopls and pyright) send the signature plus the doc comment — never the body. Reading the
      -- implementation without leaving the buffer means asking for the definition instead and
      -- showing the source lines at the target. Falls back to hover when there is no definition
      -- (a type-only symbol, a keyword).

      -- Caps the *window*, not the contents: the buffer holds the whole declaration and the float
      -- scrolls (see attach_scrollbar).
      local PEEK_MAX_HEIGHT = 30
      -- Without a parser there is no way to know where the declaration ends, so show a fixed span.
      local PEEK_FALLBACK_LINES = 60

      -- A plain Location — and a LocationLink from a server that reports only the name's range —
      -- points at the identifier, not the declaration. Walk up to the outermost syntax node that
      -- still starts on that line to recover the whole function/class body.
      local function expand_to_declaration(bufnr, srow, scol)
        local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { srow, scol } })
        if not ok or not node then
          return srow, srow + PEEK_FALLBACK_LINES - 1
        end
        while true do
          local parent = node:parent()
          -- Stop below the root, or it would swallow the entire file for a line-0 declaration.
          if not parent or not parent:parent() or parent:start() ~= srow then
            break
          end
          node = parent
        end
        local nsrow, _, nerow = node:range()
        return nsrow, nerow
      end

      local peek_scroll_ns = vim.api.nvim_create_namespace 'peek-definition-scrollbar'

      -- Floats have no native scrollbar, and a preview capped at PEEK_MAX_HEIGHT gives no hint that
      -- there is more below. Draw one in a one-column companion float pinned over the preview's
      -- right border, redrawn on every scroll of the preview window.
      local function attach_scrollbar(fwin)
        if vim.w[fwin].peek_scrollbar then
          return
        end
        local height = vim.api.nvim_win_get_height(fwin)
        local total = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(fwin))
        if total <= height then
          return
        end

        local sbuf = vim.api.nvim_create_buf(false, true)
        vim.bo[sbuf].bufhidden = 'wipe'
        -- Blank cells: the bar is painted with line highlights, so it renders as a solid block in
        -- the colorscheme's own Pmenu scrollbar colours.
        local track = {}
        for _ = 1, height do
          track[#track + 1] = ' '
        end
        vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, track)

        local swin = vim.api.nvim_open_win(sbuf, false, {
          -- 'win'-relative coordinates start at the text area, so col == width is the border cell.
          relative = 'win',
          win = fwin,
          row = 0,
          col = vim.api.nvim_win_get_width(fwin),
          width = 1,
          height = height,
          focusable = false,
          style = 'minimal',
          noautocmd = true,
          zindex = (vim.api.nvim_win_get_config(fwin).zindex or 50) + 1,
        })
        vim.wo[swin].winhighlight = 'Normal:PmenuSbar,NormalFloat:PmenuSbar'
        vim.w[fwin].peek_scrollbar = swin

        local function redraw()
          if not (vim.api.nvim_win_is_valid(fwin) and vim.api.nvim_win_is_valid(swin)) then
            return
          end
          local topline = vim.fn.line('w0', fwin)
          local size = math.max(1, math.floor(height * height / total + 0.5))
          local pos = math.floor((topline - 1) * (height - size) / (total - height) + 0.5)
          vim.api.nvim_buf_clear_namespace(sbuf, peek_scroll_ns, 0, -1)
          for row = pos, math.min(pos + size, height) - 1 do
            vim.api.nvim_buf_set_extmark(sbuf, peek_scroll_ns, row, 0, { line_hl_group = 'PmenuThumb' })
          end
        end
        redraw()

        local group = vim.api.nvim_create_augroup('peek-definition-scrollbar-' .. fwin, { clear = true })
        vim.api.nvim_create_autocmd('WinScrolled', { group = group, pattern = tostring(fwin), callback = redraw })
        vim.api.nvim_create_autocmd('WinClosed', {
          group = group,
          pattern = tostring(fwin),
          callback = function()
            if vim.api.nvim_win_is_valid(swin) then
              vim.api.nvim_win_close(swin, true)
            end
            -- Deferred: deleting the group from inside one of its own callbacks.
            vim.schedule(function()
              pcall(vim.api.nvim_del_augroup_by_id, group)
            end)
          end,
        })
      end

      local function peek_definition()
        local win = vim.api.nvim_get_current_win()
        vim.lsp.buf_request_all(0, vim.lsp.protocol.Methods.textDocument_definition, function(client)
          return vim.lsp.util.make_position_params(win, client.offset_encoding)
        end, function(results)
          local target
          for _, res in pairs(results) do
            local r = res.result
            if type(r) == 'table' then
              -- Location | LocationLink | (Location|LocationLink)[]
              target = (r.uri or r.targetUri) and r or r[1]
              if target then
                break
              end
            end
          end

          if not target then
            vim.lsp.buf.hover()
            return
          end

          local uri = target.targetUri or target.uri
          local range = target.targetRange or target.range
          local bufnr = vim.uri_to_bufnr(uri)
          vim.fn.bufload(bufnr)

          local srow, erow = range.start.line, range['end'].line
          if erow - srow < 1 then
            srow, erow = expand_to_declaration(bufnr, srow, range.start.character)
          end
          local lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false)
          if #lines == 0 then
            return
          end

          local ft = vim.bo[bufnr].filetype
          local fbuf, fwin = vim.lsp.util.open_floating_preview(lines, ft, {
            border = 'rounded',
            -- Same contract as hover: closes on cursor move, and pressing the key a second time
            -- jumps into the float (so its contents can be scrolled or yanked).
            focus_id = 'peek-definition',
            title = string.format('%s:%d', vim.fn.fnamemodify(vim.uri_to_fname(uri), ':~:.'), srow + 1),
            max_height = PEEK_MAX_HEIGHT,
            wrap = false,
          })
          -- Both of open_floating_preview's re-focus paths return an already-open float — and the
          -- one taken from inside the float returns the *source* buffer and window. Only touch a
          -- float we just built.
          if vim.bo[fbuf].buftype ~= 'nofile' then
            return
          end
          -- open_floating_preview sets 'syntax', which does not fire FileType, so treesitter never
          -- starts (see the global FileType hook in custom/plugins/treesitter.lua). Set the option
          -- that does.
          vim.bo[fbuf].filetype = ft
          attach_scrollbar(fwin)
        end)
      end

      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          -- Fugitive blob buffers (fugitive://<gitdir>//<sha>/<path> — a file at a revision,
          -- see lua/gitctx.lua) have buftype='' and a real filetype, so vim.lsp.enable()
          -- attaches servers to them. Servers can't resolve a fugitive:// URI, and
          -- diagnostics against historic contents are noise, so back out here.
          if vim.api.nvim_buf_get_name(event.buf):match '^fugitive://' then
            vim.lsp.buf_detach_client(event.buf, event.data.client_id)
            vim.diagnostic.enable(false, { bufnr = event.buf })
            return
          end

          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          map('gd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')
          map('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')
          map('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')
          map('<leader>D', require('telescope.builtin').lsp_type_definitions, 'Type [D]efinition')
          map('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')
          map('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')
          map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
          map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' })
          map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
          -- will be useful to look at definition in a preview [good thing is hover goes away only on moving mouse and not like pressing Esc]
          map('<leader>ph', vim.lsp.buf.hover, 'LS[P] [H]over')
          map('<leader>pd', peek_definition, '[P]eek [D]efinition body')

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client:supports_method(vim.lsp.protocol.Methods.textDocument_inlayHint) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

      -- gopls is configured here via the native vim.lsp.config() API (Neovim 0.11) rather than
      -- through the `servers` table below. Reason: nvim 0.11 + mason-lspconfig v2 dropped the old
      -- lspconfig `handlers` mechanism, so any per-server opts in that table are silently ignored.
      -- Configuring gopls natively also lets us pin our self-built gopls (v0.22.0, go1.26) instead
      -- of Mason's stale v0.16.2 — Mason prepends its bin dir to PATH, so a bare `gopls` would
      -- resolve to the old Nov-2024 copy. lspconfig's lsp/gopls.lua supplies the base
      -- cmd/filetypes/root_dir; we override cmd + capabilities + settings on top of it.
      vim.lsp.config('gopls', {
        cmd = { vim.fn.expand '~/go/bin/gopls' },
        capabilities = capabilities,
        settings = {
          gopls = {
            -- Exclude generated/build artefact dirs from file watching (speeds up large monorepos)
            directoryFilters = { '-.git', '-.bazel', '-bazel-bin', '-bazel-out', '-vendor' },
            analyses = {
              unusedparams = true,
              shadow = false,
            },
            staticcheck = false, -- disable to reduce CPU on large monorepos
            gofumpt = false,
            usePlaceholders = true,
            completeUnimported = true,
            -- This is a Bazel monorepo: proto .pb.go files are generated by Bazel at build time
            -- and not committed. The standard `go list` driver fails because those packages have
            -- no .go files on disk. GOPACKAGESDRIVER tells gopls to use the Bazel-aware driver
            -- (built from @io_bazel_rules_go//go/tools/gopackagesdriver) which queries Bazel for
            -- package metadata instead. The driver gracefully falls back outside Bazel workspaces.
            env = vim.tbl_extend('force', {
              GOPRIVATE = 'eng-hs-gitlab.juniper.net',
              GONOSUMDB = 'eng-hs-gitlab.juniper.net',
              GONOPROXY = 'eng-hs-gitlab.juniper.net',
            }, vim.uv.os_uname().sysname == 'Darwin' and {
              -- Bazel-aware packages driver; needed on macOS where `go list` fails for
              -- proto-generated packages not committed to the repo. Not required on Linux.
              GOPACKAGESDRIVER = vim.fn.expand '~/go/bin/gopackagesdriver-wrapper',
            } or {}),
          },
        },
      })
      vim.lsp.enable 'gopls'

      -- Trial: TypeScript 7 native preview (`tsgo`, a Go binary) in place of node's tsserver, for
      -- stockscreener only. Measured on packages/frontend, full --noEmit typecheck:
      --   tsgo  0.40s, 517MB peak RSS
      --   tsc 5.9.3  2.14s, 732MB peak RSS
      -- i.e. ~5x faster and ~29% less memory on the same object graph. Scoped to one tree so the
      -- rest of the setup keeps the known-good ts_ls; widen TSGO_ROOTS once it has proven itself.
      -- Configured outside `servers` (like gopls) because mason has no package for it and
      -- mason-tool-installer installs every key of that table.
      local TSGO_ROOTS =
        { '/opt/nagki/myprojs/stockscreener', '/Users/nagakiran/stormbreaker/security_director', '/Users/nagakiran/stormbreaker/security_director/naas/sd/ui' }

      local function tsgo_root_for(bufnr)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        if fname == '' then
          return nil
        end
        local norm = vim.fs.normalize(fname)
        for _, root in ipairs(TSGO_ROOTS) do
          if norm == root or norm:sub(1, #root + 1) == root .. '/' then
            return root
          end
        end
        return nil
      end

      vim.lsp.config('tsgo', {
        cmd = { 'tsgo', '--lsp', '--stdio' },
        filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'typescript.tsx' },
        -- Not calling on_dir() declines the buffer, which is how tsgo stays confined to TSGO_ROOTS.
        root_dir = function(bufnr, on_dir)
          local root = tsgo_root_for(bufnr)
          if root then
            on_dir(root)
          end
        end,
      })
      vim.lsp.enable 'tsgo'

      -- pyenv's myenv (scripts/install-deps.sh python) when it exists; otherwise pyright's own discovery
      local pyenv_versions = (vim.env.PYENV_ROOT or (vim.env.HOME .. '/.pyenv')) .. '/versions'
      local servers = {
        pyright = {
          settings = {
            python = vim.uv.fs_stat(pyenv_versions .. '/myenv') and { venvPath = pyenv_versions, venv = 'myenv' } or {},
          },
        },
        eslint = {},
        ts_ls = {
          -- Native (nvim 0.11) root_dir signature: (bufnr, on_dir).
          --
          -- Scope tsserver to vim-rooter's project root, not to the nearest tsconfig.json: the
          -- monorepos contain nested tsconfig.json files that are not the effective config for a
          -- given file, so a nearest-match search picks the wrong project. Rooter already resolves
          -- the root for the window (see custom/plugins/init.lua), which makes `.vim_rooter` the
          -- one knob for both: dropping that marker at a sub-project boundary narrows nvim's cwd
          -- and tsserver's program together, instead of loading a whole monorepo as one program.
          --
          -- Resolve with vim.fs.root() rather than getcwd(): rooter chdirs with `lcd`
          -- (window-local) and this callback can run for a buffer that is not in the current
          -- window.
          root_dir = function(bufnr, on_dir)
            -- Hand the tsgo trial roots over exclusively; two TypeScript servers on one buffer
            -- would double the memory this is meant to reduce.
            if tsgo_root_for(bufnr) then
              return
            end
            local fname = vim.api.nvim_buf_get_name(bufnr)
            local patterns = vim.g.rooter_patterns or { '.vim_rooter', '.git' }
            on_dir(vim.fs.root(fname, patterns) or vim.fs.dirname(fname))
          end,
          init_options = {
            -- Need to use when specific tsconfig to be chosen like atom/stockscreener
            -- tsconfig = vim.fn.getcwd() .. '/tsconfig.json',
            --
            -- tsserver grows to whatever it is allowed to and never gives it back: measured 3.5GB
            -- (stockscreener) and 2.0GB (security_director) after ~6 days. The cap makes it collect
            -- instead of grow. Type acquisition adds @types downloads for untyped deps on top.
            maxTsServerMemory = 3072,
            disableAutomaticTypingAcquisition = true,
          },
        },
        jdtls = {
          cmd = function(config)
            local root = config.root_dir or vim.uv.cwd()
            local workspace = vim.fn.expand '~/.cache/jdtls/workspace/' .. root:gsub('[/\\]', '_')
            return {
              'jdtls',
              '-configuration',
              vim.fn.expand '~/.cache/jdtls/config',
              '-data',
              workspace,
            }
          end,
          root_dir = function(bufnr, on_dir)
            local fname = vim.api.nvim_buf_get_name(bufnr)
            on_dir(vim.fs.root(fname, '.classpath') or vim.fs.root(fname, '.git') or vim.uv.os_homedir())
          end,
        },
        lua_ls = {
          settings = {
            Lua = {
              completion = {
                callSnippet = 'Replace',
              },
            },
          },
        },
      }

      -- nvim 0.11 + mason-lspconfig v2 dropped the `handlers` callback API: it auto-enables
      -- installed servers via vim.lsp.enable() and reads each server's config from
      -- vim.lsp.config[name]. So register capabilities globally ('*' merges into every server)
      -- and push each server's overrides through the native vim.lsp.config(). (gopls is
      -- configured + enabled separately above so we can pin its binary.)
      vim.lsp.config('*', { capabilities = capabilities })
      for name, cfg in pairs(servers) do
        vim.lsp.config(name, cfg)
      end

      require('mason').setup()

      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua',
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      -- Auto-installs + auto-enables the servers in `ensure_installed` using the configs
      -- registered above via vim.lsp.config.
      -- stylua is a formatter (used via conform.nvim), not a language server. nvim-lspconfig now
      -- ships an lsp/stylua.lua (cmd = {'stylua','--lsp'}) and mason-lspconfig auto-enables every
      -- installed Mason package that maps to a server — so it tries to start our formatter binary as
      -- an LSP, which fails ("--lsp" unsupported, exit code 2). Exclude it from automatic_enable.
      require('mason-lspconfig').setup {
        automatic_enable = {
          -- marksman auto-attaches to markdown (our ~/textfiles/*.txt help/notes files
          -- are set to filetype=markdown), which sets tagfunc=vim.lsp.tagfunc and hijacks
          -- :tj/:tag — exact tag jumps become fuzzy workspace/symbol queries. We navigate
          -- via the ~/textfiles/tags file (and use Telescope for gd), so exclude it.
          -- jsonls is unused here; excluded as cleanup.
          exclude = { 'stylua', 'marksman', 'jsonls' },
        },
      }
    end,
  },
}
