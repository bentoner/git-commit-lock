# `git-commit-lock`: a mutex for committing from a shared working tree

Design reference for the commit lock — the "why" and the "how it works". The
suggested agent operating rules live in the README ("Suggested agent
instructions"); read that first.

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

## Scope: lock only, git by hand

The lock is the **only** thing we automate. The git commands — what to stage,
what to commit — are run manually by the agent, under the lock. We deliberately
do **not** ship a commit wrapper: teaching a wrapper as *the* way to commit
leads agents to treat the wrapper's scope as the limit of what is possible
(observed in practice). The lock is a shared invariant worth packaging; a
commit is local git that should stay flexible. Keep the automated surface
minimal.

## How the lock works

The lock is a **file** — by default `<gitdir>/commit.lock` — whose existence
means "someone is committing" and whose content names the holder. Acquiring,
stealing, and releasing it are built around three filesystem operations —
create-or-fail, rename, unlink — each atomic on local POSIX filesystems
and NTFS alike, so the bash implementation and the PowerShell port take the
*same* lock with identical semantics, and a `.sh` holder and a `.ps1` holder
in one tree serialise against each other.

It is deliberately **not** an OS lock — no `flock`, no kernel mutex, no
helper daemon (see [Why not
`flock`?](#why-not-flock-or-another-os-lock-primitive)). Instead it is a
**lease**: a lock older than the staleness window (default 5 minutes) is
presumed crashed and may be stolen, so one dead or wedged agent can't wedge
the rest, and a holder that loses the lease mid-hold finds out at release
(exit 98) rather than silently claiming success. The full mechanics —
acquire, steal, the never-steal guards, release, and the clock caveat — are
in [The protocol in detail](#the-protocol-in-detail).

## Why not `flock` (or another OS lock primitive)?

Kernel locks look like the obvious tool here — so why a hand-rolled
filesystem lease? Two reasons, either of which would have been decisive on
its own: kernel locks can't recover a wedged holder, and no kernel primitive
spans the runtimes that have to share this lock.

**Kernel locks can't recover a wedged holder.** Automatic release-on-death
is the kernel lock's great virtue (with caveats: Windows documents
post-mortem unlocking as asynchronous, and an `flock` lives on the open file
description, so an inherited descriptor in a child keeps it held). But there
is no supported way to take a kernel lock away from a process that is alive
and *stuck* — an agent hung on a credential prompt, a wedged hook, a dead
network mount — short of killing the holder. For unattended agent fleets,
hung-but-alive is at least as common as crashed, and a locking tool that lets
one wedged agent silently halt an overnight multi-agent run is doing more
harm than the race it prevents. The lease design recovers from both crash
and wedge within the stale window, at the documented cost of being
**fail-open** — a theft is detected (exit 98) rather than prevented. That
trade is sensible here because the failure being guarded against is mild:
two colliding committers almost always produce just a failed commit, or at
worst a mixed-up commit.

**No kernel primitive spans the runtimes.** The other hard requirement is
**one lock that both implementations can take natively**: bash running under
Git for Windows' MINGW64 environment, and PowerShell/.NET, contending on the
*same* lock in the same repo, with the bash side also portable to macOS and
Linux. No OS lock primitive survives that intersection:

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

So the only locking primitive every runtime here observes identically is the
**filesystem namespace** — atomic create and atomic rename — and that is what
the lock is built from. The trade-off is owned in [The protocol in
detail](#the-protocol-in-detail) below: staleness needs a clock heuristic,
release needs theft detection, and a few narrow check-then-act races remain
(detected, not silent — the implementation headers carry the full inventory).

The filesystem primitives carry their own assumption, stated here explicitly:
the repo must live on a **local filesystem with atomic create/rename and sane
mtimes** (NTFS, ext4, APFS, and kin). Repos on network or sync-backed storage
— NFS, SMB shares, Dropbox/OneDrive-synced directories — are outside the
design's guarantees.

## The protocol in detail

Both implementations follow the same protocol on the same wire format:

- **acquire** = create the lock **file** with an atomic create-or-fail open
  (bash: a `noclobber` redirect, i.e. `O_CREAT|O_EXCL`; .NET:
  `FileMode.CreateNew`), writing its content in the same open: line 1 is the
  holder's unique token (theft detection — it must start `tok.`, which is
  part of the wire format), line 2 an informational `pid=<pid> host=<host>`
  owner line for the logs. While the file exists, nobody else can create it,
  so an existing file is unambiguously the current holder's.
  - Creation and ownership metadata are one atomic-enough step: the token
    travels with the file, and a crash between create and write just leaves
    an *empty file with a valid mtime*, recovered by the normal staleness
    rule (a regression test covers it).
  - After winning, the acquirer reads the path back and must find its own
    token; anything else after the read-retry ladder (up to 8 read attempts
    with
    escalating 20→320 ms backoff, ~1.3 s total budget — the same schedule in
    both implementations, enough to ride out a sub-second transient such as
    an AV scanner's handle) — foreign, empty, gone — means it
    cannot prove it holds the path: it logs loudly and treats the lock as
    NOT acquired. It never "repairs" a failed read-back by rewriting the
    path: after a long suspension (sleep, stop-the-world) the file may
    legitimately be a successor's live lock, and an overwrite would corrupt
    it undetectably.
- **steal** = win the **claim**, then one atomic rename-over. To steal a
  stale lock, a waiter must first create the **claim file** — `<lock>.next`,
  same wire format, carrying a token generated fresh for that attempt — with
  the same atomic create-or-fail open, so concurrent stealers are
  serialised: exactly one holds the claim at a time, and the rest keep
  waiting. The claim *is* the next lock. Under the claim, the claimant
  re-verifies that the lock is still stale, re-checks its own claim (still
  its token, still young — a claimant suspended long enough that a waiter
  may have judged its claim abandoned must not proceed on it), touches the
  claim so the new lease starts ~now (rename preserves the source's mtime,
  so the installed lock's staleness clock *is* the claim's), re-verifies
  the lock once more immediately before the install, and then
  renames the claim **over** the lock: the dead lock is destroyed and the
  live one installed in a single `rename(2)`, with no instant at which the
  path is absent for a rival's create to re-race. Serialising stealers
  through the claim *prevents* the crash-recovery-under-contention race
  outright: were steals unserialized, a straggler whose stale judgement
  predates the recovery could displace the recovery winner's fresh lock
  (see [the golden rule](#the-golden-rule-hold-the-lock-only-to-commit)).

**Staleness is judged by the lock file's own mtime** (stamped by the creating
write). A lock older than `AGENT_LOCK_STALE_SECS` (default **300s / 5 min**)
is presumed crashed and may be stolen, so one dead agent can't wedge the
others.

**A claim is itself leased.** Claims are held for milliseconds, so a claim
older than `AGENT_LOCK_CLAIM_STALE_SECS` (default **60 s**) means the
claimant crashed: any waiter clears it (same mtime floor, same content-shape
test) and re-races the claim create. A crashed claimant therefore delays
only *steals*, and only by up to the claim window — acquiring a free lock
path is never blocked by a claim. The knobs relate: worst-case recovery is
a crashed holder *plus* a crashed claimant, so keep `AGENT_LOCK_MAX_WAIT`
above `AGENT_LOCK_STALE_SECS + AGENT_LOCK_CLAIM_STALE_SECS` (the defaults,
420 > 300 + 60, do; a startup warning fires when the relation is broken
while `MAX_WAIT` was left at its default — a caller who set the knobs
explicitly chose the relationship).

**The steal refuses anything that is not lock-shaped.** A directory at the
lock path (a config typo, or a directory lock left behind by an older
release), a symlink, a device, or a regular file whose content is neither
empty nor `tok.`-prefixed is **never** stolen or deleted: a loud one-time
config warning names the path, and waiters time out (97) until a human
removes it. The tool never runs `rm -rf` and never deletes anything it cannot
identify as a lock, so a typo'd `AGENT_LOCK_PATH` — pointing at `$HOME`, or
at a real user file with ordinary content — is harmless. The same never-steal
guards apply at the **claim path**, with independent per-path warn-once and
confirmation state; a refused object at `<lock>.next` blocks steals (never
normal acquisition) until a human removes it.

Two accepted residuals bound that guarantee, because the content test is exactly
"empty, or line 1 starts `tok.`": a stale **empty** user file is
indistinguishable from the crash orphan and IS stolen, and a stale user file
whose first line happens to start `tok.` passes the wire test and IS stolen
too — deliberately, since a fuller shape check would bind the wire format
harder for near-zero added protection (see ACCEPTED RESIDUALS in
`git-commit-lock.sh`).

(bash also refuses the *create* on a non-regular path up front: `noclobber`'s
exists⇒fail protection covers regular files only, and an open on an existing
FIFO would block before any timeout logic runs.)

One scoped exception: bash delivers this guarantee in full, but the
**PowerShell port running on POSIX** — an unsupported, CI-only
configuration — has no clean .NET type probe for FIFOs/devices/sockets, which
stat there as size 0 and take the empty-orphan steal lane (consumed by the
steal's rename-over, capping damage at the one misconfigured inode); at the
claim path the same inode stats empty and, once aged, is cleared like a
crashed claim. That residual is documented in `git-commit-lock.ps1`'s
PORT-SPECIFIC NOTES; on Windows the ps1 guard is complete.

**Aborted steals self-resolve.** A claim attempt can abort for several
reasons — the "stale" holder turns out to be live-slow and releases (the
claimant then must *not* install onto the absent path: that lane belongs to
the normal create race), the lock comes back fresh, the claim is judged
contested — and the protocol fences every abort with two rules. Claim
deletion is always **token-checked**: a claim is unlinked only after reading
back this attempt's own token, so a rival's live claim is never touched. And
because a rival's rename can install *our* claim file as the lock while we
are anywhere past the claim create (a waiter clears a claim it judged
abandoned, another claims in its place, a delayed rename lands), every exit
that does not end in a successful rename performs, as its final act, one
**ownership-discovery read** of the lock path: finding this attempt's token
there means our claim was installed — we hold the lock after all. Tokens are
generated fresh **per attempt** (never reused within an acquire), which is
what makes that read conclusive: each token only ever names one file. The
few exits that have to leave a claim behind unverified (an unreadable claim;
an unlink blocked by a foreign handle) feed an in-process **leaked-token
memory** that keeps the check running — on every later poll, and once more
at release, where a leaked token found installed at the lock means our real
hold was displaced: release cleans up the leaked file (best-effort) and
reports the loud 98. A trappable exit (EXIT/INT/TERM; the port's `finally` equivalent)
deletes an in-flight claim on the way out. The result is structural: no
process inside an acquire/hold/release arc can leave an *unowned* lock
behind. The exhaustive lane-by-lane inventory — and the bounded residuals
outside that arc — live in the implementation headers, like the rest of the
residual-race inventory.

One deployment note: **upgrade both implementations together.** Older
releases stole with an unserialized move-aside instead of the claim, so the
prevention property holds only when every party in a tree runs the claim
protocol: a mixed-version tree degrades prevention to detection (exit 98),
and an old-style stealer can leave behind moved-aside lock files (`.dead.*`)
that current versions don't clean.

**Release** = compare the file's token to ours, then one unlink. A non-empty
foreign token, or a gone file, means the lease was stolen → fail loudly with
98 (acquire's read-back positively verified our token at the path, which is
what grounds treating "gone" as theft). A file that still reads *empty* after
the retry ladder is NOT definitive theft evidence — it can be a successor
mid-create after a boundary steal (a steal that fires just as the stale
window expires, racing the holder's release), a window the probes show is
real — so ownership is unverifiable: the file is left in place (it may be
a nascent live lock; a true orphan ages into the staleness backstop) and
release fails distinctly. On a token match the unlink is retried briefly: on
Windows a foreign no-delete-share handle (an AV scanner, a naive reader) can
block it,
and — probed — the same handle class blocks a stealer's rename identically,
so the path cannot be stolen-and-recreated while the delete keeps failing. If
it keeps failing the lock is a **leftover**: release warns and returns 1, and
waiters recover only once the stale window elapses AND the blocking handle
closes.

**Location.** The lock and its log default to the repo's git dir
(`git rev-parse --absolute-git-dir`), e.g. `<repo>/.git/commit.lock` and
`<repo>/.git/git-commit-lock.log`. Never tracked by git (no `.gitignore` needed in
any repo), and correctly scoped: every worktree has its own git dir, so
independent worktrees get independent locks, while all sub-agents sharing one
checkout resolve the same git dir and share one lock.

**One caveat on the mtime clock.** A just-created lock file can transiently
report the Windows FILETIME zero (1601-01-01) to an observer in the window
around creation — a ~400-year bogus "age" that would spuriously steal a
*live, brand-new* lock and put two holders in the tree. Probing on our NTFS
test machine shows plain file creation (both bash- and pwsh-created)
produces this transient at roughly 0.04–0.5% of readings. Both
implementations therefore refuse to steal on any mtime below a sane floor
(2000-01-01), treating a
sub-floor reading as "just created — wait"; it settles in milliseconds. The
same floor governs the claim file's ageout: a sub-floor claim mtime reads as
"just created", never "ancient — clear".

## The PowerShell port (`git-commit-lock.ps1`)

Some agents (Codex on Windows, for example) run their commands in
**PowerShell**, where — depending on PATH order and what's installed — a bare
`bash` can resolve to `C:\Windows\system32\bash.exe`, the **WSL** launcher,
rather than a MINGW bash. On such machines, if your commits are signed by a
Windows-side SSH agent, WSL's Linux git can't reach the signer (no private
key in WSL; SSH-agent forwarding into WSL typically only fires in
*interactive* shells, not an agent's `bash -c`), so a bash-wrapped commit
fails to sign (`No private key found … failed to write commit object`).
Agents that ship their own MINGW64 Git-Bash, such as Claude Code, are
unaffected. The port lets PowerShell-native agents take the same lock from
PowerShell, where `git` resolves to Git-for-Windows and signs.

The port is **wire-compatible** with `git-commit-lock.sh`, so a `.ps1` holder and a
`.sh` holder serialise against each other in one tree:

- **Same lock file / log:** `git rev-parse --absolute-git-dir` prints the same
  forward-slash drive path (`C:/repo/.git`) under both MINGW git and Windows git,
  so both compute `…/.git/commit.lock` and contend on the same NTFS file.
- **Same protocol and wire format:** atomic create-or-fail, the same
  token+owner file content (`tok.`-prefixed line 1, written BOM-free so each
  side reads the other's cleanly), file-mtime staleness with the steal
  threshold and floor, the claim-serialized steal on the shared `<lock>.next`
  claim file — each side parses, ages, and clears the other's claims — with
  the same never-steal guards, and the same release classification
  (foreign/gone ⇒ 98, empty-but-present ⇒ unverifiable, delete-blocked ⇒
  leftover).
- **PowerShell specifics that matter:** the atomic create is one
  `[IO.File]::Open(..., CreateNew, ...)`, and the token+owner content is
  written and flushed **through that creation handle**, so the write can
  never land on a successor's file whatever happens to the path meanwhile.
  All reads of the lock file use an explicit `FileStream` with
  `ReadWrite|Delete` sharing (not `ReadAllText`, whose `FileShare.Read`
  handle would — probed — block another party's steal-rename or
  release-unlink for the duration). The release-time and acquire-read-back
  token reads retry on the shared escalating-backoff schedule (see the
  acquire section above) to ride out transient Windows sharing violations
  and the create→write content gap — bash runs the identical schedule, so
  the two implementations return the same verdict for the same transient.
- **The steal's rename-over differs by engine.** PowerShell 7 / .NET Core
  uses the atomic-overwrite `[IO.File]::Move($src, $dst, $true)` overload —
  probed: no absent-path window, like bash's `mv`. Windows PowerShell 5.1 /
  .NET Framework has no such overload (and `File.Replace` is deliberately
  never used: it throws on a read-only destination and has
  partial-failure states when called without a backup file), so the 5.1
  steal completes as unlink-the-ghost, then a fail-if-exists `Move` of the
  claim. The transient absent window between those two steps is safe *under
  the claim*: a rival's create landing in it simply wins the lock and our
  `Move` fails-if-exists — a fairness loss (the claimant did the recovery
  work and lost the lock), never a clobber. One Windows residual on the
  pwsh 7 lane: .NET renames with classic Windows semantics, not
  `FILE_RENAME_POSIX_SEMANTICS` (which Cygwin/MSYS `mv` uses, so bash is
  immune), so the rename-over fails while *any* rival handle is open on the
  destination, even one granting full sharing. The failure leaves both
  files intact and routes into the damped blocked-steal lane — a deferral
  of the steal by a poll interval, never an atomicity break — and steals
  only target crashed locks, so the cost is recovery latency under reader
  contention.

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
  if the lock was stolen mid-hold (the file is gone or carries a foreign
  token); 2 if the lock file is still present but reads **empty** after the
  retry ladder (ownership unverifiable — an empty file can be a successor
  mid-create after a boundary steal, so it is neither proof of theft nor
  safe to delete; `run` maps this to 1 only when the command itself
  succeeded, keeping a failing command's own code; the PowerShell port
  returns the same verdicts for the same on-disk states); 1 if the file
  could not be deleted after retries (a **leftover** — recovered once the
  stale window elapses and the blocking handle closes).
- `lock_run <cmd...>` — acquire, run the command, always release, propagate its
  exit code. The `run` CLI subcommand is this:
  `git-commit-lock.sh run -- <cmd...>`.

The sourced API is what to reach for when a single wrapped command is awkward
— say you want to review the staged diff before committing:

```sh
source ~/.local/bin/git-commit-lock.sh
lock_acquire || exit 1
git add -- path/you/changed
git diff --cached        # check the staged commit is what you intend
git commit -m "your message"
lock_release
```

(In PowerShell, dot-source `git-commit-lock.ps1` and use `Lock-Acquire` /
`Lock-Release` in a `try`/`finally`.) A quick check like that staged-diff
review is fine under the lock; just keep the hold brief and prepare anything
slow outside it — see [the golden
rule](#the-golden-rule-hold-the-lock-only-to-commit). `lock_acquire`'s exit
trap releases the lock on normal exit and on a handled INT/TERM; if the
process is killed outright (SIGKILL, a crash, power loss), the trap can't
run and the stale timeout recovers the lock instead.

The `run` CLI's exit code is the wrapped command's, except for three reserved
high codes: **96** usage error, **97** lock acquisition timed out (the command
was never run), **98** lock stolen mid-hold (the command ran but was NOT
serialised — redo it under the lock). The full table with guidance lives in
the README's Usage section. The PowerShell port keeps the same contract with
one port-specific lane: "the command's own exit code" is `$LASTEXITCODE`
where the command set one, but a *failing cmdlet* never does (non-terminating
errors don't set it), so a command whose **final statement** fails without a
native exit code maps to exit **1** with a stderr note — never into the
reserved 96–98 range. Only the final statement is consulted; a mid-command
cmdlet failure followed by a succeeding final statement exits 0, the same
blind spot as bash's last-command `$?` (the full verdict table lives at
`Invoke-WithLock` in `git-commit-lock.ps1`).

Config knobs (env, mainly for tests):

| Knob | Default |
|------|---------|
| `AGENT_LOCK_PATH`       | `<gitdir>/commit.lock` (the steal's claim file lives beside it at `<lock>.next`) |
| `AGENT_LOCK_STALE_SECS` | `300` (5 min) |
| `AGENT_LOCK_CLAIM_STALE_SECS` | `60` (1 min — claim ageout; claims are held for milliseconds) |
| `AGENT_LOCK_POLL_SECS`  | `2` |
| `AGENT_LOCK_MAX_WAIT`   | `420` (7 min — keep it above `STALE + CLAIM_STALE` so a crashed holder *and* a crashed claimant can both be recovered before waiters give up; a warning fires when it is not, gated on `MAX_WAIT` being left at its default) |
| `AGENT_LOCK_LOG`        | `<gitdir>/git-commit-lock.log` |

## The golden rule: hold the lock only to commit

Keep the critical section small: decide what to stage, build any patch, and
resolve failures **outside** the lock. A normal stage+commit holds the lock
for seconds, and that is the healthy pattern; the actual contract is just to
stay comfortably inside the staleness window (default 5 minutes). If a commit
fails under the lock (e.g. a pre-commit hook rejects it), unstage your paths
(`git reset -- <paths>`, which never touches the working tree) and
`lock_release` **before** you investigate, then retry. Never start anything
open-ended while holding the lock — an investigation, a build, or (worst,
because it's unbounded) a wait on a human.

The rule is backed by a **fail-open lease, not enforcement**. The lock file's
mtime (the staleness clock) is stamped once at creation and never refreshed,
so a hold longer than `AGENT_LOCK_STALE_SECS` can be stolen by a waiter
mid-work — two holders would then coexist. We accept that (no background
heartbeat keeps the tool a single synchronous script) and instead make it
*loud and detectable*: each acquire writes a unique token as the file's
content; release re-reads it and, if it no longer matches, the lease was
stolen → fail with a WARNING (exit code 98 from `run`) rather than claim
success.
So a robbed slow holder learns at release that its commit wasn't serialised and
must redo it. A slow but *uncontended* holder is fine — nothing moved its file,
the token still matches, release succeeds. The defence is therefore: keep
commits fast (well under the window), and if you must run something slow under
the lock, raise `AGENT_LOCK_STALE_SECS` for that invocation.

Crash recovery under contention is the scenario that puts an *innocent*
holder most at risk: after a holder dies, every waiter judges the dead lock
stale off the same mtime in the same poll window. Unserialized steals would
let a straggler — whose stale judgement predates the recovery — displace the
waiter that had already won it; and a steal that even briefly vacated the
lock path would invite the whole herd's creates to stampede the freed name
after every crash. The claim protocol closes both: stealers must first win
the claim file, the claimant re-verifies that the lock is *still* stale
while holding the claim, and the install is one atomic rename-over — the
path stays occupied throughout recovery, the recovering waiter keeps the
lock it recovered, and a straggler finds either a rival's claim (it waits)
or a fresh lock (it aborts). (One engine caveat: the
Windows PowerShell 5.1 lane installs by unlink-then-move rather than one
atomic rename, so a rival's create can win the recovered path inside that
window and the claimant backs off cleanly — the fairness loss described in
[the PowerShell port](#the-powershell-port-git-commit-lockps1), never a
clobber.) The narrow residual
interleavings that remain (e.g. a live-slow holder releasing in the
instant between the claimant's final re-verify and its rename, with a
waiter's create landing in that same instant — the implementation headers
carry the full inventory) surface at worst as the documented exit-98 redo —
some are caught even earlier, as a benign not-acquired retry at the
read-back — never a silent loss. One bounded residual is deliberately accepted rather
than prevented: a claimant dying *untrappably* (SIGKILL, power loss) in the
milliseconds between claiming and renaming orphans its claim — normally it
just ages out at the claim window, but a suspended rival's rename can
install it as an *unowned* lock that stalls waiters for up to one stale
window before the lease recovers it. That is the same class of cost, at far
lower probability, as the crashed holder's stall the lease already accepts;
nobody falsely believes they hold, so nothing corrupts.

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

## Security and trust assumptions

The lock is **advisory**: it serialises *cooperating* agents and defends
against nothing. The lock file is an ordinary file with no special
permissions, so any process running as the same user can delete or
overwrite it at will — the protocol *detects* such interference where it
can (the token checks; exit 98) but cannot prevent it. The threat model is
honest agents racing each other; against an actively hostile local process
no file-based mutex helps.

A **hostile repository can choose where the lock lives**. The lock and log
paths come from `git rev-parse --absolute-git-dir`, and git honours a
`.git` *file* containing a `gitdir:` pointer — so a crafted repo can point
the git dir at any path the user can write, and the tool will operate
there. The damage is capped by what the tool ever does on disk: it creates
the lock file (and the lock path's parent directories), appends to — and,
past a 1 MB cap, restarts — its log file, and creates and removes its small
set of lock-protocol files at its own names beside the lock, gated by the
shape and age checks above. Deletion is never recursive, and everything
happens with the invoking user's own permissions. Still, treat a repo you
wouldn't enable hooks from with the same caution here: don't run the lock
(or agents) inside it.

**Log content is attacker-influenceable — and never holds secrets.**
Whoever can write the lock file controls its owner line, which flows
unsanitised into log lines such as `STALE (… holder=…)`; under a redirected
git dir the lock *path* echoed in warnings is attacker-chosen too. That is
one-line spoofing of log text, with no execution — but don't build
automation that trusts what the log *says*. Conversely the tool itself
writes only its token (`tok.<pid>.…`), a `pid=<pid> host=<host>` owner
line, and protocol events (timestamps, pids, paths, ages) — no credentials
or repo content ever appear in the lock file or the log.

## Files

In the repository (`install.sh` installs the **two scripts** — not the test
suites — into `~/.local/bin/`, as symlinks, or as copies where symlinks are
unavailable):

| File | Role |
|------|------|
| `git-commit-lock.sh`                  | the mutex (bash; the authoritative implementation): source for `lock_acquire/lock_release/lock_run`, or `git-commit-lock.sh run -- <cmd>` |
| `git-commit-lock.ps1`                 | wire-compatible PowerShell port (see [The PowerShell port](#the-powershell-port-git-commit-lockps1) above): `git-commit-lock.ps1 run "<pwsh cmd>"`, or dot-source for `Lock-Acquire`/`Lock-Release` |
| `git-commit-lock.test.sh`             | self-contained bash tests (throwaway temp dirs); exit 0 == all pass |
| `git-commit-lock.interop.test.sh`     | cross-impl tests: pwsh + bash workers share one lock and serialise; run from MINGW/Git-Bash |
| `git-commit-lock.integration.test.sh` | end-to-end: many concurrent workers make real commits into one shared repo; the history is audited for the tool's guarantees |

## Tests

Run the suites from a clone of this repository (they are not installed to
`~/.local/bin`):

```sh
bash git-commit-lock.test.sh             # bash implementation
bash git-commit-lock.interop.test.sh     # bash + PowerShell interop (skips if pwsh is absent)
bash git-commit-lock.integration.test.sh # end-to-end: concurrent real commits into one repo (pwsh half skips if absent)
```

Each suite prints a result summary line and exits 0 when everything passes.
All three use throwaway temp dirs and never touch the repo you launch them
from. The heavy fan-out tests run at a REDUCED width by default, so a routine
run doesn't lag a shared development machine; each suite prints a
`fan-out mode:` line at the start and tags its result line with the mode, so
check those say `FULL` when you ran `GCL_TEST_FULL=1` for the full-strength
canary (CI does).

`git-commit-lock.test.sh` covers the bash implementation: mutual exclusion
under many concurrent workers (clean acquire/release path), stale-lock theft,
crash recovery under contention (several waiters racing one dead lock —
claim-serialized: exactly one steal, zero displacements, zero spurious 98s,
and no move-aside file ever created), claim contention (many concurrent
stealers, one claim winner), crashed-claimant and empty-claim orphans ageing
out at the
claim window, the claim-path wrong-type guards with independent per-path
warn-once state, a live-slow holder surviving a claimant's re-verify (abort,
no steal), the overaged-own-claim contested abort, the discovery-position
matrix (a rival installs the victim's claim as the lock at every abort
position — the victim must discover it holds, never leaving an unowned
lock), the leaked-claim lanes (the leaked-token memory discovering an
installed leak, crashed-leaver forensics, and release-time cleanup of a leak
installed over a held lock), TERM mid-claim (the trap deletes the claim
token-checked; a foreign claim survives it), the per-attempt-token
regression (an abandoned own-token lock never aliases a later discovery or
release), trap parity for steal-acquired holds, the delayed-claim fresh
lease, the sub-floor claim-mtime guard, immediate claim cleanup on a blocked
steal (no ageout penalty), a static check that the claim touch is
non-creating, the empty-file-orphan regression (a crash between create and
content write), refusal to steal a *live* lock, the sub-floor
(FILETIME-zero) mtime floor guard, the never-steal guards (a directory, a
symlink, a FIFO, or non-lock-shaped content at the lock path is refused with
the config warning), a robbed slow holder detecting the theft and failing on
release (plus the thief succeeding on its own fresh hold), an uncontended
slow holder *not* failing, exit-code propagation, release on TERM and on
exit-while-holding (signal re-raised, caller's traps and exit code
preserved), sourced-API hygiene (no strict-mode leak, reentrancy refusal,
idempotent release), numeric-knob validation (including the claim-staleness
knob and the `MAX_WAIT` relation warning), refusal to run outside a git repo
without `AGENT_LOCK_PATH`, the release classification (empty-but-present
unverifiable; gone ⇒ 98), the wire format (token line, owner line), the
default git-dir location of the lock and log, and per-worktree lock scoping.

`git-commit-lock.interop.test.sh` proves `.ps1` and `.sh` interlock: bash and
pwsh workers serialise on one lock with zero concurrent-holder violations and
zero spurious steals; a bash holder blocks a pwsh waiter and vice-versa (no
wrongful steal); each side steals the other's genuinely stale lock; mixed
waiters racing one crashed lock recover it claim-serialized (one steal, zero
displacements, zero spurious 98s); a bash claimant and a ps1 claimant race
one ghost, parsing each other's claim files (one winner, wire parity); each
side clears the other's aged claim and respects a young one; a static check
pins the port to never use `File.Replace`; both impls
agree on the release classification (truncated ⇒ unverifiable, gone ⇒ 98);
the ps1 never-steal guards get their own parity tests; the `run` verdicts for
PowerShell-native failures are pinned (a failing final cmdlet ⇒ 1, native
codes verbatim, the final-statement limitation as contract); the
blocked-release and blocked-steal lanes are exercised deterministically via a
no-delete-share handle (Windows-only by nature — POSIX open handles never
block unlink/rename, so those two skip with a note on non-Windows platforms);
and a Windows PowerShell 5.1 smoke lane re-runs the exit-code contract, a
contended acquire, and a steal — which on that engine exercises the
unlink+Move ladder by construction (see [The PowerShell
port](#the-powershell-port-git-commit-lockps1)) — on the in-box engine
(skipped with a note where `powershell` is absent, i.e. the POSIX legs). Run
it from MINGW/Git-Bash (NOT WSL) so both sides agree on the `C:/…` lock path.

`git-commit-lock.integration.test.sh` drives the real use case end-to-end:
many concurrent workers stage and commit into one shared git repository under
the lock, exactly as the README instructs agents to, and the resulting history
is audited for the guarantees this document claims — every commit lands,
history stays linear, no commit sweeps up another worker's file, no
`index.lock` races, no stolen leases, and a clean tree at the end.

The same three suites run in CI on Linux, macOS, and Windows
(`.github/workflows/tests.yml`), at full fan-out strength, alongside a
shellcheck + PSScriptAnalyzer lint job. The POSIX legs exercise the
PowerShell implementation purely as cross-implementation protocol
verification — the port is *supported* on Windows only (see [The PowerShell
port](#the-powershell-port-git-commit-lockps1)), but having two independent
implementations contend on one lock probes the protocol from angles a
single implementation never would.

The suites spawn many short-lived processes (and pwsh startup is slow), so on
a loaded machine they can take several minutes — allow a generous timeout
rather than assuming a hang. A worker occasionally failing to *launch* under
heavy process fan-out is environmental, not a lock failure — but only the
interop suite's exclusion test tolerates it (scoring by violations/steals,
with a minimum-acquired floor so a collapsed fan-out cannot pass vacuously);
the integration suite is deliberately strict per worker (every worker must
launch and commit), and the unit suite's counts are exact.

For debugging, all three suites copy their logs and work dirs to
`$GCL_TEST_PRESERVE_DIR` when it is set, and keep the work dir on disk on any
failure.
