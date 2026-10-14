local config = require("nvim-remote.config")

local M = {}

local function notify(proj, msg, level)
  if proj.notify or (level and level >= vim.log.levels.WARN) then
    vim.notify("[nvim-remote:" .. proj.name .. "] " .. msg, level or vim.log.levels.INFO)
  end
end
M.notify = notify

local function state(proj)
  proj.state = proj.state
    or { pending = {}, failed = {}, running = false, timer = nil, status = "idle", waiters = {}, last_error = nil }
  return proj.state
end
M.state = state

--- Single-quote a string for a POSIX remote shell, keeping a leading "~/" expandable.
function M.remote_quote(s)
  local prefix = ""
  if s == "~" then
    return "~"
  end
  if s:sub(1, 2) == "~/" then
    prefix, s = "~/", s:sub(3)
  end
  return prefix .. "'" .. s:gsub("'", [['\'']]) .. "'"
end

function M.ssh_base(proj)
  local cmd = vim.list_extend(vim.deepcopy(proj.ssh_cmd), proj.ssh_args or {})
  return cmd
end

local function rsync_base(proj)
  local cmd = { proj.rsync_cmd }
  vim.list_extend(cmd, proj.rsync_args or {})
  vim.list_extend(cmd, { "-e", table.concat(M.ssh_base(proj), " ") })
  return cmd
end

local function remote_spec(proj, rel)
  return proj.host .. ":" .. proj.remote_root .. "/" .. (rel or "")
end

