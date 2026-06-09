<!-- docs/commit-lock.md | repo: ben/commit-lock (C:\code\commit-lock) | design/rationale for the commit-lock tool | operating rules live in dotfiles agents/210-using-git.md -->

# `commit-lock`: a mutex for committing from a shared working tree

Design reference for the commit lock. The agent operating rules live in the
dotfiles repo at `agents/210-using-git.md` ("Shared checkouts: the commit lock");
read that first. This file is the "why" and "how it works".

## Scope: lock only, git by hand

The lock is the **only** thing we automate. The git commands — what to stage,
what to commit — are run manually by the agent, under the lock. We deliberately
do **not** ship a commit wrapper: an earlier version did, and teaching it as
*the* way to commit led an agent to treat the wrapper's per-file scope as the
limit of the possible and escalate a one-line commit to the human. The lesson:
the lock is a shared invariant worth packaging; a commit is local git that
should stay flexible. Keep the automated surface minimal.

## The problem

Multiple agents (Claude, Codex, Gemini) often operate in **one** working tree:

- By design in some repos — several agents share a single checkout on `main`.
- **Unavoidably whenever an agent spawns sub-agents.** Sub-agents run in the
  parent's working directory; they do **not** get their own git worktree. So
  even a workflow that gives each *top-level* agent a worktree still has many
  sub-agents sharing each worktree.

A git working tree has exactly one index (`.git/index`, or
`.git/worktrees/<wt>/index`) and one `HEAD`. Concurrent commits therefore:

1. **Race** on `.git/index.lock` ("Unable to create '.../index.lock'"), and
   interleaved `git add`s can stage a half-written state.
2. Tempt **sweep-up** — `git add -A`/`commit -a` captures other agents'
   half-finished work. (Avoided by always naming your own paths, not by the
   lock.)

Worktrees solve this by giving each agent its own index — but sub-agents can't
have worktrees, so we need a lock inside the shared tree.

## How the lock works

`flock` is unavailable in our Cygwin/Git-Bash environment, so the lock is built
from primitives that are atomic on NTFS:

- **acquire** = `mkdir <lock>` — atomic create-or-fail.
- **steal** = `mv <lock> <grave>` — `rename(2)` is atomic, so exactly one
  concurrent stealer wins; the rest get `ENOENT` and re-race the `mkdir`.

**Staleness is judged by the lock directory's own mtime** (stamped atomically by
`mkdir`), via `stat -c %Y` with a `date -r` fallback. A lock older than
`AGENT_LOCK_STALE_SECS` (default **300s / 5 min**) is presumed crashed and may be
stolen, so one dead agent can't wedge the others. We key on the *dir* mtime, not
an `epoch` file inside it, on purpose: an acquirer that dies between `mkdir` and
writing its metadata — or a release whose `rm -rf` only partly completes (a real
intermittent on Windows when another process holds a handle in the dir) — leaves
an orphan with no readable epoch. Keying on a file would make that orphan
un-stealable and hang every waiter to the timeout. (Exactly the bug the
self-test caught 2026-05-30: 3 of 25 workers hung to the 420s cap.) The
`epoch`/`owner` files written inside the dir are for logging only.

**Release** deletes the dir; if `rm -rf` fails it renames the dir aside and
deletes that. Recovery triggers **only** on a non-zero `rm` — while the dir
exists no one else can `mkdir` it, so it is unambiguously ours. We must *not*
re-check after a successful `rm`: a successor may already have re-created the dir
and entered its own critical section, and renaming it aside would steal that live
lock (two holders → lost update — the second bug the self-test caught).

**Location.** The lock and its log default to the repo's git dir
(`git rev-parse --absolute-git-dir`), e.g. `<repo>/.git/commit.lock` and
`<repo>/.git/commit-lock.log`. Never tracked by git (no `.gitignore` needed in
any repo), and correctly scoped: every worktree has its own git dir, so
independent worktrees get independent locks, while all sub-agents sharing one
checkout resolve the same git dir and share one lock.

