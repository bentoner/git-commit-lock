# commit-lock

A small, portable, `flock`-free **mutex for committing from a shared working
tree**. When several agents (or sub-agents) commit into the *same* checkout at
once, their `git commit`s race on `.git/index.lock` and a stray `git add -A`
can stage someone else's half-written work. `commit-lock` serialises just the
stage+commit step so that doesn't happen.

It is the only automated piece of the shared-checkout commit story — *what* to
stage and commit is still done manually by the caller, under the lock.

## When to use this

Prefer isolation when it is cheap. A [git worktree][git-worktree] gives each
agent its own working directory, `HEAD`, and index, which is the cleanest way to
run independent coding sessions in parallel. Claude Code, Codex, and Cursor all
have worktree-based agent flows:

- [Claude Code worktrees][claude-worktrees], including optional worktree
  isolation for subagents.
- [Codex app worktrees][codex-worktrees], for running independent tasks without
  touching the local checkout.
- [Cursor worktrees][cursor-worktrees], including `/worktree` and `/best-of-n`
  agent runs.

Use `commit-lock` for the narrower case where several agents are intentionally
sharing one checkout and you still want them to make commits. Typical examples:

- a workflow / Ultracode-style agent swarm where many short-lived subagents run
  in the parent checkout;
- a manually coordinated subagent swarm where review/fix agents should commit
  focused changes as they finish;
- a shared `main` checkout where spinning up, bootstrapping, and cleaning up a
  worktree for every tiny agent would cost more than the task itself.

In that situation, the problem is not branch isolation. The problem is that all
agents share one git index. `commit-lock` serialises only the short
stage+commit critical section so two agents do not race on `.git/index.lock` or
interleave staging operations.

This is not a replacement for worktrees, branches, or careful file ownership. It
does not prevent two agents from editing the same file at the same time, and it
does not make `git add -A`, `git commit -a`, or `git stash` safe in a shared
checkout. Agents must still stage only the paths or hunks they own.

Other useful tools solve adjacent problems:

- [Git worktrees][git-worktree] are the baseline primitive for per-agent
  filesystem/index isolation.
- [GitButler parallel branches][gitbutler-parallel] keep multiple logical
  branches in one working directory, with branch-aware change assignment.
- Cloud PR agents such as [GitHub Copilot cloud agent][copilot-cloud] and
  [Jules][jules] avoid the local shared-checkout problem by cloning into an
  isolated environment and returning branch/PR-shaped work.

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

[git-worktree]: https://git-scm.com/docs/git-worktree
[claude-worktrees]: https://code.claude.com/docs/en/worktrees
[codex-worktrees]: https://developers.openai.com/codex/app/worktrees
[cursor-worktrees]: https://cursor.com/docs/configuration/worktrees
[gitbutler-parallel]: https://docs.gitbutler.com/features/branch-management/virtual-branches
[copilot-cloud]: https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent
[jules]: https://jules.google/docs/
