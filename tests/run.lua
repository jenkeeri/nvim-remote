-- Headless end-to-end tests. Run with:  nvim --headless -u NONE -l tests/run.lua
-- A fake ssh (tests/fake_ssh.sh) executes the "remote" side locally.
local here = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local repo = vim.fs.dirname(here)
vim.opt.rtp:prepend(repo)
vim.opt.swapfile = false

local failures, passed = 0, 0
local function check(name, cond, info)
  if cond then
    passed = passed + 1
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (info and (": " .. vim.inspect(info)) or ""))
  end
end

local function sh(cmd)
  local res = vim.system({ "sh", "-c", cmd }, { text = true }):wait()
  assert(res.code == 0, cmd .. "\n" .. res.stderr)
  return res.stdout
end
local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end
local function read(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local c = fd:read("*a")
  fd:close()
  return c
end
local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

local tmp = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
local lroot = tmp .. "/local/proj"
local rroot = tmp .. "/remote/proj"
vim.fn.mkdir(lroot, "p")
vim.fn.mkdir(rroot .. "/build", "p")
write(rroot .. "/build/artifact.o", "remote-only")

write(lroot .. "/src/a.cpp", "int main() {}\n")
write(lroot .. "/src/gone.cpp", "x\n")
write(lroot .. "/py/tool.py", "print('hi')\n")
write(lroot .. "/.gitignore", "build/\n*.log\n")
write(lroot .. "/build/local.o", "ignored")
write(lroot .. "/debug.log", "ignored")
write(lroot .. "/notes.swp", "excluded")
sh("cd " .. lroot .. " && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init")
os.remove(lroot .. "/src/gone.cpp") -- tracked but deleted in worktree
write(lroot .. "/src/untracked.h", "#pragma once\n")
write(
  lroot .. "/.nvim-remote.json",
  vim.json.encode({ host = "devvm", remote_root = rroot, build_cmd = "sh build.sh" })
)

local nr = require("nvim-remote")
nr.setup({ ssh_cmd = { repo .. "/tests/fake_ssh.sh" }, notify = false, debounce_ms = 20, open_quickfix = "never" })
local config = require("nvim-remote.config")
local sync = require("nvim-remote.sync")

-- config / excludes
local proj = config.resolve(lroot .. "/src/a.cpp")
check("resolve project from .nvim-remote.json", proj and proj.host == "devvm" and proj.local_root == lroot, proj)
check("project inherits setup() options", proj and proj.debounce_ms == 20)
check("resolve outside project fails", config.resolve(tmp .. "/remote") == nil)
check("exclude .git dir", config.is_excluded(proj, ".git/config"))
check("exclude nested *.swp", config.is_excluded(proj, "a/b/c.swp"))
check("exclude top-level *.swp", config.is_excluded(proj, "c.swp"))
check("exclude project file", config.is_excluded(proj, ".nvim-remote.json"))
check("normal file not excluded", not config.is_excluded(proj, "src/a.cpp"))
check("dir-only pattern does not match file prefix", not config.is_excluded(proj, "src/.github"))
check("remote_quote", sync.remote_quote("~/a b'c") == [[~/'a b'\''c']])

local function wait_idle()
  local done = false
  sync.when_idle(proj, function()
    done = true
  end)
  return vim.wait(10000, function()
    return done
  end, 10)
end

-- full push (git aware)
local done
sync.push_all(proj, {}, function(ok)
  done = ok
end)
vim.wait(10000, function()
  return done ~= nil
end, 10)
check("full push succeeded", done == true, proj.state and proj.state.last_error)
check("tracked file pushed", read(rroot .. "/src/a.cpp") == "int main() {}\n")
check("untracked non-ignored file pushed", exists(rroot .. "/src/untracked.h"))
check("python file pushed", exists(rroot .. "/py/tool.py"))
check("gitignored files not pushed", not exists(rroot .. "/build/local.o") and not exists(rroot .. "/debug.log"))
check("excluded files not pushed", not exists(rroot .. "/notes.swp") and not exists(rroot .. "/.nvim-remote.json"))
check(".git not pushed", not exists(rroot .. "/.git"))
check("remote-only build artifacts kept", read(rroot .. "/build/artifact.o") == "remote-only")

-- push on save (including a new nested directory)
vim.cmd("edit " .. vim.fn.fnameescape(lroot .. "/src/a.cpp"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "int main() { return 1; }" })
vim.cmd("write")
vim.cmd("edit " .. vim.fn.fnameescape(lroot .. "/new/dir/b.java"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "class B {}" })
vim.cmd("write ++p")
check("save queue drained", wait_idle())
check("saved file pushed", read(rroot .. "/src/a.cpp") == "int main() { return 1; }\n")
check("new file in new dir pushed", read(rroot .. "/new/dir/b.java") == "class B {}\n")

vim.cmd("edit " .. vim.fn.fnameescape(lroot .. "/x.swp"))
vim.cmd("write")
wait_idle()
check("excluded file not pushed on save", not exists(rroot .. "/x.swp"))

nr.toggle()
vim.cmd("edit " .. vim.fn.fnameescape(lroot .. "/src/a.cpp"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed while disabled" })
vim.cmd("write")
wait_idle()
check("toggle disables push on save", read(rroot .. "/src/a.cpp") == "int main() { return 1; }\n")
nr.toggle()
vim.cmd("RemotePushFile")
wait_idle()
check(":RemotePushFile pushes explicitly", read(rroot .. "/src/a.cpp") == "changed while disabled\n")
check("statusline", nr.statusline() == "⇅ proj", nr.statusline())

-- remote exec -> quickfix with path translation
write(
  rroot .. "/build.sh",
  "printf '%s\\n' \"$(pwd)/src/a.cpp:1:5: error: boom\"\nprintf 'plain line\\n' >&2\nexit 2\n"
)
local code
vim.api.nvim_create_autocmd("User", {
  pattern = "NvimRemoteExecDone",
  once = true,
  callback = function(ev)
    code = ev.data.code
  end,
})
vim.cmd("RemoteBuild")
vim.wait(10000, function()
  return code ~= nil
end, 10)
check("remote build exit code reported", code == 2, code)
local items = vim.fn.getqflist()
local hit
for _, it in ipairs(items) do
  if it.valid == 1 then
    hit = it
  end
end
check(
  "quickfix entry maps remote path to local file",
  hit and vim.api.nvim_buf_get_name(hit.bufnr) == lroot .. "/src/a.cpp" and hit.lnum == 1 and hit.col == 5,
  items
)
check("quickfix title", vim.fn.getqflist({ title = 0 }).title:find("sh build.sh", 1, true) ~= nil)

-- pull with compile_commands.json rewrite
write(
  rroot .. "/build/compile_commands.json",
  vim.json.encode({ { directory = rroot .. "/build", file = rroot .. "/src/a.cpp" } })
)
write(rroot .. "/gen/out.txt", "generated")
local pulled
sync.pull(proj, { "build/compile_commands.json", "gen" }, function(ok)
  pulled = ok
end)
vim.wait(10000, function()
  return pulled ~= nil
end, 10)
check("pull succeeded", pulled == true)
local cc = read(lroot .. "/build/compile_commands.json") or ""
check("compile_commands.json paths rewritten", cc:find(lroot .. "/src/a.cpp", 1, true) and not cc:find(rroot, 1, true), cc)
check("directory pulled", read(lroot .. "/gen/out.txt") == "generated")

-- non-git project with mirror delete, configured via setup()
local l2, r2 = tmp .. "/local/plain", tmp .. "/remote/plain"
write(l2 .. "/main.c", "int x;\n")
write(l2 .. "/sub/keep.txt", "k")
write(r2 .. "/stale.txt", "old")
nr.setup({
  ssh_cmd = { repo .. "/tests/fake_ssh.sh" },
  notify = false,
  projects = { { local_root = l2, host = "devvm", remote_root = r2 .. "/" } },
})
local p2 = config.resolve(l2 .. "/main.c")
check("setup() project resolves", p2 and p2.remote_root == r2, p2)
done = nil
sync.push_all(p2, { delete = true }, function(ok)
  done = ok
end)
vim.wait(10000, function()
  return done ~= nil
end, 10)
check("non-git mirror push", done and read(r2 .. "/sub/keep.txt") == "k" and not exists(r2 .. "/stale.txt"))

-- failing push reports error state
local p3 = vim.deepcopy(p2)
p3.state = nil
p3.remote_root = "/nonexistent/dir/that/cannot/exist"
sync.queue(p3, { "main.c" }, true)
local ok3
sync.when_idle(p3, function(ok)
  ok3 = ok
end)
vim.wait(10000, function()
  return ok3 ~= nil
end, 10)
check("failed push sets error status", ok3 == false and p3.state.status == "error", p3.state)

vim.fn.delete(tmp, "rf")
print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