local function run(cmd, opts, on_done)
  local ok, err = pcall(vim.system, cmd, { cwd = opts.cwd, text = true, stdin = opts.stdin }, function(res)
    vim.schedule(function()
      on_done(res)
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_done({ code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
end

local function set_status(proj, status, err)
  local st = state(proj)
  st.status = status
  st.last_error = err
  vim.api.nvim_exec_autocmds("User", { pattern = "NvimRemoteStatus", modeline = false })
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function finish_waiters(proj)
  local st = state(proj)
  if st.running or next(st.pending) or st.timer then
    return
  end
  local waiters = st.waiters
  st.waiters = {}
  for _, cb in ipairs(waiters) do
    cb(st.status ~= "error")
  end
end

local flush

flush = function(proj)
  local st = state(proj)
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
  if st.running then
    return
  end
  local files = {}
  for rel in pairs(st.pending) do
    if exists(proj.local_root .. "/" .. rel) then
      table.insert(files, rel)
    end
  end
  st.pending = {}
  if #files == 0 then
    finish_waiters(proj)
    return
  end
  table.sort(files)
  st.running = true
  set_status(proj, "syncing")
  local cmd = rsync_base(proj)
  vim.list_extend(cmd, { "-R", "--" })
  vim.list_extend(cmd, files)
  table.insert(cmd, remote_spec(proj))
  run(cmd, { cwd = proj.local_root }, function(res)
    st.running = false
    if res.code == 0 then
      set_status(proj, "idle")
      if proj.notify_on_save then
        notify(proj, "pushed " .. table.concat(files, ", "))
      end
    else
      -- Remember failed files so the next push retries them.
      for _, f in ipairs(files) do
        st.failed[f] = true
      end
      set_status(proj, "error", vim.trim(res.stderr or ""))
      notify(proj, "push failed (" .. res.code .. "): " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
    end
    if next(st.pending) then
      flush(proj)
    else
      finish_waiters(proj)
    end
  end)
end

--- Queue project-relative files for a (debounced) push.
function M.queue(proj, rels, immediate)
  local st = state(proj)
  for rel in pairs(st.failed) do
    st.pending[rel] = true
  end
  st.failed = {}
  for _, rel in ipairs(rels) do
    st.pending[rel] = true
  end
  if immediate or (proj.debounce_ms or 0) <= 0 then
    return flush(proj)
  end
  if st.timer then
    st.timer:stop()
  else
    st.timer = vim.uv.new_timer()
  end
  st.timer:start(proj.debounce_ms, 0, function()
    vim.schedule(function()
      flush(proj)
    end)
  end)
end

--- Call cb(ok) once all queued pushes are done (flushes the queue right away).
function M.when_idle(proj, cb)
  local st = state(proj)
  table.insert(st.waiters, cb)
  if st.timer or next(st.pending) then
    flush(proj)
  else
    finish_waiters(proj)
  end
end

local function git_list(proj)
  local root = proj.local_root
  local function git(args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local ok, res = pcall(function()
      return vim.system(cmd, { text = true }):wait()
    end)
    if not ok or res.code ~= 0 then
      return nil
    end
    return vim.split(res.stdout, "\0", { trimempty = true })
  end
  local inside = git({ "rev-parse", "--show-toplevel" })
  if not inside then
    return nil
  end
  local cached = git({ "ls-files", "-z", "--cached", "--recurse-submodules" })
  local others = git({ "ls-files", "-z", "--others", "--exclude-standard" })
  local deleted = git({ "ls-files", "-z", "--deleted" }) or {}
  if not cached or not others then
    return nil
  end
  local skip = {}
  for _, d in ipairs(deleted) do
    skip[d] = true
  end
  local seen, files = {}, {}
  for _, list in ipairs({ cached, others }) do
    for _, f in ipairs(list) do
      if not seen[f] and not skip[f] and not config.is_excluded(proj, f) then
        seen[f] = true
        local stat = vim.uv.fs_lstat(root .. "/" .. f)
        if stat and stat.type ~= "directory" then
          table.insert(files, f)
        end
      end
    end
  end
  return files
end

local function to_rsync_exclude(pat)
  local inner = pat:gsub("/+$", "")
  if inner:find("/", 1, true) and inner:sub(1, 1) ~= "/" then
    return "/" .. pat
  end
  return pat
end

--- Push the whole project. With git, only tracked + untracked-not-ignored files are sent
--- and nothing is deleted on the remote. Without git, `delete` mirrors with --delete.
function M.push_all(proj, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  local st = state(proj)
  local files = proj.use_git and git_list(proj) or nil
  local cmd = rsync_base(proj)
  local tmp
  local desc
  if files then
    tmp = vim.fn.tempname()
    local fd = assert(io.open(tmp, "w"))
    fd:write(table.concat(files, "\n"), "\n")
    fd:close()
    vim.list_extend(cmd, { "--files-from=" .. tmp, "./", remote_spec(proj) })
    desc = #files .. " files (git)"
  else
    for _, pat in ipairs(proj.exclude or {}) do
      table.insert(cmd, "--exclude=" .. to_rsync_exclude(pat))
    end
    if opts.delete then
      table.insert(cmd, "--delete")
    end
    vim.list_extend(cmd, { "./", remote_spec(proj) })
    desc = "directory" .. (opts.delete and " (mirror, --delete)" or "")
  end
  if opts.dry_run then
    table.insert(cmd, 2, "--dry-run")
    table.insert(cmd, 2, "-v")
  end
  st.running = true
  set_status(proj, "syncing")
  notify(proj, (opts.dry_run and "dry-run " or "") .. "pushing " .. desc .. " -> " .. remote_spec(proj))
  local started = vim.uv.hrtime()
  run(cmd, { cwd = proj.local_root }, function(res)
    st.running = false
    if tmp then
      os.remove(tmp)
    end
    if res.code == 0 then
      set_status(proj, "idle")
      if not opts.dry_run then
        st.failed = {}
      end
      local secs = (vim.uv.hrtime() - started) / 1e9
      notify(proj, string.format("push complete (%.1fs)", secs))
      if opts.dry_run then
        vim.notify(res.stdout ~= "" and res.stdout or "(no output)", vim.log.levels.INFO)
      end
    else
      set_status(proj, "error", vim.trim(res.stderr or ""))
      notify(proj, "push failed (" .. res.code .. "): " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
    end
    if next(st.pending) then
      flush(proj)
    else
      finish_waiters(proj)
    end
    cb(res.code == 0)
  end)
end

local function rewrite_file(proj, path)
  local fd = io.open(path, "r")
  if not fd then
    return
  end
  local content = fd:read("*a")
  fd:close()
  local new, n = content:gsub(vim.pesc(proj.remote_root), (proj.local_root:gsub("%%", "%%%%")))
  if n > 0 then
    fd = assert(io.open(path, "w"))
    fd:write(new)
    fd:close()
  end
end

local function walk_rewrite(proj, path)
  local names = {}
  for _, n in ipairs(proj.rewrite_on_pull or {}) do
    names[n] = true
  end
  if next(names) == nil then
    return
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return
  end
  if stat.type == "file" then
    if names[vim.fs.basename(path)] then
      rewrite_file(proj, path)
    end
    return
  end
  for name, type in vim.fs.dir(path, { depth = math.huge }) do
    if type == "file" and names[vim.fs.basename(name)] then
      rewrite_file(proj, path .. "/" .. name)
    end
  end
end

--- Pull project-relative paths (files or directories) from the remote.
function M.pull(proj, rels, cb)
  cb = cb or function() end
  local remaining = #rels
  local all_ok = true
  if remaining == 0 then
    return cb(true)
  end
  for _, rel in ipairs(rels) do
    rel = rel:gsub("^%./", ""):gsub("/+$", "")
    local dest_parent = vim.fs.dirname(proj.local_root .. "/" .. rel)
    vim.fn.mkdir(dest_parent, "p")
    local cmd = rsync_base(proj)
    vim.list_extend(cmd, { remote_spec(proj, rel), dest_parent .. "/" })
    run(cmd, { cwd = proj.local_root }, function(res)
      if res.code == 0 then
        walk_rewrite(proj, proj.local_root .. "/" .. rel)
        notify(proj, "pulled " .. rel)
        vim.cmd("silent! checktime")
      else
        all_ok = false
        notify(proj, "pull of " .. rel .. " failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
      end
      remaining = remaining - 1
      if remaining == 0 then
        cb(all_ok)
      end
    end)
  end
end

return M
