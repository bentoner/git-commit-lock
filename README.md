# git-commit-lock

[![tests](https://github.com/bentoner/git-commit-lock/actions/workflows/tests.yml/badge.svg)](https://github.com/bentoner/git-commit-lock/actions/workflows/tests.yml)

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
might fan out a dozen subagents doing uncoupled work in parallel, and when
each one commits its own change as it finishes, the history records how the
work evolved, instead of arriving as one squashed blob at the end.
`git-commit-lock` exists to make those concurrent commits safe.

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

The lock is a file in the repo's git dir (`.git/commit.lock`), created with an
atomic create-or-fail open (`O_CREAT|O_EXCL` / `FileMode.CreateNew`) — atomic
on local POSIX filesystems and NTFS alike, with no dependency on `flock` —
whose content is the holder's unique token. Every worktree has its own git
dir, so independent worktrees get independent locks, while all agents sharing
one checkout contend on the same lock. The lock is deliberately a stealable
**lease**, not a kernel lock: in unattended agent fleets a hung-but-alive
holder is at least as common as a crashed one, and a lock that can't be taken
from a stuck holder halts the whole run — while a rare collision costs little
more than a failed commit. So a lock held longer than 5 minutes (configurable)
is presumed abandoned and can be stolen by a waiter, and a holder that loses
the lock mid-hold finds out at release (exit code 98) rather than silently
claiming success. Recovery from a crash is itself guarded: stealing is
serialized through a claim file, so when several waiters race to recover the
same dead lock exactly one steals it and the recovering waiter keeps the
lock it recovered (except on the Windows PowerShell 5.1 lane, where a rival's
create can win the recovered path and the claimant backs off cleanly) — the
narrow residual races surface as the same loud exit 98. The lock is
advisory: it serialises cooperating agents and trusts the repo and every
process running as the same user — see
[Security and trust
assumptions](docs/git-commit-lock.md#security-and-trust-assumptions).
Full design and rationale — why a stealable lease beats
`flock` and other kernel locks here, and why no OS lock primitive spans
bash-on-MINGW64 and PowerShell/.NET anyway:
[`docs/git-commit-lock.md`](docs/git-commit-lock.md).

Two wire-compatible implementations share one lock file and protocol, so a
bash holder and a PowerShell holder in the same tree serialise against
**each other**:

- `git-commit-lock.sh` — bash (the authoritative implementation)
- `git-commit-lock.ps1` — PowerShell port, **for Windows agents** whose native
  shell is pwsh (e.g. Codex): on Windows a bare `bash` resolves to WSL for
  some agents, and WSL's git can't reach a Windows-side commit signer

PowerShell-on-POSIX is not a configuration we support; on macOS and Linux,
use the bash implementation. CI nevertheless runs the two implementations
against each other on all three OSes — not as platform support, but because
two independent implementations hammering one lock is cheap adversarial
verification of the protocol.

## Suggested agent instructions

Agents only benefit from the lock if their instructions tell them to use it.
Copy this into the instruction context (`AGENTS.md`, `CLAUDE.md`, Cursor
rules, etc.) for agents that may share one checkout (the `~/.local/bin`
paths assume the installer has run — see [Install](#install) below):

````markdown
## Shared checkouts: commit lock

When several agents or subagents may be active in the same checkout, take the
commit lock for the brief moment you stage and commit. Stage only the paths or
hunks you own. Never use `git add -A`, `git commit -a`, `git commit -am`, or
`git stash` in a shared checkout.

Bash:

```sh
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git add -- path/you/changed another/path &&
  git commit -m "your message"'
```

PowerShell (on Windows, prefer this over a bash wrapper unless you know bash
resolves to the same Git and signing environment):

```powershell
pwsh -NoProfile -File "$HOME/.local/bin/git-commit-lock.ps1" run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'your message' }"
```

Hold the lock only for the stage+commit: decide what to stage, build patches,
run tests, and fix hook failures outside it. If a commit fails under the lock,
unstage with `git reset -- <paths>`, release, fix the problem, then retry.
Exit code 98 means the lock was lost mid-hold and the commit was NOT
serialised — check `git log` and redo the commit under the lock.

If a file contains both your changes and someone else's WIP, do not `git add`
the whole file. Stage only your hunks (`git add -p`, or prepare a patch
outside the lock and apply it to the index under the lock):

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch   # outside the lock; trim to your hunks
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git diff --cached --quiet || { echo "index not clean" >&2; exit 1; }
  git apply --cached /tmp/mine.patch &&
  git commit -m "your message"'
```

The `git commit` there is deliberately bare (it commits the index). Do not use
`git commit -- <file>` here: it re-reads the working tree and can pull in
someone else's WIP.

Details, the sourced API, and the full exit-code table: see the
git-commit-lock README and `docs/git-commit-lock.md` in its repository.
````

## Install

Requirements:

- Git, and bash for `git-commit-lock.sh`. On Windows use Git Bash/MSYS2 bash,
  not WSL bash — an install done from WSL is only visible inside WSL.
- PowerShell, only for `git-commit-lock.ps1` and the interop tests:
  PowerShell 7+ (`pwsh`) recommended; Windows PowerShell 5.1 (`powershell`)
  also works (covered by a CI smoke test).
- `~/.local/bin` on `PATH` if you want the installed command names to resolve
  (the installer warns if it isn't).

After cloning this repository, run the installer:

```sh
cd git-commit-lock
bash install.sh
```

This installs `git-commit-lock.sh` and `git-commit-lock.ps1` into
`~/.local/bin/` — as symlinks where possible, falling back to copies where
symlinks are unavailable (on Windows, real symlinks require Developer Mode;
both scripts are self-contained, so a copy works identically). It is
idempotent — re-run any time, e.g. after moving the repo. One caveat on the
copy fallback: a copy doesn't track the clone, so re-run `install.sh` after
pulling updates (the installer prints a reminder whenever it copies).
Installing is only a convenience so every checkout can use the same command
names; invoking the scripts by path from the clone
(e.g. `path/to/git-commit-lock/git-commit-lock.sh`) works just as well.

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
the lock is released on normal exit and on a handled INT/TERM; if the process
is killed outright (SIGKILL, a crash, power loss), the trap can't run and the
stale timeout recovers the lock instead.

The exit code of `run` is the wrapped command's, except for three reserved
high codes that report the lock's own outcomes:

| Exit code | Meaning |
|-----------|---------|
| 96 | usage error — bad arguments, or `run` outside a git repo with `AGENT_LOCK_PATH` unset; the command was never run. (An explicit `--help`/`-h` is not an error: usage on stdout, exit 0.) |
| 97 | lock acquisition timed out (`AGENT_LOCK_MAX_WAIT`, default 7 minutes) — the command was never run |
| 98 | lock stolen mid-hold — the command ran but was NOT serialised; verify with `git log` and redo it under the lock |

Anything else is the wrapped command's own exit code — with one caveat: when
ownership is *unverifiable* at release (the lock file still reads **empty**
while present, e.g. a successor mid-create after a boundary steal — not
provable theft, but not a verified-exclusive hold either), `run` fails a
*successful* command with exit **1**; a failing command keeps its own code.
A lock file that cannot be *deleted* at release (a leftover blocking handle)
is only a cleanup failure — the hold itself was exclusive — so there the
command's own exit code is kept. Both lanes warn on stderr. Avoid exiting
96–98 from your own wrapped command — those codes are reserved by this
contract, and a command exiting 98 is indistinguishable from a stolen lock.
One PowerShell-port caveat: a wrapped command whose *final statement* fails
without setting a native exit code (a failing cmdlet — non-terminating errors
never set `$LASTEXITCODE`) exits **1** with a stderr note, but a mid-command
cmdlet failure followed by a succeeding final statement is not detected
(exit 0) — the same blind spot as bash's last-command `$?`.
See
[`docs/git-commit-lock.md`](docs/git-commit-lock.md) for the `AGENT_LOCK_*` config
knobs and how staleness and stealing work.

## Tests

Three suites — bash unit, bash + PowerShell interop, and an end-to-end
integration run of concurrent real commits — cover the tool, and CI runs
them on Linux, macOS, and Windows. How to run them and what each covers:
[`docs/git-commit-lock.md#tests`](docs/git-commit-lock.md#tests).

## Licence

[MIT](LICENSE).

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
