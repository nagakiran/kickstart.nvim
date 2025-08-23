return {
  {
    'yetone/avante.nvim',
    event = 'VeryLazy',
    lazy = false,
    version = false, -- set this if you want to always pull the latest change
    -- Being overriden with config = function()
    -- opts = {
    --   -- file_selector = 'fzf',
    --   file_selector = {
    --     provider = 'telescope1',
    --     provider_opts = {
    --       find_command = function()
    --         local root = vim.fn.getcwd()
    --         -- Add debug print to verify this function is being called
    --         vim.notify('Avante file selector called from: ' .. root, vim.log.levels.INFO)
    --         return {
    --           'rg',
    --           '--files',
    --           '--hidden',
    --           '--glob',
    --           '!.git',
    --           root,
    --         }
    --       end,
    --     },
    --   },
    --   -- add any opts here
    --   mappings = {
    --     --- @class AvanteConflictMappings
    --     diff = {
    --       ours = 'co',
    --       theirs = 'ct',
    --       all_theirs = 'ca',
    --       both = 'cb',
    --       cursor = 'cc',
    --       next = ']x',
    --       prev = '[x',
    --     },
    --     suggestion = {
    --       accept = '<M-l>',
    --       next = '<M-]>',
    --       prev = '<M-[>',
    --       dismiss = '<C-]>',
    --     },
    --     jump = {
    --       next = ']]',
    --       prev = '[[',
    --     },
    --     submit = {
    --       normal = '<CR>',
    --       insert = '<C-s>',
    --     },
    --     sidebar = {
    --       apply_all = 'A',
    --       apply_cursor = 'a',
    --       switch_windows = '<Tab>',
    --       reverse_switch_windows = '<S-Tab>',
    --       remove_file = 'd',
    --       add_file = '@',
    --     },
    --   },
    -- },
    -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
    build = 'make',
    -- build = "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false" -- for windows
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'stevearc/dressing.nvim',
      'nvim-lua/plenary.nvim',
      'MunifTanjim/nui.nvim',
      --- The below dependencies are optional,
      'nvim-tree/nvim-web-devicons', -- or echasnovski/mini.icons
      'zbirenbaum/copilot.lua', -- for providers='copilot'
      {
        -- support for image pasting
        'HakonHarnes/img-clip.nvim',
        event = 'VeryLazy',
        opts = {
          -- recommended settings
          default = {
            embed_image_as_base64 = false,
            prompt_for_file_name = false,
            drag_and_drop = {
              insert_mode = true,
            },
            -- required for Windows users
            use_absolute_path = true,
          },
        },
      },
      {
        -- Make sure to set this up properly if you have lazy=true
        'MeanderingProgrammer/render-markdown.nvim',
        opts = {
          file_types = { 'markdown', 'Avante', 'codecompanion', 'typescriptreact' },
          -- Out of the box language injections for known filetypes that allow markdown to be
          -- interpreted in specified locations, see :h treesitter-language-injections
          -- Set enabled to false in order to disable
          injections = {
            typescriptreact = {
              enabled = true,
              query = [[
                ((message) @injection.content
                    (#set! injection.combined)
                    (#set! injection.include-children)
                    (#set! injection.language "markdown"))
            ]],
            },
          },
          regions = {
            typescriptreact = {
              -- Render markdown inside /* md ... */ comments
              { start = '/%*%s*md', finish = '%*/' },
              -- Optionally, render inside JSX <Markdown>...</Markdown> blocks
              { start = '<Markdown>', finish = '</Markdown>' },
            },
          },
        },
        ft = { 'markdown', 'Avante', 'codecompanion', 'typescriptreact' },
      },
    },
    -- other config options
    config = function()
      local opts = {
        provider = 'copilot',
        auto_suggestions_provider = 'copilot',
        cursor_applying_provider = nil,
        providers = {
          copilot = {
            model = 'claude-3.5-sonnet',
            -- disable_tools = true,
          },
        },
        file_selector = {
          provider = 'telescope',
          provider_opts = {
            find_command = function()
              local root = vim.fn.getcwd()
              vim.notify('Avante file selector called from: ' .. root, vim.log.levels.ERROR)
              return {
                'rg',
                '--files',
                '--hidden',
                '--glob',
                '!.git',
                root,
              }
            end,
          },
        },
      }

      -- local openai_api_url = os.getenv 'OPENAI_API_CHAT_COMPLETIONS'
      -- if openai_api_url then
      --   opts.provider = 'openai'
      --   opts.openai = {
      --     endpoint = openai_api_url,
      --     model = 'anthropic:claude-3-5-sonnet',
      --     timeout = 30000,
      --     temperature = 0,
      --     max_tokens = 4096,
      --     ['local'] = false,
      --   }
      -- end

      -- require('avante').setup(opts)
      -- Debugging: Print the opts table
      -- print(vim.inspect(opts))

      local avante = require 'avante'
      if type(avante) ~= 'table' then
        error 'Failed to load avante module'
      end

      avante.setup(opts)
    end,
    --[=====[ 
    opts = {
      -- Your config here!
      ---@alias Provider "claude" | "openai" | "azure" | "gemini" | "cohere" | "copilot" | string
      -- provider = "openai", -- Recommend using Claude
      provider = "copilot", -- Recommend using Claude
      auto_suggestions_provider = "copilot", -- Since auto-suggestions are a high-frequency operation and therefore expensive, it is recommended to specify an inexpensive provider or even a free provider: copilot
      claude = {
        endpoint = "https://api.anthropic.com",
        model = "claude-3-5-sonnet-20241022",
        temperature = 0,
        max_tokens = 4096,
      },
      behaviour = {
        auto_suggestions = false, -- Experimental stage
        auto_set_highlight_group = true,
        auto_set_keymaps = true,
        auto_apply_diff_after_generation = false,
        support_paste_from_clipboard = false,
      },
      mappings = {
        --- @class AvanteConflictMappings
        diff = {
          ours = "co",
          theirs = "ct",
          all_theirs = "ca",
          both = "cb",
          cursor = "cc",
          next = "]x",
          prev = "[x",
        },
        suggestion = {
          accept = "<M-l>",
          next = "<M-]>",
          prev = "<M-[>",
          dismiss = "<C-]>",
        },
        jump = {
          next = "]]",
          prev = "[[",
        },
        submit = {
          normal = "<CR>",
          insert = "<C-s>",
        },
        sidebar = {
          apply_all = "A",
          apply_cursor = "a",
          switch_windows = "<Tab>",
          reverse_switch_windows = "<S-Tab>",
        },
      },
      hints = { enabled = true },
      windows = {
        ---@type "right" | "left" | "top" | "bottom"
        position = "right", -- the position of the sidebar
        wrap = true, -- similar to vim.o.wrap
        width = 30, -- default % based on available width
        sidebar_header = {
          enabled = true, -- true, false to enable/disable the header
          align = "center", -- left, center, right for title
          rounded = true,
        },
        input = {
          prefix = "> ",
        },
        edit = {
          border = "rounded",
          start_insert = true, -- Start insert mode when opening the edit window
        },
        ask = {
          floating = false, -- Open the 'AvanteAsk' prompt in a floating window
          start_insert = true, -- Start insert mode when opening the ask window, only effective if floating = true.
          border = "rounded",
        },
      },
      highlights = {
        ---@type AvanteConflictHighlights
        diff = {
          current = "DiffText",
          incoming = "DiffAdd",
        },
      },
      --- @class AvanteConflictUserConfig
      diff = {
        autojump = true,
        ---@type string | fun(): any
        list_opener = "copen",
      },
    },
--]=====]
  },
}
