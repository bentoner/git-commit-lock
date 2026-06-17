# git-commit-lock: guarantees and scope (the normative contract)

**Status: normative.** This document states *what the tool guarantees*, *under
what conditions* (the operating envelope), and *what is explicitly out of
scope*. It is the contract a user or a CI gate can point at: a behavior listed
under [Guarantees](#2-guarantees) is a property the code must uphold and the
tests defend; a behavior under [Out of scope](#5-out-of-scope-not-guaranteed) is
one the tool deliberately does not promise.

**How this relates to the other two docs.** This is the *contract*;
[`failure-modes.md`](failure-modes.md) is the *analysis* behind it (per-mode
current behavior, tier classification, and the scope decisions that produced
this contract); [`git-commit-lock.md`](git-commit-lock.md) is the *design
reference* (why the protocol is shaped this way and how it works). Where they
appear to disagree, the **code and tests are authoritative**, then this contract,
then the analysis, then the design narrative. Each guarantee below cites its
witnessing test(s) and the failure-modes section that justifies it; the
[Verification map](#7-verification-map) collects those pointers.

This contract makes **no new claims** about behavior — it is a re-statement of
the decisions recorded in `failure-modes.md` §4 as commitments. It does not
re-derive the protocol (see the design doc) or re-argue the tiers (see the
analysis).

---

## 1. The operating envelope

Every guarantee in §2 holds **within this envelope**. Outside it, the tool
degrades as described in §4 (best-effort) or §5 (out of scope) — in most cases
*detectably and without corruption*, but the strict guarantees are not promised.
The envelope is not a disclaimer bolted on; it is the precise set of assumptions
the filesystem-lease design rests on.

**E1 — Single host, single time source.** All contenders share one working tree,
hence one machine, hence one clock. Staleness is `age = now − mtime` arithmetic
(`git-commit-lock.sh:928,1409`); it assumes the mtime and the comparing process's
`now` come from the *same* clock. Single-host use satisfies this. A *local* clock
jump remains correctness-safe (it degrades to the detected-98 lane, never a
silent double-commit; see G-S1 and `failure-modes.md` §E2). Multi-host use over a
shared FS does not satisfy it and is out of scope (§5, OOS-2).

**E2 — Local filesystem with atomic create/rename and sane mtimes.** The protocol
is built from three filesystem operations — atomic create-or-fail (`O_EXCL` /
`FileMode.CreateNew`), atomic rename-over, and unlink — each atomic on local
POSIX filesystems and NTFS (ext4, APFS, NTFS, and kin). (The one exception is the
Windows PowerShell 5.1 steal, which lacks the atomic 3-arg move and uses a
claim-guarded unlink-then-move — a fairness loss, never a clobber; see BE-5.)
Network and sync-backed storage (NFS, SMB/CIFS, 9p, Dropbox/OneDrive) weaken
exactly these operations and are out of scope (§5, OOS-1;
`git-commit-lock.md:122-126`).

**E3 — Cooperative wrapper unwind.** The theft-detection guarantee (G-S1) fires
when the lock-holding shell *reaches its release path* — on normal return, on a
handled INT/TERM, or on a plain `exit` (all of which unwind). It is **not**
triggered by a termination or replacement that skips the unwind: an external
SIGKILL, an `exec` that replaces the lock-holding shell itself, or PowerShell
`[Environment]::Exit()`. (An `exec` nested in a child — the ordinary
`run -- bash -c 'exec …'` — does *not* skip release.) See §5, OOS-5 for the
precise boundary.

**E4 — Commits fast relative to the staleness window (for *strict* exclusion).**
The lease is fail-open: a hold older than `AGENT_LOCK_STALE_SECS` (default 300s)
can be stolen mid-work. *Strict* mutual exclusion (G-S3) is therefore guaranteed
only for holds that complete within the staleness window. A hold that overruns it
is still *safe* — a displaced holder is detected (G-S1) — but two processes can
briefly both believe they hold the lock. Keep commits well inside the window, or
raise `AGENT_LOCK_STALE_SECS` for a deliberately slow hold (the golden rule,
`git-commit-lock.md:433-458`).

**E5 — Matching protocol version on all parties.** Prevention of the
crash-recovery-under-contention race (G-S3's no-displacement property) holds only
when every contender runs the claim protocol. A mixed-version tree degrades
prevention to detection and is out of scope (§5, OOS-3).

**E6 — Supported platforms.** `git-commit-lock.sh` (bash) is supported on Linux,
macOS, and Windows under Git-for-Windows' MINGW bash. `git-commit-lock.ps1`
(PowerShell) is supported on **Windows only**. Running the `.ps1` port on POSIX is
a CI-only cross-implementation protocol check, not a supported configuration (§5,
OOS-4; `README.md:91-95`).

**E7 — Cooperating, non-hostile agents.** The lock is advisory: it serializes
*cooperating* agents. It detects interference where it can (token checks; exit 98)
but cannot prevent a process running as the same user from deleting or
overwriting the lock file. The threat model is honest agents racing each other,
not an actively hostile local process (§5, OOS-6;
`git-commit-lock.md:520-528`).

---

## 2. Guarantees

Each guarantee holds **within the envelope (§1)**. The defaults named are knobs
(`AGENT_LOCK_*`); the guarantee is in terms of the configured value, not a fixed
number of seconds.

### 2A. Safety (unconditional within the envelope)

These are correctness properties. If one can break inside the envelope, that is a
bug.

- **G-S1 — No silent lost update.** A holder whose lease is taken from it never
  reports a serialized critical section that wasn't. On release, a **definitive**
  theft (the lock file is gone, or carries a foreign token) returns **98** with a
  loud WARNING rather than success (`git-commit-lock.sh:1607-1688`;
  `git-commit-lock.ps1:1717-1837`); a state the release cannot disambiguate (the
  file is present but reads **empty** after the retry ladder — possibly a successor
  mid-create after a boundary steal) returns the distinct **unverifiable** code
  (`lock_release` 2; `run` maps it to 1 when the command itself succeeded, else
  keeps the command's code) — still **never** a silent success. *Condition:* the
  wrapper unwinds cooperatively (E3). *Witness:* unit Test 4b (98 + WARNING), Test
  16 (unverifiable lane), interop Test 8 (98 both directions) (`U:387-417`,
  `I:460-492`). *Basis:* `failure-modes.md` §1, §B5.

- **G-S2 — No corruption and no false hold.** An acquirer that cannot prove its
  own token is at the lock path (after the read-back retry ladder) treats the lock
  as **not** acquired and logs loudly; it never "repairs" a failed read-back by
  rewriting the path (`git-commit-lock.sh:1352-1361`). Every path that cannot
  establish a fact fails toward "wait", never toward "steal" or "hold". This
  extends to resource-exhaustion lanes: a create that fails (ENOSPC, FD/inode
  exhaustion, an unwritable lock dir) **never produces a false hold or corruption**
  — it falls through to wait/97 (an empty orphan ages into the recovery lane). The
  guarantee is *no false hold*, not a uniformly clean 97: a torn write shorter than
  `tok.` is a non-lock-shaped residual, never stolen, that needs manual removal
  (`failure-modes.md` §F1 — an accepted residual). *Witness:* the read-back-failure lanes —
  create-path Test 32, steal-path Test 32b (`U:1760-1855`); resource lanes —
  coverage planned (Bucket 2 / `failure-modes.md` §4.5). *Basis:* §1, §A1, §F.

- **G-S3 — Strict mutual exclusion within the staleness window, with no
  displacement during crash recovery.** Within `AGENT_LOCK_STALE_SECS` no steal
  occurs at all, so at most one process holds the lock. When a holder dies and a
  herd of waiters recovers the one stale lock, the **claim protocol** admits
  exactly one stealer and the recovering waiter keeps the lock it recovered — a
  straggler whose stale judgement predates the recovery cannot displace it
  (`git-commit-lock.sh:1070-1218`). At most one process is ever the *legitimate*
  holder. (On the supported Windows PowerShell 5.1 unlink-then-move lane the
  recovering waiter can *lose* the recovered path to a rival's create in the
  transient absent window — a fairness loss, never a clobber; see BE-5.)
  *Condition:* holds complete within the window (E4); a stable clock (E1) — a local
  clock jump preserves *no silent loss* (G-S1) but can break *strict exclusion* by
  making a live lock look stale (a premature, but detected, steal); and matching
  version (E5). *Witness:* unit Tests 1/2b/20, interop Tests 1/6/16/16b, integration suite
  (`U:166-195,212-346,1095-1128`; `I:227-261,341-386,884-1088`). *Basis:*
  §A1/§A2/§A3.

- **G-S4 — Never destroys a non-lock-shaped object.** A directory, symlink, FIFO,
  device, socket, or a regular file whose line 1 is neither empty nor `tok.`-
  prefixed is **never** stolen or deleted, at either the lock path or the claim
  path (`git-commit-lock.sh:1322-1327,1411-1444,1458-1487,1518-1570`). The
  never-steal *safety* is unconditional; the *warning* is best-effort — it normally
  fires once and names the object, but an **actively-rewritten** user file may never
  age into the content guard and then times out at 97 *without* the warning
  (`git-commit-lock.sh:308`). Deletion is
  never recursive; the tool only ever removes its own named lock-protocol files.
  *Two accepted residuals* bound this and are documented, not bugs: a stale
  *empty* user file, and a stale file whose line 1 happens to start `tok.`, are
  stolen (`git-commit-lock.sh:298-311`). *Witness:* unit Tests 17/17d/18/22
  (`U:818-892,894-1032,1034-1076,1156-1262`). *Basis:* §D3/§D4/§G1. *Scoped
  exception:* ps1-on-POSIX has no .NET type probe for FIFO/device/socket (§5,
  OOS-4).

- **G-S5 — Truthful exit codes.** The three reserved high codes from `run` are
  exact: **96** = usage error (command **not** run), **97** = acquisition timed
  out (command **not** run), **98** = lock stolen mid-hold (command **ran but was
  not serialized** — redo it) (`git-commit-lock.sh:392-415`). A `run` exit of the
  command's own code (including 0) means the command was serialized — *subject to
  the one carve-out in OOS-5* (a non-unwinding exit returning 0 while displaced).
  *Two stated assumptions* keep the high-code contract exact: the wrapped command
  must not itself exit 96/97/98 (such an exit is indistinguishable from a tool
  verdict, `git-commit-lock.sh:392`), and an **unverifiable** release maps a
  *successful* command to **1** (G-S1), so 0 is never reported over an unverifiable
  hold. *Witness:* Test 7 (96), Test 8 (97), Test 4b (98), Test 5 (propagation),
  Test 16 (unverifiable→1), interop `run` verdict tests. *Basis:* §1, §H4.

### 2B. Recovery (within the FS/clock/tooling envelope)

These hold given a readable clock (E1) and lock-shaped state; latency is
best-effort (§4).

- **G-R1 — Lock-shaped orphans are reclaimed.** A crashed holder's stale lock, an
  orphaned or empty claim, and an empty crash-orphan (a crash between create and
  content write) all eventually become stealable and are recovered, bounded by
  `STALE` (+ `CLAIM_STALE` if a claimant also crashed) plus poll cadence
  (`git-commit-lock.sh:1408-1446,1228-1267`). This does **not** extend to *foreign*
  objects (G-S4) — those wait for an operator. *Witness:* unit Tests 2/3/21
  (`U:197-210,348-361,1130-1154`). *Basis:* §B1/§C1/§C2/§C3.

- **G-R2 — One stuck agent cannot wedge the fleet.** Because the lock is a lease
  and the claim is itself leased, a hung-but-alive holder or claimant is recovered
  within its window; the fleet does not deadlock behind it. *Witness:* the stale-
  steal and crashed-claimant lanes above. *Basis:* §1, `git-commit-lock.md:60-82`
  (the explicit reason for a lease over a kernel lock).

- **G-R3 — No busy-spin; bounded wait.** A waiter on a genuinely squatted or
  delete-blocked lock gives up at `MAX_WAIT` and never busy-spins past it; the
  failed-steal lane logs in a damped, bounded way (`I:746-817`). *Witness:* interop
  Test 14b. *Basis:* §K(4).

- **G-R4 — No process leaves an *unowned* lock behind.** Per-attempt tokens make
  the ownership-discovery read conclusive, so no process inside an
  acquire/hold/release arc can install a lock nobody owns and walk away: it either
  discovers it holds, or the lock is recovered by staleness, and in no case is a
  steal-installed lock mistaken for owned by the wrong process
  (`git-commit-lock.sh:138-157` + the leaked-token memory). The one bounded
  residual — an untrappably-killed claimant's claim installed as an unowned lock —
  stalls waiters ≤ one stale window with **no false success** (accepted; §B3).
  *Witness:* unit Tests 31/35/36 (`U:1549-1758,2013-2164`). *Basis:* §C4.

### 2C. Interoperation

- **G-I1 — bash and PowerShell take the same lock.** One on-disk wire format
  (`tok.`-prefixed line 1, owner line 2), one read-retry ladder
  (8 attempts, 20/40/80/160/320/320/320 ms — byte-identical between ports), one
  set of release verdicts, one config grammar. A `.sh` holder and a `.ps1` holder
  in one tree serialize against each other and steal each other's genuinely stale
  locks. *Condition:* Windows for the supported ps1 config (E6). *Witness:* the
  interop suite throughout (`I:*`). *Basis:* §I1.

---

## 3. Failure semantics (the shape of every degradation)

When the tool cannot uphold a property it fails in one of these bounded,
documented ways — **never** silently:

- **Detect, don't pretend** — a displaced holder returns 98 + WARNING (G-S1).
- **Wait, don't guess** — an unprovable state routes to poll/wait → 97, never to
  a steal or a hold (G-S2).
- **Refuse, don't destroy** — a non-lock-shaped object is left in place (and
  normally warned about — the warning is best-effort, see G-S4); waiters reach 97.
- **Announce, don't hide** — a broken staleness clock (unreadable mtime) warns
  loudly once and disables stealing (fails safe; §4, BE-2).

**Within the operating envelope**, the only place a *correctness* degradation can
be silent — a non-unwinding exit returning 0 while displaced — is carved out
explicitly in OOS-5. Two silences fall *outside* that scope and are disclosed
separately: a degradation **outside** the envelope (a network/sync FS silently
losing exclusion, OOS-1), and a **non-correctness** loss (a swallowed log write,
BE-4). Logging is best-effort by design; correctness is not.

---

## 4. Best-effort (within the envelope, not a hard guarantee)

These hold under normal conditions and degrade *gracefully and detectably* under
pathological scheduling or host-health failures. **Correctness (§2) is preserved
throughout; only liveness/latency degrades.** This tier is the reference Bucket 4
scopes the suite's wall-clock test assertions against (the strict/envelope test
split, `failure-modes.md` §4.1 / D-c).

- **BE-1 — Wall-clock latency bounds are in poll-count, not seconds.** Recovery
  latency (≈ `STALE` + poll cadence), the `MAX_WAIT` timeout, and the ~1.26s
  read-retry ladder all *stretch* under CPU oversubscription or a slow FS while
  still completing. The guarantee is "bounded by the configured knobs in
  poll-count," not "exactly N seconds." Tests asserting a specific wall-clock or
  poll-count number (Test 21's ≤20s, Test 22a's warning timing, Test 29's ≥2-CLAIM
  count) assert an *envelope* bound, not a correctness bound, and may be relaxed or
  gated to a defined load level (`GCL_ENVELOPE_TIER=relax`) without any product
  change. *Basis:* `failure-modes.md` §K, §4.1.

- **BE-2 — Diagnostic warnings are best-effort.** The wrong-type config warning
  and the claim-path warning rely on poll headroom that an oversubscribed runner
  can starve; the guarantee is that the *condition is handled safely*, not that a
  specific warning fires within a specific time. *Basis:* §K(2), §D3.

- **BE-3 — Recovery presumes a readable clock; an unreadable mtime fails safe.**
  If the lock's mtime cannot be read at all, both ports retry three times, then
  warn loudly once per process and treat the lock as **not** stale (the mtime floor
  fails closed to "fresh"): no premature steal, no corruption — but recovery of a
  genuinely crashed holder is *disabled* and waiters block to `MAX_WAIT` (97).
  Safety is preserved; recovery is lost and announced. *Coverage planned* (Bucket
  2 / §4.5). *Basis:* §E3.

- **BE-4 — Logging is best-effort and never blocks the lock.** Every log write
  ends `|| true`; a failed or unwritable log write is swallowed and the lock works
  unaffected (the log self-truncates past ~1 MB). *Coverage planned* (Bucket 2 /
  §4.5, the F2/J1 test). *Basis:* §F2/§J1.

- **BE-5 — The PowerShell 5.1 steal is claim-guarded, not atomic.** Windows
  PowerShell 5.1 lacks the 3-arg `File.Move` overload, so its steal is
  unlink-then-move with a transient absent window. Under the claim this is a
  *fairness loss* (a rival's create can win the recovered path; the claimant backs
  off cleanly), **never a clobber**. *Basis:* §D1, `git-commit-lock.md:471-476`.

---

## 5. Out of scope (not guaranteed)

The tool deliberately does not promise the following. Where it can, it still fails
*safely and detectably*; the point of listing them is that the strict guarantees
of §2 are **not** claimed here.

- **OOS-1 — Network / shared / sync-backed filesystems.** NFS, SMB/CIFS, 9p,
  Dropbox/OneDrive. These weaken the atomic create/rename the protocol rests on, so
  exclusion may silently not hold. Documented boundary only — surfaced in the
  README; **no** FS-type probe is built (decision: `failure-modes.md` §4 item 3).
  *Basis:* §E1.

- **OOS-2 — Multi-host use / clock skew across hosts.** Rides on OOS-1 (only arises
  on a shared FS). A *local* clock jump on the single host is **in scope and
  correctness-safe** (degrades to the detected-98 lane). *Basis:* §E2.

- **OOS-3 — Mixed-version trees.** If contenders run different protocol versions,
  the no-displacement prevention (G-S3) degrades to detection (98), and old-style
  stealers can leave `.dead.*` litter. Never silent, but the prevention property is
  not guaranteed. Deployment rule: **upgrade both implementations together**
  (`git-commit-lock.md:251-256`; to be surfaced in the README too — Bucket 3).
  *Basis:* §I2.

- **OOS-4 — PowerShell port on POSIX.** Supported on Windows only; on POSIX it runs
  solely as a cross-implementation protocol check. Its one residual there
  (FIFO/device/socket stat as empty and take the empty-orphan lane, capping damage
  at the one misconfigured inode) is accepted and documented. *Basis:* §D3.

- **OOS-5 — A non-unwinding exit returning 0 while displaced (the no-silent-loss
  boundary).** G-S1's detection requires the *lock-holding shell* to reach release
  (E3). If a *displaced* holder is terminated or replaced **without unwinding** —
  external SIGKILL, an `exec` that replaces the **lock-holding shell itself**, or
  PowerShell `[Environment]::Exit()` — *and* the resulting process exits **0**, the
  caller can see success with no 98. The `exec` case is **narrower than it looks**
  (verified empirically): `lock_run` runs the wrapped command vector in the wrapper
  shell (`git-commit-lock.sh:1733`), so the bypass needs the exec to run in *that*
  shell — a **sourced** caller doing `lock_acquire; exec …` in its own shell, or
  the contrived `run -- exec …` where the wrapped command *is* an exec. An exec
  **nested in a child** — the normal `run -- bash -c 'exec …'` — does **not**
  bypass: the child is replaced, the wrapper waits and releases normally. A **plain
  `exit` is safe** (it unwinds). What keeps the whole class narrow: an external
  SIGKILL yields a non-zero wait status (POSIX `128+9`), so a caller checking exit
  codes does not see success; the hole needs a process that *deliberately* replaces
  or hard-exits the lock-holding shell **and** returns 0 **while displaced**. The
  *next* holder still recovers via staleness; only the abruptly-exiting one is
  unwarned. No code change closes this without the handle-based ops the design
  rejected. *Witness (boundary exercised indirectly):* interop Test 5 (`I:308-334`,
  ps1 `[Environment]::Exit()`); the bash `exec` lane is a coverage gap
  (`steering-coverage.md` A4). *Basis:* §H4.

- **OOS-6 — Adversarial / hostile local processes.** The lock is advisory. Against
  a process actively trying to break it (deleting/overwriting the lock file, or a
  hostile repo redirecting the git dir), the tool *detects* interference where it
  can but does not prevent it; damage from a redirected git dir is bounded to the
  tool's own named files with non-recursive deletion. *Basis:*
  `git-commit-lock.md:520-551`.

- **OOS-7 — Non-issues, explicitly.** A case-insensitive FS path collision (the
  lock and claim paths never collide under case folding; two case-differing
  configured paths resolving to one file is *correct* shared-lock behavior) and
  memory exhaustion (the scripts allocate trivially). No action. *Basis:* §D5/§F5.

### Things deliberately NOT built (and why)

The design considered and rejected each of these; they are not roadmap items
(`failure-modes.md` §4 "Things explicitly NOT to do"):

- A **background heartbeat** to refresh the lease — would make the tool more than a
  single synchronous script; the fail-open-but-detectable lease is the deliberate
  alternative.
- A **two-rename compare-and-swap** to prevent the B3 residual — reintroduces crash
  litter and a sweep, for a failure that is already bounded and false-success-free.
- **`File.Replace`** in the ps1 port — throws on a read-only destination and has
  partial-failure states (pinned out by interop Test 16d).
- **Supporting network/shared filesystems** — correctness rests on local-FS atomic
  create/rename; this is a boundary to document, not to engineer around.

---

## 6. Staying inside the envelope (operating rules)

- **Hold the lock only to commit.** Decide what to stage, build any patch, and
  resolve failures *outside* the lock; a normal stage+commit holds it for seconds
  (the golden rule, `git-commit-lock.md:433-458`). This keeps holds inside the
  staleness window (E4) so G-S3 applies.
- **For a deliberately slow hold, raise `AGENT_LOCK_STALE_SECS`** for that
  invocation rather than risking a fail-open steal.
- **Keep the lock on a local filesystem** (the default `<gitdir>/commit.lock`
  almost always is) so E2 holds.
- **Upgrade both implementations together** (E5) so G-S3's prevention holds.
- **Never `git stash` in a shared checkout** — it rewrites the working tree and
  clobbers other agents' edits (orthogonal to the lock, but part of operating in a
  shared tree).

---

## 7. Verification map

Each guarantee → its witnessing test(s) and the failure-modes section. `U` =
`tests/git-commit-lock.test.sh`, `I` = `tests/git-commit-lock.interop.test.sh`,
`integ` = `tests/git-commit-lock.integration.test.sh`. "Coverage planned" marks a
guarantee that is currently reasoned-correct-but-untested and slated for a
fault-injection test under Bucket 2 (`failure-modes.md` §4.5, Ben's override to
add coverage); the *guarantee* is made now, the *test* lands in Phase 3.

| Guarantee | Witness | failure-modes § |
|---|---|---|
| G-S1 no silent lost update | U Test 4b + Test 16 (unverifiable lane); I Test 8 (both dirs) | §1, §B5 |
| G-S2 no corruption / no false hold | U Tests 32/32b (read-back failure); **resource lanes: coverage planned** (F1/F3/F4) | §1, §A1, §F |
| G-S3 strict exclusion in window + no displacement | U Tests 1/2b/20; I Tests 1/6/16/16b; integ | §A1/§A2/§A3 |
| G-S4 never destroys non-lock-shaped | U Tests 17/17d/18/22 | §D3/§D4/§G1 |
| G-S5 truthful exit codes | U Tests 7/8/4b/5/16; I run-verdict tests | §1, §H4 |
| G-R1 lock-shaped orphans reclaimed | U Tests 2/3/21 | §B1/§C1/§C2/§C3 |
| G-R2 one stuck agent can't wedge | stale-steal + crashed-claimant lanes | §1 |
| G-R3 no busy-spin; bounded wait | I Test 14b | §K(4) |
| G-R4 no unowned lock left behind | U Tests 31/35/36 | §C4 |
| G-I1 bash⇄pwsh same lock | I suite throughout | §I1 |
| BE-3 unreadable mtime fails safe | **coverage planned** (E3) | §E3 |
| BE-4 logging best-effort | **coverage planned** (F2/J1) | §F2/§J1 |

The "coverage planned" rows are exactly the lanes Phase 1c (the steering-coverage
audit) and Bucket 2 (the new fault-injection tests) exist to close.
