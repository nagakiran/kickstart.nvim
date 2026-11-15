-- Kubernetes browser (pods/deployments/logs/describe/port-forward) over $KUBECONFIG.
-- <C-x> switches context (colima / onprem), g? lists keys. <leader>K opens k9s for log tailing.
return {
  'ramilito/kubectl.nvim',
  version = '2.*',
  dependencies = 'saghen/blink.download', -- fetches the prebuilt Rust core
  cmd = 'Kubectl',
  keys = {
    {
      '<leader>k',
      function()
        require('kubectl').toggle { tab = true }
      end,
      desc = 'Kubectl',
    },
    {
      '<leader>K',
      function()
        vim.cmd 'tabnew | terminal k9s --context onprem'
        vim.cmd 'startinsert'
      end,
      desc = 'k9s (onprem)',
    },
  },
  opts = { logs = { since = '24h' } }, -- default 5m shows nothing for quiet pods; gh changes it per view
}
