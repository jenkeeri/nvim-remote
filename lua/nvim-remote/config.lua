local M = {}

M.defaults = {
  -- Push a file to the remote every time it is written.
  sync_on_save = true,
  -- Delay (ms) used to batch several quick writes into one rsync call.
  debounce_ms = 150,
  -- Glob patterns (relative to the project root) never pushed.
  -- A trailing "/" matches directories only; patterns without "/" match at any depth.
  exclude = { ".git/", ".nvim-remote.json", ".DS_Store", "*.swp", "*~" },
  -- Use `git ls-files` to decide what a full push sends (respects .gitignore).
  use_git = true,
  rsync_cmd = "rsync",
  rsync_args = { "-az" },
  -- ssh command used for rsync transport and remote commands.
  ssh_cmd = { "ssh" },
  -- Re-use one ssh connection for all transfers (much faster saves).
  ssh_args = {
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/nvim-remote-%C",
    "-o", "ControlPersist=10m",
    "-o", "BatchMode=yes",
  },
  -- Default command for :RemoteBuild (run inside remote_root).
  build_cmd = nil,
  -- Wait for pending pushes before :RemoteExec / :RemoteBuild.
  sync_before_exec = true,
  -- Allocate a remote tty for :RemoteExec so Ctrl-C/:RemoteStop also kills the remote process.
  exec_tty = true,
  -- "always" | "on_error" | "never"
  open_quickfix = "on_error",
  -- errorformat for :RemoteExec output (nil = use 'errorformat').
  errorformat = nil,
  -- Files whose content gets remote_root -> local_root rewritten on :RemotePull.
  rewrite_on_pull = { "compile_commands.json" },
  -- Show info notifications (errors are always shown).
  notify = true,
  -- Also notify after every successful on-save push (noisy).
  notify_on_save = false,
  -- Explicit project list: { { local_root = "~/src/foo", host = "devvm", remote_root = "/home/me/foo" } }
  projects = {},
}

M.options = vim.deepcopy(M.defaults)

M.PROJECT_FILE = ".nvim-remote.json"
local cache = {}

local function normalize(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
  if path ~= "/" then
    path = path:gsub("/+$", "")
  end
  return path
end
M.normalize = normalize

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  cache = {}
end

function M.clear_cache()
  cache = {}
end

local function finalize(proj)
  if type(proj.host) ~= "string" or proj.host == "" then
    return nil, "missing 'host'"
  end
  if type(proj.remote_root) ~= "string" or proj.remote_root == "" then
    return nil, "missing 'remote_root'"
  end
  proj.remote_root = proj.remote_root:gsub("/+$", "")
  proj.local_root = normalize(proj.local_root)
  proj.name = proj.name or vim.fs.basename(proj.local_root)
  local base = vim.deepcopy(M.options)
  base.projects = nil
  -- Lists from the project replace (not merge with) the global ones.
  for k, v in pairs(proj) do
    base[k] = v
  end
  return base
end

local function read_project_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "cannot read " .. path
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil, "invalid JSON in " .. path
  end
  data.local_root = vim.fs.dirname(path)
  return data
end

local function is_within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Find the project a path belongs to (setup() projects first, then .nvim-remote.json).
---@param path string|nil file or directory; defaults to the current buffer / cwd
---@return table|nil project, string|nil err
function M.resolve(path)
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
    if path == "" or path:match("^%a+://") then
      path = vim.fn.getcwd()
    end
  end
  path = normalize(path)

  local best
  for _, p in ipairs(M.options.projects or {}) do
    local root = normalize(p.local_root or "")
    if root ~= "" and is_within(path, root) and (not best or #root > #best.root) then
      best = { root = root, spec = p }
    end
  end
  if best then
    local key = "setup:" .. best.root
    if not cache[key] then
      local spec = vim.deepcopy(best.spec)
      spec.local_root = best.root
      local proj, err = finalize(spec)
      if not proj then
        return nil, "project " .. best.root .. ": " .. err
      end
      cache[key] = { proj = proj }
    end
    return cache[key].proj
  end

  local start = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local found = vim.fs.find(M.PROJECT_FILE, { upward = true, path = start, type = "file" })[1]
  if not found then
    return nil, "no remote project configured for " .. path
  end
  found = normalize(found)
  local stat = vim.uv.fs_stat(found)
  local mtime = stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or 0
  local c = cache[found]
  if c and c.mtime == mtime then
    return c.proj
  end
  local data, err = read_project_file(found)
  if not data then
    return nil, err
  end
  local proj, ferr = finalize(data)
  if not proj then
    return nil, found .. ": " .. ferr
  end
  -- Keep runtime state (queue, status) when the file is re-read.
  if c and c.proj then
    proj.state = c.proj.state
  end
  cache[found] = { mtime = mtime, proj = proj }
  return proj
end

--- Path of `abs` relative to the project root, or nil when outside it.
function M.relpath(proj, abs)
  abs = normalize(abs)
  if not is_within(abs, proj.local_root) or abs == proj.local_root then
    return nil
  end
  return abs:sub(#proj.local_root + 2)
end

local glob_cache = {}

local function glob_match(g, rel)
  local lp = glob_cache[g]
  if not lp then
    lp = vim.glob.to_lpeg(g)
    glob_cache[g] = lp
  end
  return lp:match(rel) ~= nil
end

--- Whether a project-relative file path matches one of the exclude globs.
function M.is_excluded(proj, rel)
  for _, pat in ipairs(proj.exclude or {}) do
    local dir_only = pat:sub(-1) == "/"
    local p = pat:gsub("/+$", ""):gsub("^/+", "")
    local anchored = pat:find("/", 1, true) ~= nil and pat:find("/", 1, true) < #pat
    local prefix = anchored and "" or "**/"
    if glob_match(prefix .. p .. "/**", rel) then
      return true
    end
    if not dir_only and glob_match(prefix .. p, rel) then
      return true
    end
    if not anchored and not dir_only and glob_match(p, rel) then
      return true
    end
  end
  return false
end

return M
