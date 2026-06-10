# git-commit-lock

A small mutex that lets several agents **commit from one shared Git checkout
without tripping over each other**.

A Git working tree has one index and one `HEAD`. Git's own `index.lock`
protects them from corruption, but it does so by making the loser of a race
*fail* ("Unable to create '.../index.lock'"), not wait — and it doesn't stop
two agents' staging operations from interleaving, so one agent's commit can
sweep up paths another agent had just staged. `git-commit-lock` adds the
queueing Git doesn't provide: each agent wraps its stage+commit step in the
lock, and concurrent committers take turns.

The tool automates only the lock. What to stage and commit stays in the
caller's hands — each agent still names exactly the paths or hunks it owns.

## Why

Multi-agent coding sessions routinely put many processes in one checkout.
Subagents run in their parent's working directory — in Claude Code, Codex, and
similar tools they don't get a worktree of their own — so even a workflow that
gives every top-level agent its own worktree ends up with each fan-out of
subagents sharing one tree.

Committing from that shared tree is often exactly what you want. A session
might fan out a dozen subagents doing uncoupled work in parallel — drafting
plans for several features at once, fixing independent review findings,
updating docs file-by-file — and when each one commits its own change as it
finishes, the history records how the work evolved, instead of arriving as one
squashed blob at the end. `git-commit-lock` exists to make those concurrent
commits safe.

Typical setups:

- a Claude Code workflow fanning out subagents that draft plans for several
  features at once, each committing its own plan file as it lands;
- parallel review/fix agents committing focused fixes to different files as
  they finish;
- one agent iterating on a plan while another implements;
- any shared checkout where creating and bootstrapping a worktree for every
  small agent task is more machinery than the task needs.

