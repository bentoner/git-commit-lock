# commit-lock

A small, portable, `flock`-free **mutex for committing from a shared working
tree**. When several agents (or sub-agents) commit into the *same* checkout at
once, their `git commit`s race on `.git/index.lock` and a stray `git add -A`
can stage someone else's half-written work. `commit-lock` serialises just the
stage+commit step so that doesn't happen.

It is the only automated piece of the shared-checkout commit story — *what* to
stage and commit is still done manually by the caller, under the lock.

Two wire-compatible implementations share one lock dir + protocol, so a bash
holder (Claude) and a PowerShell holder (Codex) in the same tree serialise
against **each other**:

- `commit-lock.sh` — bash (the authoritative implementation)
- `commit-lock.ps1` — PowerShell port (for agents whose native shell is pwsh)

> The **agent operating rules** for using the lock (take it only for
> stage+commit; never `git add -A/-a/-am`; never `git stash` in a shared
> checkout; the same-file-hunk recipe) live in the **dotfiles** repo at
> `agents/210-using-git.md`. This repo is the tool + its design; that doc is the
> policy. Full design/rationale: [`docs/commit-lock.md`](docs/commit-lock.md).

## Install

```sh
bash install.sh
```

Symlinks `commit-lock.sh` and `commit-lock.ps1` into `~/.local/bin/` (real
symlinks; on Windows this needs Developer Mode on). Ensure `~/.local/bin` is on
your `PATH`. Re-run any time (e.g. after moving the repo) — it's idempotent.

## Usage

Bash (Claude) — run a command under the lock:

```sh
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git add -- path/you/changed && git commit -m "your message"'
```

PowerShell (Codex):

```powershell
& ~/.local/bin/commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
```

Exit code is the command's; **exit 2** means the lock was lost mid-hold (your
commit was NOT serialised — verify with `git log` and redo). A lock held
>5 min is assumed crashed and is stolen automatically. See
[`docs/commit-lock.md`](docs/commit-lock.md) for the `run` vs source-the-lib
forms, the `AGENT_LOCK_*` config, and how staleness/steal works.

## Verifying on a new machine

```sh
bash commit-lock.test.sh           # bash impl;        "RESULT: 19 passed, 0 failed"
bash commit-lock.interop.test.sh   # cross-impl (pwsh); "INTEROP RESULT: 11 passed, 0 failed"
```

Run both from a Windows MINGW/Git-Bash (the same bash Claude uses), **not** WSL —
both sides must agree on the `C:/...` lock path. The interop suite needs `pwsh`
and `git-bash` on `PATH`. The suites use throwaway temp dirs and never touch the
repo you launch them from.
