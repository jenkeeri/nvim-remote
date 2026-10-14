local config = require("nvim-remote.config")
local sync = require("nvim-remote.sync")
local exec = require("nvim-remote.exec")

local M = {}

local augroup
local enabled = true

local function project_or_warn(path)
  local proj, err = config.resolve(path)
  if not proj then
    vim.notify("[nvim-remote] " .. (err or "no project"), vim.log.levels.WARN)
  end
  return proj
end

local function buf_path(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end
  return name
end

--- Called on BufWritePost.
function M.on_write(buf)
  if not enabled or vim.bo[buf].buftype ~= "" then
    return
  end
  local path = buf_path(buf)
  if not path then
    return
  end
  local proj = config.resolve(path)
  if not proj or not proj.sync_on_save then
    return
  end
  local rel = config.relpath(proj, path)
  if not rel or config.is_excluded(proj, rel) then
    return
  end
  sync.queue(proj, { rel })
end

function M.push_file(path)
  path = path or buf_path(0)
  if not path then
    return vim.notify("[nvim-remote] current buffer is not a file", vim.log.levels.WARN)
  end
  local proj = project_or_warn(path)
  if not proj then
    return
  end
  local rel = config.relpath(proj, path)
  if not rel then
    return vim.notify("[nvim-remote] file is outside " .. proj.local_root, vim.log.levels.WARN)
  end
  sync.queue(proj, { rel }, true)
  sync.when_idle(proj, function(ok)
    if ok then
      sync.notify(proj, "pushed " .. rel)
    end
  end)
end

function M.push(opts)
  local proj = project_or_warn()
  if not proj then
    return
  end
  opts = opts or {}
  if opts.delete then
    local choice = vim.fn.confirm(
      "Mirror " .. proj.local_root .. " to " .. proj.host .. ":" .. proj.remote_root
        .. "?\nRemote files missing locally (e.g. build dirs not excluded) will be DELETED"
        .. (proj.use_git and " (ignored when the project is a git repo)" or ""),
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return
    end
  end
  sync.push_all(proj, opts)
end

function M.pull(paths)
  local proj = project_or_warn()
  if not proj then
    return
  end
  if #paths == 0 then
    local p = buf_path(0)
    local rel = p and config.relpath(proj, p)
    if not rel then
      return vim.notify("[nvim-remote] usage: :RemotePull {path} ...", vim.log.levels.WARN)
    end
    paths = { rel }
  end
  local rels = {}
  for _, p in ipairs(paths) do
    -- Accept both project-relative and local absolute paths.
    local abs = vim.fn.fnamemodify(vim.fn.expand(p), ":p")
    local rel = p:sub(1, 1) == "/" and config.relpath(proj, abs) or p
    if not rel or ("/" .. rel .. "/"):find("/%.%./") then
      vim.notify("[nvim-remote] invalid path: " .. p, vim.log.levels.WARN)
    else
      table.insert(rels, rel)
    end
  end
  sync.pull(proj, rels)
end

function M.exec(cmd)
  local proj = project_or_warn()
  if not proj then
    return
  end
  if not cmd or cmd == "" then
    return vim.notify("[nvim-remote] usage: :RemoteExec {cmd}", vim.log.levels.WARN)
  end
  exec.run(proj, cmd)
end

function M.build(args)
  local proj = project_or_warn()
  if not proj then
    return
  end
  if not proj.build_cmd or proj.build_cmd == "" then
    return vim.notify("[nvim-remote] no build_cmd configured for " .. proj.name, vim.log.levels.WARN)
  end
  local cmd = proj.build_cmd
  if args and args ~= "" then
    cmd = cmd .. " " .. args
  end
  exec.run(proj, cmd)
end

function M.stop()
  local proj = project_or_warn()
  if proj then
    exec.stop(proj)
  end
end

function M.shell(cmd)
  local proj = project_or_warn()
  if proj then
    exec.shell(proj, cmd)
  end
end

function M.toggle()
  enabled = not enabled
  vim.notify("[nvim-remote] sync on save " .. (enabled and "enabled" or "disabled"))
end

function M.is_enabled()
  return enabled
end

function M.status()
  local proj, err = config.resolve()
  if not proj then
    return vim.notify("[nvim-remote] " .. err, vim.log.levels.INFO)
  end
  local st = sync.state(proj)
  local pending = vim.tbl_count(st.pending) + vim.tbl_count(st.failed)
  local lines = {
    "project:      " .. proj.name,
    "local root:   " .. proj.local_root,
    "remote:       " .. proj.host .. ":" .. proj.remote_root,
    "sync on save: " .. tostring(enabled and proj.sync_on_save),
    "status:       " .. st.status .. (pending > 0 and (" (" .. pending .. " pending)") or ""),
    "build cmd:    " .. tostring(proj.build_cmd),
  }
  if st.last_error then
    table.insert(lines, "last error:   " .. st.last_error)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Short string for statuslines, e.g. "⇅ myproj" / "⇅ myproj …" / "⇅ myproj !". Empty outside projects.
function M.statusline()
  local path = buf_path(0)
  if not path then
    return ""
  end
  local proj = config.resolve(path)
  if not proj then
    return ""
  end
  local st = sync.state(proj)
  local mark = ""
  if st.exec then
    mark = " ⚙"
  elseif st.status == "syncing" or next(st.pending) then
    mark = " …"
  elseif st.status == "error" then
    mark = " !"
  end
  if not enabled or not proj.sync_on_save then
    mark = mark .. " (off)"
  end
  return "⇅ " .. proj.name .. mark
end

local function complete_remote_paths(arglead)
  local proj = config.resolve()
  if not proj then
    return {}
  end
  local dir = arglead:match("^(.*/)") or ""
  local cmd = exec.remote_command(proj, "ls -1Ap " .. (dir ~= "" and sync.remote_quote(dir) or "") .. " 2>/dev/null")
  table.insert(cmd, #cmd - 1, "-o")
  table.insert(cmd, #cmd - 1, "ConnectTimeout=3")
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(4000)
  end)
  if not ok or res.code ~= 0 then
    return {}
  end
  local items = {}
  for _, name in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
    local full = dir .. name
    if vim.startswith(full, arglead) then
      table.insert(items, full)
    end
  end
  return items
end

local function create_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("RemotePush", function(o)
    M.push({ delete = o.bang })
  end, { bang = true, desc = "Push the whole project to the remote (! = mirror with --delete, non-git only)" })
  cmd("RemotePushDry", function()
    M.push({ dry_run = true })
  end, { desc = "Show what :RemotePush would transfer" })
  cmd("RemotePushFile", function(o)
    M.push_file(o.args ~= "" and vim.fn.fnamemodify(o.args, ":p") or nil)
  end, { nargs = "?", complete = "file", desc = "Push the current (or given) file now" })
  cmd("RemotePull", function(o)
    M.pull(o.fargs)
  end, { nargs = "*", complete = complete_remote_paths, desc = "Pull files/dirs from the remote" })
  cmd("RemoteExec", function(o)
    M.exec(o.args)
  end, { nargs = "+", complete = "shellcmd", desc = "Run a command in remote_root, output to quickfix" })
  cmd("RemoteBuild", function(o)
    M.build(o.args)
  end, { nargs = "*", desc = "Run build_cmd on the remote" })
  cmd("RemoteStop", M.stop, { desc = "Stop the running remote command" })
  cmd("RemoteShell", function(o)
    M.shell(o.args)
  end, { nargs = "*", desc = "Open an ssh terminal in remote_root" })
  cmd("RemoteSyncToggle", M.toggle, { desc = "Toggle push-on-save" })
  cmd("RemoteStatus", M.status, { desc = "Show remote sync status" })
end

function M.setup(opts)
  config.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("[nvim-remote] requires Neovim >= 0.10", vim.log.levels.ERROR)
    return
  end
  create_commands()
  augroup = vim.api.nvim_create_augroup("NvimRemote", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      M.on_write(ev.buf)
    end,
  })
end

return M
