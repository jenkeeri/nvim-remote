local M = {}

function M.check()
  local health = vim.health
  health.start("nvim-remote")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end
  local config = require("nvim-remote.config")
  local opts = config.options
  for _, bin in ipairs({ opts.rsync_cmd, opts.ssh_cmd[1], "git" }) do
    if vim.fn.executable(bin) == 1 then
      health.ok(bin .. " found: " .. vim.fn.exepath(bin))
    else
      health.error(bin .. " not found in $PATH")
    end
  end

  local proj, err = config.resolve()
  if not proj then
    health.info("current buffer: " .. err)
    return
  end
  health.ok("project '" .. proj.name .. "': " .. proj.local_root .. " -> " .. proj.host .. ":" .. proj.remote_root)
  local exec = require("nvim-remote.exec")
  local cmd = exec.remote_command(proj, "command -v rsync >/dev/null && echo ok-rsync")
  table.insert(cmd, #cmd - 1, "-o")
  table.insert(cmd, #cmd - 1, "ConnectTimeout=5")
  local res = vim.system(cmd, { text = true }):wait(10000)
  if res.code == 0 and res.stdout:find("ok-rsync", 1, true) then
    health.ok("ssh to " .. proj.host .. " works, remote_root exists and rsync is installed remotely")
  else
    health.error(
      "remote check failed (exit " .. tostring(res.code) .. "): " .. vim.trim((res.stderr or "") .. (res.stdout or "")),
      {
        "Make sure `ssh " .. proj.host .. "` works without a password prompt (ssh keys / ssh-agent)",
        "Make sure " .. proj.remote_root .. " exists on the remote and rsync is installed there",
      }
    )
  end
end

return M