This works best when the work is already partitioned — by file, by role, or by
a coordinator sequencing agents whose edits would overlap. The lock makes
concurrent *commits* safe; it does not make concurrent *edits* safe. It does
not isolate working-tree changes, assign file ownership, or make broad Git
operations safe: agents must still stage only the paths or hunks they own, and
avoid `git add -A`, `git commit -a`, and `git stash` in shared checkouts. If
many agents will edit the same paths concurrently, add file-level coordination
or use separate checkouts (see
[Alternatives](#alternatives-and-related-tools)).

## How it works

The lock is a directory in the repo's git dir (`.git/commit.lock`), acquired
with an atomic `mkdir` — atomic on POSIX filesystems and NTFS alike, with no
dependency on `flock`. Every worktree has its own git dir, so independent
worktrees get independent locks, while all agents sharing one checkout contend
on the same lock. A lock held longer than 5 minutes (configurable) is presumed
crashed and is stolen, so a dead agent can't wedge the others; a holder that
loses the lock mid-hold finds out at release (exit code 2) rather than
silently claiming success. Full design and rationale:
[`docs/git-commit-lock.md`](docs/git-commit-lock.md).

Two wire-compatible implementations share one lock directory and protocol, so
a bash holder and a PowerShell holder in the same tree serialise against
**each other**:

- `git-commit-lock.sh` — bash (the authoritative implementation)
- `git-commit-lock.ps1` — PowerShell port, for agents whose native shell is pwsh

The scripts use only portable primitives, but so far they have been exercised
mainly on Windows (Git Bash + PowerShell 7).

## Install

Requirements:

- Git, and bash for `git-commit-lock.sh`. On Windows use Git Bash/MSYS2 bash,
  not WSL bash — an install done from WSL is only visible inside WSL.
- PowerShell 7+ (`pwsh`), only for `git-commit-lock.ps1` and the interop tests.
- `~/.local/bin` on `PATH` if you want the installed command names to resolve
  (the installer warns if it isn't).

After cloning this repository, run the installer:

```sh
cd git-commit-lock
bash install.sh
```

This symlinks `git-commit-lock.sh` and `git-commit-lock.ps1` into
`~/.local/bin/` and is idempotent — re-run any time, e.g. after moving the
repo. On Windows, real symlinks require Developer Mode; if symlinks are
unavailable, skip the installer and invoke the scripts by path from the clone
(e.g. `path/to/git-commit-lock/git-commit-lock.sh`). Installing is only a
convenience so every checkout can use the same command names.

## Suggested agent instructions

Agents only benefit from the lock if their instructions tell them to use it.
Copy this into the instruction context (`AGENTS.md`, `CLAUDE.md`, Cursor
rules, etc.) for agents that may share one checkout:

````markdown
## Shared checkouts: commit lock

When several agents or subagents may be active in the same checkout, take the
commit lock for the brief moment you stage and commit. Stage only the paths or
hunks you own. Never use `git add -A`, `git commit -a`, `git commit -am`, or
`git stash` in a shared checkout.

Use the shell-native lock command for the agent. On Windows, use
`git-commit-lock.ps1` through `pwsh` rather than a bash wrapper unless you
know that bash resolves to the same Git and signing environment.

Bash:

```sh
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git add -- path/you/changed another/path &&
  git commit -m "your message"'
```

PowerShell:

```powershell
pwsh -NoProfile -File "$HOME/.local/bin/git-commit-lock.ps1" run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'your message' }"
```

If you want to run the git steps one at a time — for example to review the
staged diff before committing — source the library and drive the lock
yourself, keeping the whole hold brief:

```sh
source ~/.local/bin/git-commit-lock.sh
lock_acquire || exit 1
git add -- path/you/changed
git diff --cached
git commit -m "your message"
lock_release
```

Hold the lock only for stage+commit. Decide what to stage, build patches, run
tests, and fix hook failures outside the lock. If a commit fails under the
lock, unstage your paths with `git reset -- <paths>`, release the lock, fix
the problem, then retry.

If the command exits 2 with the lock-stolen warning, the lock was lost
mid-hold and the commit was not serialised; check `git log` and redo the
commit under the lock. Otherwise, inspect stderr and the wrapped command's
exit code.

If a file contains both your changes and someone else's WIP, do not `git add`
the whole file. Stage only your hunk with `git add -p`, or prepare a patch
outside the lock and apply it to the index under the lock:

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git diff --cached --quiet || { echo "index not clean" >&2; exit 1; }
  git apply --cached /tmp/mine.patch &&
  git commit -m "your message"'
```

Use a bare `git commit` for index-only commits. Do not use
`git commit -- <file>` in this case because it re-reads the working tree and
can pull in someone else's WIP.
````

## Usage

Bash — run a command under the lock:

```sh
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git add -- path/you/changed && git commit -m "your message"'
```

PowerShell:

```powershell
pwsh -NoProfile -File "$HOME/.local/bin/git-commit-lock.ps1" run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
```

If a single wrapped command is awkward — say you want to review the staged
diff before committing — source the library and drive the lock yourself:

```sh
source ~/.local/bin/git-commit-lock.sh
lock_acquire || exit 1
git add -- path/you/changed
git diff --cached        # check the staged commit is what you intend
git commit -m "your message"
lock_release
```

(In PowerShell, dot-source `git-commit-lock.ps1` and use `Lock-Acquire` /
`Lock-Release` in a `try`/`finally`.) Keep the hold brief either way: the lock
is a lease, and a hold longer than the staleness window (default 5 minutes)
can be stolen by a waiter. Prepare everything you can outside the lock, and
never wait on a human while holding it. `lock_acquire` arms an exit trap, so
the lock is released even if the shell dies mid-hold.

The exit code of `run` is the wrapped command's. If it exits 2 with the
lock-stolen warning, the lock was lost mid-hold and the commit was NOT
serialised — verify with `git log` and redo. If the lock can't be acquired
within `AGENT_LOCK_MAX_WAIT` (default 7 minutes), the command isn't run and
the exit code is 1 with a timeout message on stderr. See
[`docs/git-commit-lock.md`](docs/git-commit-lock.md) for the `AGENT_LOCK_*` config
knobs and how staleness and stealing work.

## Alternatives and related tools

If each agent can have its own checkout or index, or you need to coordinate
*edits* rather than commits, other tools fit better — alone or alongside the
lock:

- [Git worktrees][git-worktree] give each agent its own working directory,
  `HEAD`, and index. Claude Code, Codex, and Cursor all document
  worktree-based agent flows: [Claude Code worktrees][claude-worktrees],
  [Codex app worktrees][codex-worktrees], and
  [Cursor worktrees][cursor-worktrees]. Note that subagents still run inside
  their parent's worktree, which is where `git-commit-lock` comes in.
- [GitButler parallel branches][gitbutler-parallel] keep multiple logical
  branches in one working directory, with branch-aware change assignment.
- Jeffrey Emanuel's [MCP Agent Mail][agent-mail] gives agents identities,
  threaded messages, advisory file reservations before editing, and an
  optional pre-commit guard (see also the [Agent Mail
  skill][agent-mail-skill]). Those reservations coordinate editing intent;
  `git-commit-lock` can still be used underneath them for the shared-index
  stage+commit step. His older [Claude Code Agent Farm][agent-farm] also uses
  lock files for work/file claiming before agents edit.
- Cloud PR agents such as [GitHub Copilot cloud agent][copilot-cloud] and
  [Jules][jules] clone into isolated environments and return branch/PR-shaped
  work, avoiding the shared checkout entirely.

## Running the tests

```sh
bash git-commit-lock.test.sh             # bash implementation
bash git-commit-lock.interop.test.sh     # bash + PowerShell interop (skips if pwsh is absent)
bash git-commit-lock.integration.test.sh # end-to-end: concurrent real commits into one repo (pwsh half skips if absent)
```

All three suites print a summary line and exit 0 when everything passes.
They use throwaway temp dirs and never touch the repo you launch them from.
On Windows, run them from Git Bash/MSYS2 bash, **not** WSL bash, so the bash
and PowerShell sides resolve the same `C:/...` lock path.

## Licence

[MIT](LICENSE).

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
