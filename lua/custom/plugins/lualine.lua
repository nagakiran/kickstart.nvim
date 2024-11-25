return {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    -- As noticing flicking status line goes off and rerenders on opening tab
    cond = true,
    config = function()
        -- local config = {
        --     sections = {
        --     lualine_b = { 'filename', 'diff', 'diagnostics'},
        --     lualine_c = {function() return vim.fn.getcwd() end}
        -- }
        -- },
        local config = {
                    options = {
                        icons_enabled = true,
                        theme = 'auto',
                        component_separators = { left = '', right = ''},
                        section_separators = { left = '', right = ''},
                        disabled_filetypes = {
                            statusline = {},
                            winbar = {},
                        },
                        ignore_focus = {},
                        always_divide_middle = true,
                        globalstatus = true,
                        refresh = {
                            statusline = 100,
                            tabline = 100,
                            winbar = 100,
                        }
                    },
                    sections = {
                        -- tabline = {
                        --     lualine_a = {},
                        --     lualine_b = {'branch'},
                        --     lualine_c = {'filename'},
                        --     lualine_x = {},
                        --     lualine_y = {},
                        --     lualine_z = {}
                        -- },
                        lualine_a = {'mode',
                            -- {
                            --     'tabs',
                            --     mode = 2,
                            --     path = 0
                            -- }
                    },
                        lualine_b = {
                            'branch',
                            'diff',
                            'diagnostics'
                        },
                        lualine_c = {{
                            'filename',
                            path = 1
                    }},
                        lualine_x = {
                            {
                                function() 
                                    return vim.fn.getcwd() 
                                end
                            },'encoding', 'fileformat', 'filetype'},
                        lualine_y = {'progress'},
                        lualine_z = {'location'}
                    },
                    inactive_sections = {
                        lualine_a = {},
                        lualine_b = {},
                        lualine_c = {'filename'},
                        lualine_x = {'location'},
                        lualine_y = {},
                        lualine_z = {}
                    },
                    -- tabline = {},
                    winbar = {},
                    inactive_winbar = {},
                    extensions = {}
                }
        require("lualine").setup(config)
    end,
}
