# nvim-remote

Edit locally in Neovim, build and run on a remote Linux VM. Each file you
save is pushed to the VM with `rsync` over ssh. Compiler output comes back
into Neovim's quickfix list with the remote paths rewritten to your local
files. You don't need to commit or push anything to test a change.

```
 macbook (nvim)                          linux VM
 ~/src/engine  ── :w → rsync over ssh ─▶  /home/me/src/engine
               ◀── :RemoteBuild output ──  make -j / mvn / pytest …
                   (quickfix, local paths)
```

* **Push on save.** Writes are debounced and batched into a single `rsync`
  call. Every transfer reuses one persistent ssh connection
  (`ControlMaster`), so a save typically takes milliseconds.
* **Git-aware full push.** `:RemotePush` sends tracked files and untracked
  files that aren't ignored, using `git ls-files`, so `.gitignore` applies.
  It never deletes anything on the VM, which keeps remote `build/`
  directories intact.
* **Remote build and exec.** Use `:RemoteBuild` or `:RemoteExec make -j8`.
  Pending pushes finish first. Output streams into quickfix, and
  `/remote/root/...` paths become your local paths, so `:cn` jumps to
  C++, Java or Python errors.
* **Pull.** `:RemotePull build/compile_commands.json` fetches generated
  files. Remote paths inside `compile_commands.json` are rewritten to
  local paths, so clangd on the Mac can find your sources.
* **Remote shell.** `:RemoteShell` opens a terminal split that's already
  `cd`'d into the project on the VM.
* **Several projects at once.** Each buffer is matched to its own project
  and VM.

## Requirements

* Neovim ≥ 0.10.
* `rsync` and `ssh` on the Mac. The macOS built-in `openrsync` works, and so
  does `brew install rsync`.
* `rsync` installed on the VM.
* Password-less ssh to the VM through keys or ssh-agent. Prompts are disabled
  with `BatchMode=yes` because a hidden password prompt would hang the
  transfer.

An entry in `~/.ssh/config` is the easiest way to set this up:

```sshconfig
Host devvm
  HostName 10.0.0.42
  User me
  IdentityFile ~/.ssh/id_ed25519
```

## Installation (NvChad / lazy.nvim)

Create `~/.config/nvim/lua/plugins/remote.lua`, or add the spec to
`lua/plugins/init.lua`:

```lua
return {
  {
    "jenkeeri/nvim-remote",
    event = "VeryLazy",
    opts = {
      -- every option is optional, see "Configuration" below
      -- build_cmd = "cmake --build build -j$(nproc)",
    },
    keys = {
      { "<leader>rb", "<cmd>RemoteBuild<cr>", desc = "Remote build" },
      { "<leader>rp", "<cmd>RemotePush<cr>", desc = "Remote push project" },
      { "<leader>rf", "<cmd>RemotePushFile<cr>", desc = "Remote push file" },
      { "<leader>rs", "<cmd>RemoteShell<cr>", desc = "Remote shell" },
      { "<leader>rx", ":RemoteExec ", desc = "Remote exec" },
      { "<leader>rk", "<cmd>RemoteStop<cr>", desc = "Remote stop" },
      { "<leader>rt", "<cmd>RemoteSyncToggle<cr>", desc = "Toggle push on save" },
    },
  },
}
```

To work on a local clone instead, use `dir = "~/path/to/nvim-remote"` in
place of the repo name.

## Telling a repo where it lives on the VM

**Option A: a per-repo `.nvim-remote.json`.** Put this file in the root of
the local checkout and add it to your global gitignore:

```json
{
  "host": "devvm",
  "remote_root": "/home/me/src/engine",
  "build_cmd": "cmake --build build -j$(nproc) 2>&1"
}
```

**Option B: list your projects in `setup()`:**

```lua
opts = {
  projects = {
    { local_root = "~/src/engine", host = "devvm", remote_root = "/home/me/src/engine",
      build_cmd = "cmake --build build -j16" },
    { local_root = "~/src/backend", host = "devvm", remote_root = "/home/me/src/backend",
      build_cmd = "mvn -q -B compile", errorformat = "[ERROR] %f:[%l\\,%v] %m" },
    { local_root = "~/src/tools", host = "devvm", remote_root = "/home/me/src/tools",
      build_cmd = "python -m pytest -q" },
  },
}
```