**One caveat on the mtime clock (added 2026-06-03).** A just-created lock dir can
transiently report the Windows FILETIME zero (1601-01-01) in the window between
creation and its first metadata write — a ~400-year bogus "age" that would
spuriously steal a *live, brand-new* lock and put two holders in the tree. Both
implementations therefore refuse to steal on any mtime below a sane floor
(2000-01-01), treating a sub-floor reading as "just created — wait", and
`commit-lock.ps1` additionally stamps the dir's mtime the instant it wins the
create. This race only became reachable once the PowerShell port (whose atomic
create is a temp-dir + rename, which leaves a longer unsettled-mtime window than
`mkdir`) began sharing the lock with the bash path; the interop self-test catches
it (~1-in-4 runs before the fix, 0 after).

## The PowerShell port (`commit-lock.ps1`)

Codex on Windows runs commands in **PowerShell**, where a bare `bash` resolves to
`C:\Windows\system32\bash.exe` — the **WSL** launcher. WSL's Linux git can't reach
the Windows SSH commit signer (no private key in WSL; the dotfiles agent-forward
only fires in *interactive* WSL shells, not Codex's `bash -c`), so a bash-wrapped
commit under Codex fails to sign (`No private key found … failed to write commit
object`). Claude is immune — it ships its own MINGW64 Git-Bash. So Codex commits
via `commit-lock.ps1` from PowerShell, where `git` is Git-for-Windows and signs.

The port is **wire-compatible** with `commit-lock.sh`, so a `.ps1` holder and a
`.sh` holder serialise against each other in one tree:

- **Same lock dir / log:** `git rev-parse --absolute-git-dir` prints the same
  forward-slash drive path (`C:/repo/.git`) under both MINGW git and Windows git,
  so both compute `…/.git/commit.lock` and contend on the same NTFS directory.
- **Same protocol:** atomic create-or-fail, dir-mtime staleness with the steal
  threshold, rename-aside steal, unique-token release check. Tokens are written
  BOM-free so each side reads the other's cleanly (only *inequality* matters for
  steal detection, so the formats needn't match).
- **PowerShell specifics that matter:** the atomic create is a temp-dir +
  `[IO.Directory]::Move` (because `New-Item -ItemType Directory` has a
  check-then-create TOCTOU and `[IO.Directory]::CreateDirectory` silently succeeds
  on an existing dir — neither is a mutex gate). The load-bearing token write and
  the release-time token read each retry briefly to ride out transient Windows
  sharing violations (a dropped token write would later look like a false theft).

Usage (Codex): `& ~/.local/bin/commit-lock.ps1 run "git add -- <paths>; if ($LASTEXITCODE -eq 0) { git commit -m '<msg>' }"`. Chain with
`if ($LASTEXITCODE -eq 0)` (not `&&`, not `exit`); exit code 2 = lock lost
mid-hold, redo. Verified end-to-end 2026-06-03: a commit through the port carries
a Good SSH signature.

## API

Source it (`source ~/.local/bin/commit-lock.sh`) for:

- `lock_acquire` — block until held (steal-if-stale); returns non-zero only on
  the `AGENT_LOCK_MAX_WAIT` timeout. Arms an EXIT/INT/TERM trap that releases.
- `lock_release` — release if held (idempotent).
- `lock_run <cmd...>` — acquire, run the command, always release, propagate its
  exit code. The `run` CLI subcommand is this:
  `commit-lock.sh run -- <cmd...>`.

Config knobs (env, mainly for tests): `AGENT_LOCK_DIR`, `AGENT_LOCK_STALE_SECS`,
`AGENT_LOCK_POLL_SECS`, `AGENT_LOCK_MAX_WAIT`, `AGENT_LOCK_LOG`.

## The golden rule: hold the lock only to commit

The lock must protect a *sub-second* critical section. Decide what to stage,
build any patch, and resolve failures **outside** it. If a commit fails under
the lock (e.g. a pre-commit hook rejects it), unstage your paths
(`git reset -- <paths>`, which never touches the working tree) and
`lock_release` **before** you investigate, then retry. Never acquire the lock
and then read, build, or ask the user.

This is enforced by a **fail-open lease, not a guarantee**. The dir mtime (the
staleness clock) is stamped once at `mkdir` and never refreshed, so a hold
longer than `AGENT_LOCK_STALE_SECS` can be stolen by a waiter mid-work — two
holders would then coexist. We accept that (no background heartbeat keeps the
tool a single synchronous script) and instead make it *loud and detectable*:
each acquire writes a unique token; release re-reads it and, if it no longer
matches, the lease was stolen → return 2 + WARNING rather than claim success.
So a robbed slow holder learns at release that its commit wasn't serialised and
must redo it. A slow but *uncontended* holder is fine — nothing moved its dir,
the token still matches, release succeeds. The defence is therefore: keep
commits fast (well under the window), and if you must run something slow under
the lock, raise `AGENT_LOCK_STALE_SECS` for that invocation.

Never `git stash` in a shared checkout — it rewrites the working tree on disk and
clobbers other agents' uncommitted edits.

## Committing: the manual recipes

Normal case — commit the paths you changed:

```sh
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git add -- path/a path/b && git commit -m "msg"'
```

Shared file (you own only part of it) — stage just your hunk, commit the index:

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch   # outside lock; trim to your hunk(s)
bash ~/.local/bin/commit-lock.sh run -- bash -c '
  git diff --cached --quiet || { echo "index not clean" >&2; exit 1; }
  git apply --cached /tmp/mine.patch && git commit -m "msg"'   # BARE commit
```

`git apply --cached` patches the **index relative to HEAD**, so it isolates your
change even when it shares a working-tree hunk with someone else's edit;
`git add -p` is the interactive equivalent. Commit with a **bare** `git commit`
(commits the index). Do **not** use `git commit -- <file>`: a pathspec switches
git to `--only` semantics, re-reading the *working tree* and pulling the other
party's WIP back in. (Verified: `git commit -- file` after `git apply --cached`
ignores the clean index and stages the whole working-tree file.)

## Files

Under `~/.local/bin/` (repo `C:\code\commit-lock\`):

| File | Role |
|------|------|
| `commit-lock.sh`             | the mutex (bash, used by Claude): source for `lock_acquire/lock_release/lock_run`, or `commit-lock.sh run -- <cmd>` |
| `commit-lock.ps1`            | wire-compatible PowerShell port (used by Codex on Windows — see below): `commit-lock.ps1 run "<pwsh cmd>"`, or dot-source for `Lock-Acquire`/`Lock-Release` |
| `commit-lock.test.sh`        | self-contained bash tests (throwaway temp dirs); exit 0 == all pass |
| `commit-lock.interop.test.sh`| cross-impl tests: pwsh + bash workers share one lock and serialise; run from MINGW/Git-Bash |

## Verifying on a new machine

```
bash ~/.local/bin/commit-lock.test.sh            # bash impl; "RESULT: N passed, 0 failed"
bash ~/.local/bin/commit-lock.interop.test.sh    # cross-impl (needs pwsh); "INTEROP RESULT: …"
```

`commit-lock.test.sh` covers mutual exclusion over 8×25 concurrent workers (clean
acquire/release path), stale-lock theft, the epoch-less-orphan regression,
refusal to steal a *live* lock, a robbed slow holder detecting the theft and
failing on release (plus the thief succeeding on its own fresh hold), an
uncontended slow holder *not* failing, exit-code propagation, and the git-dir
lock location.

`commit-lock.interop.test.sh` proves `.ps1` and `.sh` interlock: 8 bash + 8 pwsh
workers serialise on one lock with zero concurrent-holder violations and zero
spurious steals; a bash holder blocks a pwsh waiter and vice-versa (no wrongful
steal); and each side steals the other's genuinely stale lock. Run it from
MINGW/Git-Bash (NOT WSL) so both sides agree on the `C:/…` lock path.

Last verified 2026-06-03: bash suite **19 passed, 0 failed**; interop suite
**11/11, stable across 10 runs**. Note both suites spawn many short-lived
processes (and pwsh startup is slow), so on a loaded machine they can take several
minutes — allow a generous timeout rather than assuming a hang. A worker
occasionally failing to *launch* under heavy Cygwin fan-out is environmental, not
a lock failure; the interop test scores exclusion by violations/steals, not by
that count.
