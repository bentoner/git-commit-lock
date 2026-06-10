# `git-commit-lock`: a mutex for committing from a shared working tree

Design reference for the commit lock. The suggested agent operating rules live
in the README ("Suggested agent instructions"); read that first. This file is
the "why" and "how it works".

## Scope: lock only, git by hand

The lock is the **only** thing we automate. The git commands — what to stage,
what to commit — are run manually by the agent, under the lock. We deliberately
do **not** ship a commit wrapper: an earlier version did, and teaching it as
*the* way to commit led an agent to treat the wrapper's per-file scope as the
limit of the possible and escalate a one-line commit to the human. The lesson:
the lock is a shared invariant worth packaging; a commit is local git that
should stay flexible. Keep the automated surface minimal.

## The problem

Multiple agents (e.g. Claude, Codex, Gemini) often operate in **one** working
tree:

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

`flock(1)` is not reliably available here — Git for Windows ships none, and a
Cygwin/MSYS2-installed one is invisible to .NET anyway (see [Why not
`flock`?](#why-not-flock-or-another-os-lock-primitive) for the full story) —
so the lock is built from primitives that are atomic on NTFS:

- **acquire** = `mkdir <lock>` — atomic create-or-fail.
- **steal** = `mv <lock> <grave>` — `rename(2)` is atomic, so exactly one
  concurrent stealer wins; the rest get `ENOENT` and re-race the `mkdir`.

**Staleness is judged by the lock directory's own mtime** (stamped atomically
by `mkdir`). A lock older than `AGENT_LOCK_STALE_SECS` (default **300s /
5 min**) is presumed crashed and may be stolen, so one dead agent can't wedge
the others. We key on the *dir* mtime, not an `epoch` file inside it, on
purpose: an acquirer that dies between `mkdir` and writing its metadata — or a
release whose `rm -rf` only partly completes (a real intermittent on Windows
when another process holds a handle in the dir) — leaves an orphan with no
readable epoch. Keying on a file would make that orphan un-stealable and hang
every waiter to the timeout (exactly the bug an early self-test run caught,
with workers wedged to the wait cap; the suite now has a regression test for
it). The `epoch`/`owner` files written inside the dir are for logging only.

**Release** deletes the dir; if `rm -rf` fails it renames the dir aside and
deletes that. Recovery triggers **only** on a non-zero `rm` — while the dir
exists no one else can `mkdir` it, so it is unambiguously ours. We must *not*
re-check after a successful `rm`: a successor may already have re-created the dir
and entered its own critical section, and renaming it aside would steal that live
lock (two holders → lost update — the second bug the self-test caught).

**Location.** The lock and its log default to the repo's git dir
(`git rev-parse --absolute-git-dir`), e.g. `<repo>/.git/commit.lock` and
`<repo>/.git/git-commit-lock.log`. Never tracked by git (no `.gitignore` needed in
any repo), and correctly scoped: every worktree has its own git dir, so
independent worktrees get independent locks, while all sub-agents sharing one
checkout resolve the same git dir and share one lock.

**One caveat on the mtime clock.** A just-created lock dir can
transiently report the Windows FILETIME zero (1601-01-01) in the window between
creation and its first metadata write — a ~400-year bogus "age" that would
spuriously steal a *live, brand-new* lock and put two holders in the tree. Both
implementations therefore refuse to steal on any mtime below a sane floor
(2000-01-01), treating a sub-floor reading as "just created — wait", and
`git-commit-lock.ps1` additionally stamps the dir's mtime the instant it wins the
create. This race only became reachable once the PowerShell port (whose atomic
create is a temp-dir + rename, which leaves a longer unsettled-mtime window than
`mkdir`) began sharing the lock with the bash path; the interop self-test catches
it (~1-in-4 runs before the fix, 0 after).

## Why not `flock` (or another OS lock primitive)?

Kernel locks look like the obvious tool here — so why a hand-rolled
filesystem lease? Because the hard requirement is **one lock that both
implementations can take natively**: bash running under Git for Windows'
MINGW64 environment, and PowerShell/.NET, contending on the *same* lock in the
same repo, with the bash side also portable to macOS and Linux. No OS lock
primitive survives that intersection:

- **Availability.** Git for Windows deliberately excludes util-linux from its
  payload, so its bash has no `flock(1)` at all (MSYS2 proper offers one via
  `pacman -S util-linux`, but Git for Windows users don't have pacman). macOS
  has the `flock(2)` syscall but ships no `flock(1)` utility either — it's a
  util-linux program.
- **Interop.** Even where a Cygwin-family `flock` exists, Cygwin implements
  POSIX advisory locks (`flock`/`fcntl`/`lockf`) in its own emulation layer —
  not via `LockFileEx` — so by default they are visible only to other
  Cygwin-runtime processes. .NET has no `flock` equivalent; on Windows its
  locking is share modes fixed at open time (`FileShare.None` etc.) and
  byte-range locks via `FileStream.Lock`, both kernel-enforced. The two worlds
  never contend on one lock: a Cygwin `flock` holder is invisible to a
  PowerShell opener, and a PowerShell share-mode lock isn't something bash can
  *take*, only collide with. (Cygwin ≥ 1.7.19 has a per-descriptor opt-in,
  `fcntl(F_LCK_MANDATORY)`, that does map to Windows locking — but nothing a
  shell script holds uses it, and such locks don't survive fork/exec.) Git for
  Windows does ship a perl whose `flock()` "works", but it is the same MSYS
  emulation — invisible to .NET — so a perl helper buys no cross-runtime
  exclusion.
- **A compiled helper could do it** — a small binary holding a Windows named
  mutex or `LockFileEx` lock on one side and `flock` on the other, with the
  kernel releasing the lock automatically when the holder dies. We rejected
  it deliberately: it turns two dependency-free scripts into an installed
  binary with command-wrapping semantics, which is a different (and heavier)
  project than "copy these scripts anywhere agents run".
- **And kernel locks can't recover a wedged holder.** Automatic
  release-on-death is the kernel lock's great virtue (with caveats: Windows
  documents post-mortem unlocking as asynchronous, and an `flock` lives on
  the open file description, so an inherited descriptor in a child keeps it
  held). But there is no supported way to take a kernel lock away from a
  process that is alive and *stuck* — an agent hung on a credential prompt, a
  wedged hook, a dead network mount — short of killing it. For unattended
  agent fleets, hung-but-alive is at least as common as crashed. The lease
  design recovers from both within the stale window, at the documented cost
  of being fail-open — a theft is detected (exit 98) rather than prevented.

So the only locking primitive every runtime here observes identically is the
**filesystem namespace** — atomic create and atomic rename — and that is what
the lock is built from. The trade-off is owned in the sections above:
staleness needs a clock heuristic, release needs theft detection, and two
narrow check-then-act races remain (detected, not silent).

The filesystem primitives carry their own assumption, stated here explicitly:
the repo must live on a **local filesystem with atomic create/rename and sane
mtimes** (NTFS, ext4, APFS, and kin). Repos on network or sync-backed storage
— NFS, SMB shares, Dropbox/OneDrive-synced directories — are outside the
design's guarantees.

## The PowerShell port (`git-commit-lock.ps1`)

Some agents (Codex on Windows, for example) run their commands in
**PowerShell**, where a bare `bash` resolves to `C:\Windows\system32\bash.exe`
— the **WSL** launcher. If your commits are signed by a Windows-side SSH agent,
WSL's Linux git can't reach the signer (no private key in WSL; SSH-agent
forwarding into WSL typically only fires in *interactive* shells, not an
agent's `bash -c`), so a bash-wrapped commit fails to sign (`No private key
found … failed to write commit object`). Agents that ship their own MINGW64
Git-Bash, such as Claude Code, are unaffected. The port lets PowerShell-native
agents take the same lock from PowerShell, where `git` resolves to
Git-for-Windows and signs.

The port is **wire-compatible** with `git-commit-lock.sh`, so a `.ps1` holder and a
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

Usage:

```powershell
& ~/.local/bin/git-commit-lock.ps1 run "git add -- <paths>; if (`$LASTEXITCODE -eq 0) { git commit -m '<msg>' }"
```

Chain with `if ($LASTEXITCODE -eq 0)` (not `&&`, not `exit`) — and note the
backtick before `$LASTEXITCODE` in the double-quoted command string, which
defers the interpolation until the command runs under the lock. Exit
code 98 = lock lost mid-hold, redo.

## API

Source it (`source ~/.local/bin/git-commit-lock.sh`) for:

- `lock_acquire` — block until held (steal-if-stale); returns 97 on the
  `AGENT_LOCK_MAX_WAIT` timeout (and 1 on API misuse, e.g. a reentrant
  acquire). Arms an EXIT/INT/TERM trap that releases.
- `lock_release` — release if held (idempotent); returns 98, with a warning,
  if the lock was stolen mid-hold; 2 if the token was unreadable at release
  with the lock dir still present (ownership unverifiable — `run` maps this
  to 1); 1 if the dir could not be removed (the stale window recovers it).
- `lock_run <cmd...>` — acquire, run the command, always release, propagate its
  exit code. The `run` CLI subcommand is this:
  `git-commit-lock.sh run -- <cmd...>`.

The `run` CLI's exit code is the wrapped command's, except for three reserved
high codes: **96** usage error, **97** lock acquisition timed out (the command
was never run), **98** lock stolen mid-hold (the command ran but was NOT
serialised — redo it under the lock). The full table with guidance lives in
the README's Usage section.

Config knobs (env, mainly for tests):

| Knob | Default |
|------|---------|
| `AGENT_LOCK_DIR`        | `<gitdir>/commit.lock` |
| `AGENT_LOCK_STALE_SECS` | `300` (5 min) |
| `AGENT_LOCK_POLL_SECS`  | `2` |
| `AGENT_LOCK_MAX_WAIT`   | `420` (7 min — kept above the stale window so a waiter can steal before giving up) |
| `AGENT_LOCK_LOG`        | `<gitdir>/git-commit-lock.log` |

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
matches, the lease was stolen → fail with a WARNING (exit code 98 from `run`)
rather than claim success.
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
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
  git add -- path/a path/b && git commit -m "msg"'
```

Shared file (you own only part of it) — stage just your hunk, commit the index:

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch   # outside lock; trim to your hunk(s)
bash ~/.local/bin/git-commit-lock.sh run -- bash -c '
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

In the repository (`install.sh` symlinks the **two scripts** — not the test
suites — into `~/.local/bin/`):

| File | Role |
|------|------|
| `git-commit-lock.sh`                  | the mutex (bash; the authoritative implementation): source for `lock_acquire/lock_release/lock_run`, or `git-commit-lock.sh run -- <cmd>` |
| `git-commit-lock.ps1`                 | wire-compatible PowerShell port (see [The PowerShell port](#the-powershell-port-git-commit-lockps1) above): `git-commit-lock.ps1 run "<pwsh cmd>"`, or dot-source for `Lock-Acquire`/`Lock-Release` |
| `git-commit-lock.test.sh`             | self-contained bash tests (throwaway temp dirs); exit 0 == all pass |
| `git-commit-lock.interop.test.sh`     | cross-impl tests: pwsh + bash workers share one lock and serialise; run from MINGW/Git-Bash |
| `git-commit-lock.integration.test.sh` | end-to-end: many concurrent workers make real commits into one shared repo; the history is audited for the tool's guarantees |

## Verifying on a new machine

From a clone of this repository (the suites are not installed to
`~/.local/bin`):

```sh
bash git-commit-lock.test.sh             # bash implementation
bash git-commit-lock.interop.test.sh     # bash + PowerShell interop (skips if pwsh is absent)
bash git-commit-lock.integration.test.sh # end-to-end: concurrent real commits into one repo (pwsh half skips if absent)
```

Each suite prints a result summary line and exits 0 when everything passes.

`git-commit-lock.test.sh` covers the bash implementation: mutual exclusion
under many concurrent workers (clean acquire/release path), stale-lock theft,
the epoch-less-orphan regression, refusal to steal a *live* lock, a robbed
slow holder detecting the theft and failing on release (plus the thief
succeeding on its own fresh hold), an uncontended slow holder *not* failing,
exit-code propagation, the default git-dir location of the lock and log, and
per-worktree lock scoping.

`git-commit-lock.interop.test.sh` proves `.ps1` and `.sh` interlock: bash and
pwsh workers serialise on one lock with zero concurrent-holder violations and
zero spurious steals; a bash holder blocks a pwsh waiter and vice-versa (no
wrongful steal); and each side steals the other's genuinely stale lock. Run it
from MINGW/Git-Bash (NOT WSL) so both sides agree on the `C:/…` lock path.

`git-commit-lock.integration.test.sh` drives the real use case end-to-end:
many concurrent workers stage and commit into one shared git repository under
the lock, exactly as the README instructs agents to, and the resulting history
is audited for the guarantees this document claims — every commit lands,
history stays linear, no commit sweeps up another worker's file, no
`index.lock` races, no stolen leases, and a clean tree at the end.

The suites spawn many short-lived processes (and pwsh startup is slow), so on
a loaded machine they can take several minutes — allow a generous timeout
rather than assuming a hang. A worker occasionally failing to *launch* under
heavy process fan-out is environmental, not a lock failure; the suites score
exclusion by violations/steals, not by launch counts.