Any option below can be overridden per project, in either option.
`remote_root` should be an absolute path without spaces.

The first time, run `:RemotePush` to send the whole repo. After that, saving
is enough. Run `:checkhealth nvim-remote` to check ssh, rsync and the remote
directory.

## Commands

| Command | What it does |
|---|---|
| `:RemotePush` | Push the whole project. Git repos send tracked files plus untracked files that aren't ignored. |
| `:RemotePush!` | Non-git projects only: mirror with `--delete` (asks for confirmation). |
| `:RemotePushDry` | Show what `:RemotePush` would transfer. |
| `:RemotePushFile [file]` | Push the current (or given) file right away. |
| `:RemotePull [path…]` | Pull files or directories (relative to the project root) from the VM. Tab completion lists remote paths. |
| `:RemoteBuild [args]` | Run `build_cmd` (plus `args`) in `remote_root`. Output goes to quickfix. |
| `:RemoteExec {cmd}` | Run any command in `remote_root`, e.g. `:RemoteExec ./build/bin/tests --gtest_filter=Foo*`. |
| `:RemoteStop` | Kill the running remote command. |
| `:RemoteShell [cmd]` | Open an interactive ssh terminal in `remote_root`. |
| `:RemoteSyncToggle` | Turn push-on-save on or off. |
| `:RemoteStatus` | Show project, remote, pending pushes and the last error. |

## Configuration (defaults)

```lua
require("nvim-remote").setup({
  sync_on_save = true,
  debounce_ms = 150,
  exclude = { ".git/", ".nvim-remote.json", ".DS_Store", "*.swp", "*~" },
  use_git = true,                 -- use git ls-files for :RemotePush
  rsync_cmd = "rsync",
  rsync_args = { "-az" },
  ssh_cmd = { "ssh" },
  ssh_args = { "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/nvim-remote-%C",
               "-o", "ControlPersist=10m", "-o", "BatchMode=yes" },
  build_cmd = nil,
  sync_before_exec = true,        -- wait for pending pushes before exec/build
  exec_tty = true,                -- remote tty so :RemoteStop kills the remote process
  open_quickfix = "on_error",     -- "always" | "on_error" | "never"
  errorformat = nil,              -- nil = use 'errorformat' (gcc/clang style by default)
  rewrite_on_pull = { "compile_commands.json" },
  notify = true,
  notify_on_save = false,
  projects = {},
})
```

In `exclude`, a pattern without `/` matches at any depth, and a trailing
`/` means directories only.

### Statusline (NvChad)

`require("nvim-remote").statusline()` returns `⇅ engine`, adding `…` while
syncing, `!` after an error and `⚙` while a remote command runs. It returns
an empty string outside projects. To add it to NvChad's statusline, put this
in `chadrc.lua`:

```lua
M.ui = {
  statusline = {
    modules = {
      remote = function()
        local ok, r = pcall(require, "nvim-remote")
        return ok and ("%#St_gitIcons# " .. r.statusline() .. " ") or ""
      end,
    },
    order = { "mode", "file", "git", "%=", "lsp_msg", "%=", "remote", "diagnostics", "lsp", "cwd", "cursor" },
  },
}
```

The plugin also fires `User NvimRemoteStatus` when the sync status changes,
and `User NvimRemoteExecDone` (with `data.code`) when a remote command
finishes.

## Notes and limitations

* Pushing is one-way, from local to remote. Files created on the VM (build
  outputs, generated code) are never overwritten or deleted unless you push
  a file with the same path. Use `:RemotePull` to bring files back.
* Deleting or renaming a file locally does not delete it on the VM. Remove
  stale files with `:RemoteExec rm path/to/old.cpp`. For non-git projects,
  `:RemotePush!` mirrors the directory with `--delete`.
* After `git checkout`, `git pull` or a rebase on the Mac, run `:RemotePush`.
  Only changed files are transferred.
* Errors from a failed push are shown, and the failed files are retried on
  the next push.

## Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```

The tests use `tests/fake_ssh.sh` in place of ssh, so the "remote" side runs
locally. No VM is needed.
