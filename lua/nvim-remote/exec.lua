local sync = require("nvim-remote.sync")

local M = {}

local function strip(line)
  line = line:gsub("\r$", ""):gsub("\r", "")
  -- ANSI CSI / OSC escape sequences (colored compiler output under a tty).
  line = line:gsub("\27%[[%d;?]*[%a@]", ""):gsub("\27%].-\7", "")
  return line
end

--- Translate remote absolute paths in a line to local ones.
function M.translate(proj, line)
  local repl = proj.local_root:gsub("%%", "%%%%")
  return (line:gsub(vim.pesc(proj.remote_root), repl))
end

function M.remote_command(proj, cmd, opts)
  opts = opts or {}
  local remote = "cd " .. sync.remote_quote(proj.remote_root) .. " && " .. cmd
  if opts.env ~= false then
    remote = "export PAGER=cat GIT_PAGER=cat; " .. remote
  end
  local full = sync.ssh_base(proj)
  if opts.tty then
    table.insert(full, "-tt")
  end
  vim.list_extend(full, { proj.host, remote })
  return full
end

local function line_splitter(on_line)
  local buf = ""
  return function(data, final)
    if data then
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        on_line(buf:sub(1, nl - 1))
        buf = buf:sub(nl + 1)
      end
    end
    if final and buf ~= "" then
      on_line(buf)
      buf = ""
    end
  end
end

--- Run `cmd` inside remote_root on the remote host and stream its output into the quickfix list.
function M.run(proj, cmd, opts)
  opts = opts or {}
  local st = sync.state(proj)
  if st.exec then
    sync.notify(proj, "a remote command is already running (:RemoteStop to cancel)", vim.log.levels.WARN)
    return
  end

  local function start()
    local title = "[" .. proj.host .. "] " .. cmd
    vim.fn.setqflist({}, " ", { title = title, lines = {} })
    local qf_id = vim.fn.getqflist({ id = 0 }).id
    local efm = proj.errorformat or vim.o.errorformat
    if proj.open_quickfix == "always" then
      vim.cmd("botright copen")
      vim.cmd("wincmd p")
    end

    local batch = {}
    local scheduled = false
    local function flush_lines()
      scheduled = false
      if #batch == 0 then
        return
      end
      local lines = batch
      batch = {}
      vim.fn.setqflist({}, "a", { id = qf_id, lines = lines, efm = efm })
      -- Keep an open quickfix window scrolled to the newest output.
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].buftype == "quickfix" and vim.fn.getwininfo(win)[1].loclist == 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
        end
      end
    end
    local function on_line(line)
      table.insert(batch, M.translate(proj, strip(line)))
      if not scheduled then
        scheduled = true
        vim.schedule(flush_lines)
      end
    end
    local out = line_splitter(on_line)
    local err = line_splitter(on_line)

    local full = M.remote_command(proj, cmd, { tty = proj.exec_tty })
    local started = vim.uv.hrtime()
    sync.notify(proj, "running: " .. cmd)
    local ok, job = pcall(vim.system, full, {
      text = true,
      stdout = function(_, data)
        out(data, data == nil)
      end,
      stderr = function(_, data)
        err(data, data == nil)
      end,
    }, function(res)
      vim.schedule(function()
        st.exec = nil
        out(nil, true)
        err(nil, true)
        flush_lines()
        local secs = (vim.uv.hrtime() - started) / 1e9
        local valid = 0
        for _, item in ipairs(vim.fn.getqflist({ id = qf_id, items = 0 }).items) do
          if item.valid == 1 then
            valid = valid + 1
          end
        end
        local failed = res.code ~= 0 or res.signal ~= 0
        local msg = string.format("'%s' %s (exit %d, %.1fs)", cmd, failed and "FAILED" or "finished", res.code, secs)
        if valid > 0 then
          msg = msg .. string.format(", %d quickfix entr%s", valid, valid == 1 and "y" or "ies")
        end
        sync.notify(proj, msg, failed and vim.log.levels.ERROR or vim.log.levels.INFO)
        if proj.open_quickfix == "on_error" and (failed or valid > 0) then
          vim.cmd("botright copen")
        end
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NvimRemoteExecDone",
          modeline = false,
          data = { cmd = cmd, code = res.code, project = proj.name },
        })
        if opts.on_exit then
          opts.on_exit(res.code)
        end
      end)
    end)
    if not ok then
      sync.notify(proj, "failed to start ssh: " .. tostring(job), vim.log.levels.ERROR)
      return
    end
    st.exec = job
  end

  if proj.sync_before_exec then
    sync.when_idle(proj, function(push_ok)
      if not push_ok then
        sync.notify(proj, "pending push failed; running command anyway", vim.log.levels.WARN)
      end
      start()
    end)
  else
    start()
  end
end

function M.stop(proj)
  local st = sync.state(proj)
  if st.exec then
    st.exec:kill(15)
    sync.notify(proj, "remote command stopped")
  else
    sync.notify(proj, "no remote command running")
  end
end

--- Open an interactive ssh shell (in remote_root) in a terminal split.
function M.shell(proj, cmd)
  local remote = cmd and cmd ~= "" and cmd or 'exec "$SHELL" -l'
  local full = M.remote_command(proj, remote, { tty = true, env = false })
  vim.cmd("botright split")
  vim.cmd("enew")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart(full, { term = true })
  else
    vim.fn.termopen(full)
  end
  vim.cmd("startinsert")
end

return M
