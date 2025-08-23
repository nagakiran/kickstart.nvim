vim.cmd [[cab cc CodeCompanion]]
require('which-key').add {
  mode = { 'n', 'v' },
  -- { '<C-a>', '<cmd>CodeCompanionActions<cr>', desc = 'CodeCompanion Actions' },
  { '<LocalLeader>ct', '<cmd>CodeCompanionChat Toggle<cr>', desc = 'Toggle CodeCompanion Chat' },
  { '<LocalLeader>ce', '<cmd>CodeCompanionChat /explain<cr>', desc = 'CodeCompanion explain' },
  { '<LocalLeader>cc', '<cmd>CodeCompanionChat<cr>', desc = 'CodeCompanion chat' },
  { '<LocalLeader>cg', '<cmd>CodeCompanionChat /commit<cr>', desc = 'Generate Git Commit Message' },
}
require('which-key').add {
  mode = { 'v' },
  { 'ga', '<cmd>CodeCompanionChat Add<cr>', desc = 'Add to CodeCompanion Chat' },
  { '<LocalLeader>cp', '<cmd>CodeCompanion<cr>', desc = 'CodeCompanion Prompt' },
}
