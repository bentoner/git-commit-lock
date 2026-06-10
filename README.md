# commit-lock

A small, portable, `flock`-free **mutex for committing from a shared working
tree**. When several agents (or sub-agents) commit into the *same* checkout at
once, their `git add` / `git commit` commands can race on `.git/index.lock` or
interleave staging operations. `commit-lock` serialises only the stage+commit
step; the caller still decides exactly which paths or hunks to stage.

It is the only automated piece of the shared-checkout commit story — *what* to
stage and commit is still done manually by the caller, under the lock.

## When this makes sense

`commit-lock` is for agent workflows where several processes share one Git
checkout and each process may need to create commits. In that setup, all agents
share one `HEAD` and one Git index, so concurrent `git add` / `git commit`
operations can collide.

Typical cases:

- an agent swarm runner where short-lived subagents run in the parent checkout;
- a manually coordinated subagent swarm where review/fix agents commit focused
  changes as they finish;
- one agent writing a plan while another implements, or several agents creating
  independent plans/docs in separate files;
- a shared checkout where creating and bootstrapping a worktree for every small
  agent task is more machinery than the task needs.

This fits workflows where a coordinator is already thinking about conflicts:
partitioning work, sending execution agents sequentially when their edits would
overlap, and using the shared checkout mainly for planning-doc iteration,
reviews, small fixes, and other low-conflict tasks. In those cases, separate
worktrees and file reservations may not add much because the work is already
partitioned by file or role, but the agents can still collide in Git if they
stage and commit at the same time. If many execution agents will edit the same
code paths concurrently, add file-level coordination as well or use separate
checkouts.

`commit-lock` covers only the brief stage+commit critical section. It serialises
that section so agents do not race on `.git/index.lock` or interleave staging
operations.

It does not isolate working-tree edits, assign file ownership, or make broad Git
operations safe. Agents still need to stage only the paths or hunks they own and
avoid `git add -A`, `git commit -a`, and `git stash` in shared checkouts.

Coordination boundaries:

- [Git worktrees][git-worktree] give each agent its own working directory,
  `HEAD`, and index. Claude Code, Codex, and Cursor all document worktree-based
  agent flows: [Claude Code worktrees][claude-worktrees],
  [Codex app worktrees][codex-worktrees], and
  [Cursor worktrees][cursor-worktrees].
- [GitButler parallel branches][gitbutler-parallel] keep multiple logical
  branches in one working directory, with branch-aware change assignment.
- Jeffrey Emanuel's [MCP Agent Mail][agent-mail] gives agents identities,
  threaded messages, advisory file reservations before editing, and an optional
  pre-commit guard. The public [Agent Mail skill][agent-mail-skill] documents
  that workflow for agents. Those reservations coordinate editing intent;
  `commit-lock` can still be used underneath them for the shared-index
  stage+commit step. His older [Claude Code Agent Farm][agent-farm] also uses
  lock files for work/file claiming before agents edit.
- Cloud PR agents such as [GitHub Copilot cloud agent][copilot-cloud] and
  [Jules][jules] clone into isolated environments and return branch/PR-shaped
  work.

Two wire-compatible implementations share one lock dir + protocol, so a bash
holder and a PowerShell holder in the same tree serialise against **each
other**:

- `commit-lock.sh` — bash (the authoritative implementation)
- `commit-lock.ps1` — PowerShell port (for agents whose native shell is pwsh)

If you want agents to use the lock consistently, add the suggested wording below
to your user or project instructions (`AGENTS.md`, `CLAUDE.md`, Cursor rules,
etc.). Full design/rationale: [`docs/commit-lock.md`](docs/commit-lock.md).

## Install

Requirements:

- Git and a POSIX-like shell for `commit-lock.sh`.
- PowerShell for `commit-lock.ps1` (`pwsh` is needed for the interop tests).
- `~/.local/bin` on `PATH` if you want the installed command names to resolve.
- On Windows, use Windows Git Bash/MSYS2 bash for install and shell tests, not
  WSL bash. WSL installation only affects the WSL environment.
- Real symlink installation on Windows requires Developer Mode. If symlinks are
  unavailable, invoke the scripts by path from the clone.

After cloning this repository, run the installer:

