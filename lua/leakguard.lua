-- Mitigations for leaks that live in plugin code, plus GC pacing.
--
-- Everything here patches behaviour this config does not own, so each piece is written to fail
-- soft: if a plugin's internals have moved, the wrapper declines rather than half-applying.
local M = {}

local uv = vim.uv

--------------------------------------------------------------------------------------------------
-- LuaJIT GC pacing
--------------------------------------------------------------------------------------------------
--
-- A 12-day session measured a 1.1GB Lua heap holding a 168MB live set -- 85% floating garbage. That
-- matters beyond the heap itself: LuaJIT's allocator mmaps arenas to cover the *peak*, and neither
-- it nor macOS malloc ever hands those back, so the high-water mark becomes permanently mapped
-- (17,330 VM_ALLOCATE regions against ~186 in a fresh nvim). Collecting sooner keeps the peak, and
-- therefore the retained arenas, smaller.
--
-- Measured on a synthetic churn workload (6 rounds parsing a 1.37MB ledger + heavy table alloc):
--        peak heap 54.3MB -> 31.0MB (-43%), VM regions 588 -> 343 (-42%), final RSS -24%.
--
-- The trade is CPU: a lower pause means more GC cycles. If typing on a large buffer regresses,
-- raise `M.gc_pause` toward the LuaJIT default of 200 rather than removing this.
M.gc_pause = 120 -- start a cycle at 120% of the post-collection estimate (default 200)
M.gc_stepmul = 400 -- do more work per step so cycles actually finish (default 200)

function M.tune_gc()
  collectgarbage('setpause', M.gc_pause)
  collectgarbage('setstepmul', M.gc_stepmul)
end

M.tune_gc()

local group = vim.api.nvim_create_augroup('LeakGuard', { clear = true })

-- A full collect measured 235ms on the big session -- unacceptable on CursorHold, but free when
-- you have already switched away from the terminal.
vim.api.nvim_create_autocmd('FocusLost', {
  group = group,
  desc = 'Full Lua GC when stepping away from the editor',
  callback = function()
    vim.schedule(function()
      collectgarbage 'collect'
    end)
  end,
})

--------------------------------------------------------------------------------------------------
-- telescope.nvim: one leaked uv timer per picker
--------------------------------------------------------------------------------------------------
--
-- `telescope/debounce.lua` returns `wrapped_fn, timer` and documents the contract in its own
-- doc comment: "Remember to call `timer.close()` at the end or you will leak memory!". Its caller
-- `pickers.lua:580` (`debounce.throttle_leading(status_updater, 50)`) keeps only the function, so
-- every `Picker:find()` strands a timer. Measured: handle count held flat at 16 across buffer and
-- completion workloads and rose only with pickers (17 -> 22 -> 23 over three); one live session had
-- 3249.
--
-- The timers only flip a `running` flag on a 50ms fuse, so once no picker is on screen they are
-- inert and safe to close. `bufreap.sweep()` calls `drain_telescope_timers` on its 60s tick, at
-- which point it has already established that no telescope picker is open.
local tracked = {}

--- Close every throttle timer telescope dropped. Called by `bufreap.sweep()` when no picker is up.
---@return integer closed
function M.drain_telescope_timers()
  local closed = 0
  for _, t in ipairs(tracked) do
    -- Guarded: a caller that *does* honour the contract will have closed it already.
    local ok = pcall(function()
      if not t:is_closing() then
        t:stop()
        t:close()
        closed = closed + 1
      end
    end)
    local _ = ok
  end
  tracked = {}
  return closed
end

--- Wrap telescope's debounce factories so their timers are recoverable.
---
--- Telescope is lazy-loaded, so this is retried from the sweep tick until the module shows up
--- rather than forcing it to load at startup.
---@return boolean patched
function M.patch_telescope()
  local d = package.loaded['telescope.debounce']
  if not d or d.__leakguard then
    return d ~= nil and d.__leakguard == true
  end
  for _, name in ipairs { 'throttle_leading', 'throttle_trailing' } do
    local orig = d[name]
    if type(orig) == 'function' then
      d[name] = function(...)
        -- Telescope pickers are modal and strictly sequential, so any timer tracked from an
        -- earlier `find()` is already dead by the time a new one asks for a throttle. Draining
        -- here bounds the registry at one picker's worth no matter what the sweep's picker
        -- detection decides, which is what actually keeps the count flat.
        M.drain_telescope_timers()
        local fn, timer = orig(...)
        if timer then
          tracked[#tracked + 1] = timer
        end
        return fn, timer
      end
    end
  end
  d.__leakguard = true
  return true
end

--------------------------------------------------------------------------------------------------
-- plenary.nvim: a leaked uv check handle per job
--------------------------------------------------------------------------------------------------
--
-- `plenary/job.lua` `Job:_reset()` assigns a fresh `uv.new_check()` over whatever was there, and
-- carries the comment "We may be memory leaking here. Please report to TJ." `_reset` runs from both
-- `Job:new` and `Job:start`, so a job allocates two and strands the first.
--
-- PARTIAL FIX, deliberately. This recovers the allocation-time handle. The other path -- the local
-- `start_shutdown_check` doing `uv.check_stop(...)` then `child._shutdown_check = nil` when a job
-- exits normally -- drops the handle from a local closure that config code cannot reach. Closing
-- those would mean sweeping unowned `check` handles out of `uv.walk`, which could close one another
-- plugin still holds, so it is not done here. Expect roughly half the leak to remain (one session
-- had 538); the rest belongs upstream.
---@return boolean patched
function M.patch_plenary()
  local job = package.loaded['plenary.job']
  if not job or job.__leakguard then
    return job ~= nil and job.__leakguard == true
  end
  local orig = rawget(job, '_reset')
  if type(orig) ~= 'function' then
    return false
  end
  job._reset = function(self, ...)
    local h = rawget(self, '_shutdown_check')
    if h then
      pcall(function()
        if not uv.is_closing(h) then
          if uv.is_active(h) then
            uv.check_stop(h)
          end
          h:close()
        end
      end)
      self._shutdown_check = nil
    end
    return orig(self, ...)
  end
  job.__leakguard = true
  return true
end

-- Both targets are lazy-loaded, so keep trying cheaply until they appear. `package.loaded` lookups
-- are all this costs once patched.
vim.api.nvim_create_autocmd({ 'BufEnter', 'CmdlineEnter' }, {
  group = group,
  desc = 'Apply leak mitigations once the target plugins have loaded',
  callback = function()
    M.patch_telescope()
    M.patch_plenary()
  end,
})

M.patch_telescope()
M.patch_plenary()

return M
