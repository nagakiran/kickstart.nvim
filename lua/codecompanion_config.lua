vim.cmd [[cab cc CodeCompanion]]
require('which-key').add {
  mode = { 'n', 'v' },
  { '<C-a>', '<cmd>CodeCompanionActions<cr>', desc = 'CodeCompanion Actions' },
  { '<LocalLeader>ct', '<cmd>CodeCompanionChat Toggle<cr>', desc = 'Toggle CodeCompanion Chat' },
}
require('which-key').add {
  mode = { 'v' },
  { 'ga', '<cmd>CodeCompanionChat Add<cr>', desc = 'Add to CodeCompanion Chat' },
}