```sh
cd commit-lock
bash install.sh
```

Symlinks `commit-lock.sh` and `commit-lock.ps1` into `~/.local/bin/` (real
symlinks; on Windows this needs Developer Mode on). Ensure `~/.local/bin` is on
your `PATH`. Re-run any time (e.g. after moving the repo) — it's idempotent.

You can also point an agent at a clone and have it invoke the scripts by path,
for example `path/to/commit-lock/commit-lock.sh` or
`path/to/commit-lock/commit-lock.ps1`. Installing into `~/.local/bin` is only a
convenience so every checkout can use the same command.

## Suggested agent instructions

Copy this into the instruction context for agents that may share one checkout:

````markdown
## Shared checkouts: commit lock

When several agents or subagents may be active in the same checkout, take the
commit lock for the brief moment you stage and commit. Stage only the paths or
hunks you own. Never use `git add -A`, `git commit -a`, `git commit -am`, or
`git stash` in a shared checkout.

Use the shell-native lock command for the agent. On Windows/PowerShell, use
`commit-lock.ps1` rather than a bash wrapper unless you know that bash resolves
to the same Git and signing environment.

Bash:

```sh
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git add -- path/you/changed another/path &&
  git commit -m "your message"'
```

PowerShell:

```powershell
& ~/.local/bin/commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'your message' }"
```

Hold the lock only for stage+commit. Decide what to stage, build patches, run
tests, and fix hook failures outside the lock. If a commit fails under the lock,
unstage your paths with `git reset -- <paths>`, release the lock, fix the
problem, then retry.

If the command exits 2 with the lock-stolen warning, the lock was lost mid-hold
and the commit was not serialised; check `git log` and redo the commit under the
lock. Otherwise, inspect stderr and the wrapped command's exit code.

If a file contains both your changes and someone else's WIP, do not `git add`
the whole file. Stage only your hunk with `git add -p`, or prepare a patch
outside the lock and apply it to the index under the lock:

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git diff --cached --quiet || { echo "index not clean" >&2; exit 1; }
  git apply --cached /tmp/mine.patch &&
  git commit -m "your message"'
```

Use a bare `git commit` for index-only commits. Do not use
`git commit -- <file>` in this case because it re-reads the working tree and can
pull in someone else's WIP.
````

## Usage

Bash — run a command under the lock:

```sh
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git add -- path/you/changed && git commit -m "your message"'
```

PowerShell:

```powershell
& ~/.local/bin/commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
```

Exit code is the command's. If it exits 2 with the lock-stolen warning, the lock
was lost mid-hold and the commit was NOT serialised — verify with `git log` and
redo. A lock held >5 min is assumed crashed and is stolen automatically. See
[`docs/commit-lock.md`](docs/commit-lock.md) for the `run` vs source-the-lib
forms, the `AGENT_LOCK_*` config, and how staleness/steal works.

## Verifying on a new machine

```sh
bash commit-lock.test.sh           # bash impl;        "RESULT: 19 passed, 0 failed"
bash commit-lock.interop.test.sh   # cross-impl (pwsh); "INTEROP RESULT: 11 passed, 0 failed"
```

Run both from Windows Git Bash/MSYS2 bash, **not** WSL — both sides must agree
on the `C:/...` lock path. The interop suite needs `pwsh` and `git-bash` on
`PATH`. The suites use throwaway temp dirs and never touch the repo you launch
them from.

[git-worktree]: https://git-scm.com/docs/git-worktree
[claude-worktrees]: https://code.claude.com/docs/en/worktrees
[codex-worktrees]: https://developers.openai.com/codex/app/worktrees
[cursor-worktrees]: https://cursor.com/docs/configuration/worktrees
[gitbutler-parallel]: https://docs.gitbutler.com/features/branch-management/virtual-branches
[agent-mail]: https://github.com/Dicklesworthstone/mcp_agent_mail_rust
[agent-mail-skill]: https://github.com/Dicklesworthstone/agent_flywheel_clawdbot_skills_and_integrations/blob/main/skills/agent-mail/SKILL.md
[agent-farm]: https://github.com/Dicklesworthstone/claude_code_agent_farm
[copilot-cloud]: https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent
[jules]: https://jules.google/docs/
