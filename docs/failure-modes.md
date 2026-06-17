# git-commit-lock: failure-mode map and scope decisions

**Status:** decision-support document. For each failure mode it states the
tool's *current* behavior (grounded in the product code and tests), classifies
it into one of three robustness tiers, and recommends whether it should be an
in-scope guarantee. The owner uses this to deliberately decide, per mode, "yes,
we guarantee this" or "no, out of scope."

**Sources of truth, in order:** the product code
(`git-commit-lock.sh`, `git-commit-lock.ps1`) and the test suites
(`tests/git-commit-lock.test.sh`, `tests/git-commit-lock.interop.test.sh`,
`tests/git-commit-lock.integration.test.sh`). Every claim below cites
`file:line`. The narrative docs (`README.md`, `docs/git-commit-lock.md`) and
the implementation header comments are corroborating, not authoritative — where
this document relies on a header comment it has verified the comment against the
code. (Cited line numbers are against the tree at commit `c762899`; treat them
as anchors, not exact addresses, if the files move.)

A note on epistemics: the bash file's header (`git-commit-lock.sh:1-426`) is
itself an exhaustive design narrative and the ps1 header
(`git-commit-lock.ps1:41-177`) mirrors it. They are unusually trustworthy as
documentation *because* the tests pin the behaviors they describe. This document
does not re-derive the protocol; it re-classifies it for a scope decision and
flags the boundaries the headers state but a reader might skip.

---

## 1. The core guarantee (what must hold under ANY conditions)

**No silent lost update — given cooperative wrapper unwind.** The absolute safety
property is that the tool never reports a *serialized* critical section that
wasn't: a holder whose lease was taken from it learns so — `lock_release` returns
**98** and logs a loud WARNING — rather than exiting success
(`git-commit-lock.sh:1607-1688`; `git-commit-lock.ps1:1717-1837`). The two
reserved failure codes mean the wrapped command was provably *not* run (96 usage,
97 timeout) or provably *not serialized* (98) (`git-commit-lock.sh:392-415`).

Two honest qualifications make this a precise property rather than a slogan, and
both matter for the scope decision:

- **It is a lease, not a kernel lock** (`docs/git-commit-lock.md:60-126` explains
  why no OS primitive spans bash-on-MINGW and PowerShell/.NET). **Strict mutual
  exclusion holds only *within* the staleness window** (default 300s): a hold that
  overruns it *can* be stolen mid-work — "fail-open" — so two processes can
  briefly *both* believe they hold the lock. That overlap is accepted by design
  and made *detectable* (the displaced holder's 98 at release), not prevented
  (`git-commit-lock.sh:213-227`). At most one process is ever the *legitimate*
  holder; a displaced believer finds out at release. So "mutual exclusion" is a
  Tier-1 guarantee **within the envelope (commits faster than STALE)**, not an
  unconditional one.
- **Detection requires the wrapper to actually reach release.** The 98 path fires
  on normal return and on trapped signals. It does **not** fire if the held process
  is terminated or *replaced* without unwinding — an external SIGKILL, a bash
  `exec` in the wrapped command (which replaces the holding shell, so neither
  `lock_release` nor the EXIT trap runs), or PowerShell `[Environment]::Exit()`
  (bypasses `Lock-Release`, the `finally`, and the `PowerShell.Exiting` backstop,
  `git-commit-lock.ps1:221-245`). A *plain* `exit` is safe — it unwinds. A
  non-unwinding exit returning 0 *while displaced* can report success without the
  98 (see **§H4**). The *next* holder still recovers via staleness, but the
  abruptly-exiting one is not warned. Hence the precise statement: **no silent lost
  update, provided the wrapper unwinds cooperatively.**

Liveness (eventual recovery) and bounded stalls are best-effort within an
operating envelope (Tier 2), not absolute — and "recovery" means lock-shaped
orphans get reclaimed, **not** that every bad state self-heals (a foreign object
at the path is deliberately never auto-removed; see the tier split).

The integration suite is the end-to-end witness for this guarantee on the real
use case: many workers committing into one repo, audited for "every commit
lands, history linear, no sweep-up, no `index.lock` races, no stolen leases,
clean tree" (`tests/git-commit-lock.integration.test.sh:10-12, 226-283`).

### The three tiers used throughout

1. **Correctness guarantee** — must hold under *any* conditions (load, slow FS,
   adversarial scheduling). Two kinds, and the distinction matters:
   - **Safety (unconditional):** no corruption, and **no silent lost update** —
     the displaced holder detects the loss (98) *provided its wrapper reaches
     release* (§1's hard-kill/`Exit()` caveat). Strict **mutual exclusion holds
     within the staleness window**; beyond it the lease is
     fail-open-but-detectable.
   - **Recovery (for lock-shaped stale state, under the supported FS/clock/tooling
     envelope):** a crashed holder's stale lock, an orphaned claim, and an empty
     crash-orphan are eventually reclaimed. This does **not** extend to *foreign*
     objects at the path — a directory, a real user file, or non-`tok.` junk
     content are deliberately *never* auto-removed; they wait at 97 for an
     operator. "Eventual recovery" means lock-shaped orphans self-clear, not that
     every bad state self-heals.
   If a *safety* property can break, it is a bug; a *recovery* property failing
   outside its envelope (e.g. a foreign object, an unreadable clock) is a
   classified Tier-2/3 degradation, not a Tier-1 violation.
2. **Best-effort within a stated envelope** — holds under normal/expected
   conditions, degrades gracefully (and *detectably*) under pathological ones.
   Everything wall-clock-bounded lives here, because wall-clock bounds depend on
   scheduling: timeouts, recovery latency, the diagnostic warnings that depend
   on timing. Correctness is preserved; only liveness/latency degrades.
3. **Out of scope** — explicitly not handled; the operating envelope excludes
   it. Damage, if any, is bounded and documented.

---

## 2. Summary table

Legend — **Tier:** 1 correctness / 2 best-effort-in-envelope / 3 out-of-scope.
**Tested:** ✓ deterministic test · ~ load/timing-sensitive or partial · ○
robust-by-code-but-unverified · S static/grep check · (plat) platform-gated.

| # | Failure mode | Current behavior | Tier | Tested | Recommendation |
|---|---|---|---|---|---|
| A1 | Clean high contention (N workers, no crashes) | Serialized; no lost update | 1 | ✓ U:166-195, I:227-261/341-386, integ | **In scope.** Keep. |
| A2 | Thundering herd recovering one dead lock | Claim serializes; exactly one steal, zero displacement | 1 | ✓ U:212-346, I:884-1015 | **In scope.** Keep. |
| A3 | Many concurrent stealers on one ghost | One O_EXCL claim winner | 1 | ✓ U:1095-1128, I:1017-1088 | **In scope.** Keep. |
| B1 | Holder dies (crash/SIGKILL/power) mid-hold | Lease ages out; stolen after STALE | 1 (recovery) / 2 (latency) | ✓ U:197-210/348-361 | **In scope** (recovery). Latency = Tier 2. |
| B2 | Holder dies mid-CLAIM (trappable: INT/TERM) | Trap deletes claim, token-checked; discovery read | 1 | ✓ U:1857-1928, I:1151-1244 | **In scope.** Keep. |
| B3 | Holder dies mid-claim (untrappable: SIGKILL) | Claim ages out ≤ CLAIM_STALE; rival rename can install unowned lock, recovered ≤ STALE | 2 | ✓ U:1648-1677 (forensics) | **Accept** (residual 5). Bounded, no false success. |
| B4 | Slow but UNCONTENDED holder overruns STALE | Keeps its lock (nothing moved it) | 1 | ✓ U:419-429, I:494-499 | **In scope.** Keep. |
| B5 | Slow CONTENDED holder overruns STALE | Stolen; robbed holder detects at release → 98 | 1 (detection) | ✓ U:387-417, I:460-492 | **In scope.** This *is* fail-open-but-detectable. |
| C1 | Orphaned/stale lock | mtime-stale → stolen via claim | 1 | ✓ U:197-210 | **In scope.** Keep. |
| C2 | Empty lock (crash between create+write) | Empty + stale → stealable | 1 | ✓ U:348-361 | **In scope.** Keep. |
| C3 | Crashed-claimant / empty claim orphan | Ages out ≤ CLAIM_STALE; cleared | 1 (recovery) / 2 (latency) | ✓ U:1130-1154 | **In scope.** Keep. |
| C4 | Leaked claim (unverifiable unlink) | Leaked-token memory keeps ownership discoverable | 1 | ✓ U:1549-1758, U:2013-2164 | **In scope.** Keep. |
| D1 | Atomic rename-over (steal install) | `mv -T` / `File.Move(...,true)` / 5.1 unlink+move | 1 (local FS) | ✓ U:212-346, I:16d S:1141 | **In scope on local FS.** Boundary = D-axis. |
| D2 | O_EXCL atomic create | `set -C` redirect / `FileMode.CreateNew` | 1 (local FS) | ✓ throughout | **In scope on local FS.** |
| D3 | Wrong-type at path (dir/symlink/FIFO/dev/socket) | Never stolen/deleted; loud warn; waiters → 97 | 1 (bash + ps1-on-Win) / 2 (ps1-on-POSIX) | ✓ U:818-892/1156-1262/Test 37 (rename-refused mid-steal), ~(plat) | **In scope.** ps1-on-POSIX residual = accept. |
| D4 | Non-lock CONTENT at path (user file) | Never stolen (content guard); warn | 1 | ✓ U:1034-1076 | **In scope.** Two accepted residuals (§D4). |
| D5 | Case-insensitive FS path collision | Not handled explicitly | 3 | ✗ | **Likely non-issue;** see §D5. Decide. |
| E1 | Network/shared FS (NFS/SMB/9p/Dropbox) | Outside design guarantees (stated) | 3 | ✗ | **Out of scope** (stated). See §E — decide whether to *enforce*. |
| E2 | Multi-host clock skew / NTP jump | Implicitly single-clock; **not** addressed in docs | 3 (and a doc gap) | ✗ | **Out of scope** but UNDER-documented. See §E2. |
| E3 | mtime probe unreadable (staleness clock broken) | Warns loudly once; treats as not-stale → safe, recovery disabled → 97 | 2 | ✓ U:Test 42 | **Accept** — fails safe + announced. See §E3. |
| F1 | Disk full (ENOSPC) during create/write | Create fails → wait; torn write ages out | 2/3 | ✓ U:Test 50 (Linux+sudo tmpfs; (plat) skip elsewhere) | **Tested** (§4.5) + document. See §F1. |
| F2 | ENOSPC during LOG write | Swallowed (`|| true`); silent log loss | 2 | ✓ U:Test 49 (portable failing-log path) | **Tested** (§4.5); logging best-effort, lock unaffected. |
| F3 | Inode / FD exhaustion | Create fails → wait → 97 | 2 | ○ (document-only) | **Document-only**: no deterministic portable injection. See §F3. |
| F4 | Read-only / unwritable lock dir or parent | `mkdir -p` best-effort; create fails → wait → 97 | 2 | ✓ U:Test 48 (POSIX `chmod 0555`; (plat) skip on Windows) | **Tested** (§4.5, highest-value). See §F4. |
| G1 | Lock path = a directory / `$HOME` typo | Never stolen/deleted; loud warn; → 97 | 1 | ✓ U:818-840 | **In scope.** Keep. |
| G2 | Garbage numeric config | Falls back to default + stderr note | 1 | ✓ U:695-703, I:554-608 | **In scope.** Keep. |
| G3 | `run` outside a git repo, no `AGENT_LOCK_PATH` | Refuses (96) | 1 | ✓ U:705-712 | **In scope.** Keep. |
| G4 | `MAX_WAIT ≤ STALE + CLAIM_STALE` (default MW) | Startup warning | 2 | ✓ U:497-522 | **In scope.** Keep. |
| H1 | SIGINT/SIGTERM mid-hold | Release + re-raise (143); traps restored | 1 | ✓ U:577-600/1989-2011 | **In scope.** Keep (bash). ps1 = §H. |
| H2 | EXIT-while-holding | Release + chain caller's EXIT trap | 1 | ✓ U:633-648 | **In scope.** Keep. |
| H3 | ps1 process death under `-File` | `PowerShell.Exiting` does NOT fire; relies on stale window | 2 | ○ (limit documented) | **Accept;** `run` path is covered. See §H. |
| H4 | Non-unwinding exit while held (SIGKILL / bash `exec` / `[Environment]::Exit()`) | Skips release → a displaced holder is unwarned (no 98); plain `exit` is safe | 2 | ~ (I:308-334 indirect) | **Document** the no-silent-loss boundary. See §H4. |
| I1 | bash⇄pwsh wire/format compatibility | Shared format; token grammar tightened to match | 1 | ✓ I:* throughout | **In scope.** Keep. |
| I2 | Mixed-VERSION tree (old unserialized steal) | Prevention degrades to detection (98); `.dead.*` litter | 3 | ✗ | **Out of scope:** "upgrade both together." Residual 4. |
| J1 | Logging subsystem failure | All log writes `|| true`; 1 MB self-truncate | 2 | ✓ U:Test 49 (via F2) | **Tested** (§4.5, via F2); logging never blocks the lock. |
| K1 | Extreme load / CPU oversubscription / slow FS | Correctness holds; wall-clock bounds stretch | 2 | ~ (CI stress) | **Define the envelope.** See §K — the key analytical section. |
| K2 | Internal time budgets (poll, MAX_WAIT, read ladder) | Fixed schedules; tunable | 2 | ✓/~ | **In scope** as Tier-2 envelope. See §K. |

U = `tests/git-commit-lock.test.sh`, I = `tests/git-commit-lock.interop.test.sh`,
integ = `tests/git-commit-lock.integration.test.sh`.

---

## 3. Per-mode detail

### A. High contention / thundering herd

**A1 — Clean contention, no crashes.** N processes race to acquire a free or
held-then-released lock. The acquire loop is one O_EXCL create attempt per poll;
exactly one creator wins, the rest poll and take turns
(`git-commit-lock.sh:1312-1361`). After winning, the acquirer re-reads its own
token (read-back verification, `git-commit-lock.sh:1352-1361`) before claiming
the hold — so even a create that "won" but whose file was concurrently
clobbered does not produce a false hold.
*Tier 1.* Tested heavily: unit Test 1 (8 rounds × 25 workers at FULL,
`U:166-195`), interop Test 1/Test 6 mixed bash+pwsh (`I:227-261`, the strict
deterministic counter `I:341-386`), and the integration suite's real-commit
swarm. **Recommend: in scope, keep.** This is the tool's whole reason to exist.

**A2 — Thundering herd recovering one dead lock.** After a holder dies, *every*
waiter judges the same lock stale off the same mtime in the same poll window —
the worst case for displacement. The **claim protocol** is the answer: to steal,
a waiter must first win an O_EXCL claim file `<lock>.next`, re-verify staleness
under the claim, then install by one atomic rename-over
(`git-commit-lock.sh:1070-1218`, the steps narrated at `:82-115`). This
*prevents* the straggler-robs-recovery-winner race rather than detecting and
repairing it. *Tier 1.* Tested: unit Test 2b asserts zero spurious 98s, exactly
one `STOLE-BY-CLAIM` per round, and — via a background sampler — that **no
move-aside `.dead.*` file ever exists** (`U:212-346`); interop Test 16 proves
the same across mixed impls (`I:884-1015`). The header records the unserialized
baseline was probed to displace 5/5 with 4 waiters (`git-commit-lock.sh:233-234`).
**Recommend: in scope, keep — this is a load-bearing correctness property.**

**A3 — Many concurrent stealers.** Distilled A2: N stealers, one O_EXCL claim
winner, the rest wait and acquire in sequence. *Tier 1.* Tested: unit Test 20
(`U:1095-1128`), interop Test 16b (one bash claimant vs one ps1 claimant on one
ghost, cross-parsing each other's claim files, `I:1017-1088`).
**Recommend: in scope, keep.**

> **Load caveat on A2/A3 (see §K):** *correctness* is load-independent (it rests
> on O_EXCL + atomic rename, not timing). What stretches under load is the
> *latency* to recover, and the *test harness's* ability to set up the race
> deterministically — Test 2b/16 carry heavy sync scaffolding and bounded
> discard-and-retry precisely because a fast waiter can complete an entire steal
> before the harness finishes backdating the ghost (`U:70-104, 285-336`). That
> is a test-harness envelope concern, not a protocol gap.

### B. Holder death

**B1 — Crash/SIGKILL/power loss mid-hold.** The lease ages out: once the lock
file's mtime is older than `STALE_SECS`, a waiter steals it. *Recovery is Tier
1; recovery latency is Tier 2* (bounded by STALE + poll cadence under normal
load). Tested via the stale-lock and empty-orphan steals (`U:197-210, 348-361`).
**Recommend: in scope (recovery). Document the latency bound (§K).**

**B2 — Trappable death mid-claim (INT/TERM).** The EXIT/INT/TERM handlers are
armed at acquire *start*, not at hold, in "claim-window mode"
(`git-commit-lock.sh:1299-1310, 987-997`). A trappable exit while a claim is in
flight runs the token-checked claim deletion (one bounded retry) and a final
discovery read; it never runs lock-release (98) semantics on a *mere claim*.
*Tier 1.* Tested: unit Test 33 — TERM mid-claim deletes our claim, leaves a
*foreign* claim intact, no 98, no ageout penalty (`U:1857-1928`); the matching
ps1 lane is interop Test 16e (`I:1151-1244`). **Recommend: in scope, keep.**

**B3 — Untrappable death mid-claim (SIGKILL between claim and rename).**
Deliberately **accepted, not prevented** (residual 5,
`git-commit-lock.sh:266-282`). The orphaned claim normally just ages out at
CLAIM_STALE; the rare bad case is a suspended rival's rename installing it as an
*unowned* lock that stalls waiters ≤ STALE before the lease recovers it. Crucial
property: **no false success anywhere** — nobody believes they hold; the only
cost is a bounded stall, same class as B1 at far lower probability. The preventing
alternative (a two-rename compare-and-swap) was evaluated and rejected because it
reintroduces crash litter (`git-commit-lock.sh:276-282`). *Tier 2.* Tested for
forensics/recovery via the crashed-leaver leg of Test 31 (`U:1648-1677`).
**Recommend: accept as a documented bounded residual. Do not build the
two-rename CAS** — the cure is worse than the disease and the failure is already
false-success-free.

**B4 — Slow but uncontended holder.** With no waiter, nothing moves the file;
the token still matches at release; success. *Tier 1.* Tested: unit Test 4c,
interop Test 9 (`U:419-429`, `I:494-499`). **Recommend: in scope, keep** — this
is what stops the lock punishing every slow-but-safe hold.

**B5 — Slow CONTENDED holder (the fail-open ceiling).** A hold past STALE *with*
a contender gets stolen; the robbed holder detects it at release (file gone, or
a foreign token — both definitive because acquire's read-back proved our token
was at the path) and returns exactly **98** plus a WARNING
(`git-commit-lock.sh:1620-1688`). *Tier 1 for detection.* Tested: unit Test 4b,
interop Test 8 both directions (`U:387-417`, `I:460-492`). **Recommend: in
scope, keep.** This is the deliberate fail-open-but-detectable contract; the
mitigation is operational — "commits must be fast" (the golden rule,
`docs/git-commit-lock.md:433-458`), and raise STALE for a genuinely slow hold.

### C. Orphaned / stale locks and claims

**C1/C2 — Stale or empty lock.** Staleness is judged by the lock file's own
mtime; a lock older than STALE and *lock-shaped* (empty, or line 1 starts
`tok.`) is stealable (`git-commit-lock.sh:1408-1446`). The empty case is the
crash-between-create-and-write orphan and is explicitly stealable. *Tier 1.*
Tested: Test 2 (stale), Test 3 (empty orphan regression) (`U:197-210, 348-361`).
**Recommend: in scope, keep.**

**C3 — Crashed-claimant / empty-claim orphan.** A claim older than CLAIM_STALE
(default 60s; claims are normally held for ms) is cleared by any waiter, which
re-races the claim create (`git-commit-lock.sh:1228-1267`). A crashed claimant
therefore delays only *steals*, only by ≤ the claim window; a free lock path is
never blocked by a claim. *Recovery Tier 1, latency Tier 2.* Tested: Test 21
(aged foreign claim and empty claim both age out and recovery completes,
`U:1130-1154`). **Recommend: in scope, keep.**

> **Test 21's `≤20s` latency assertion is Tier 2, not Tier 1.** `U:1144` asserts
> wall-clock recovery `≤20s` with STALE=1, CLAIM_STALE=2, MAX_WAIT=30. The
> *protocol* recovers correctly regardless; the 20s number is a generous
> envelope bound that a sufficiently oversubscribed runner (e.g. 8 CPU hogs on a
> 2-core box under the stress wrapper) can blow without any protocol defect.
> This is exactly the kind of bound §K says to treat as a test-harness envelope:
> if it flakes under extreme artificial load, **relax the test's bound or scope
> the stress level — do not harden the code.**

**C4 — Leaked claim.** A few exits must leave a claim behind without a verifiable
unlink (an unreadable claim; an unlink blocked by a foreign handle — exactly
three feeders, `git-commit-lock.sh:138-157`). These append the attempt token to
an in-process **leaked-token memory**. While non-empty, every poll (and a pass
at release/timeout) also reads the lock's line 1: a listed token there means a
rival's rename installed *our* leaked claim as the lock → adopt the hold, or, at
release, recognise our real hold was displaced, clean the leaked file
best-effort, and report 98. The result is structural: **no process inside an
acquire/hold/release arc can leave an *unowned* lock** (per-attempt tokens make
the discovery read conclusive). One scope nuance worth stating, because the
memory is **process-local**: only the leaking process can *adopt* its own
installed claim. If that process exits the arc first — times out (97), releases
cleanly, or dies — *before* adopting, the installed claim becomes an unowned lock
recovered by the ordinary staleness lane, never adopted by another process (this
is exactly residual 5 / §B3). Per-attempt-token uniqueness still guarantees that
lock can never be *mistaken* for owned by anyone, so there is **no false
success** — the only cost is a bounded stall. *Tier 1.* Tested extensively: Test 31 (the four
leaked lanes, including a real Windows no-delete-share feeder), Test 35
(release-time cleanup of a leak installed over a held hold → 98), Test 36
(inconclusive-read keeps the entry) (`U:1549-1758, 2013-2164`); ps1 parity in
interop Test 16e. **Recommend: in scope, keep.** This is the most intricate
machinery in the tool and the most thoroughly tested.

### D. Filesystem semantics the protocol depends on

These are the **load-bearing FS assumptions**. Where one does not hold, that is a
real robustness boundary, not a bug to fix.

**D1 — Steal install: atomic overwrite vs. the 5.1 fallback.** The steal installs
its lock at the path by replacing whatever is there. There are two engine classes
and they differ in atomicity — so this row is *not* uniformly "atomic rename":
- **Atomic overwrite (the guaranteed lane):** one `rename(2)`-class replace with
  no path-absent window. bash uses GNU `mv -T` where available, probed once, with
  a guarded `[ -d ]` + bare-`mv` fallback on BSD/macOS
  (`git-commit-lock.sh:954-979`); pwsh 7 uses the 3-arg `File.Move(src,dst,true)`
  (`git-commit-lock.ps1:941-982`). Atomic replace is guaranteed on local POSIX FS
  and NTFS (probe R1: 400 replaces, zero absent reads,
  `git-commit-lock.sh:380-382`); *not* guaranteed on some network FS (§E).
- **Windows PowerShell 5.1 fallback (NOT atomic, but claim-guarded):** 5.1 has no
  3-arg overload, so it unlinks then does a 2-arg `Move` (`git-commit-lock.ps1:941-982`).
  This lane has a real path-absent window in which a rival's *create* can win the
  recovered path — a **fairness loss, never a clobber** (claim serialization still
  admits one stealer; the loser re-polls), documented at
  `docs/git-commit-lock.md:471-476`.
`File.Replace` is *deliberately never used* (throws on read-only dest;
partial-failure states) — pinned by a static grep in interop Test 16d
(`I:1141-1149`). *The atomic lane is Tier 1 on local FS; the 5.1 fallback is Tier
1 for safety (no clobber) but gives up rename atomicity (fairness only).*
**Recommend: in scope on local FS; the network-FS boundary is §E.**

**D2 — O_EXCL atomic create.** `set -C` noclobber redirect (bash) /
`FileMode.CreateNew` with `FileShare.ReadWrite|Delete` (ps1,
`git-commit-lock.ps1:650-670`). Atomic create-or-fail on local POSIX and NTFS;
exactly one creator wins. *Tier 1 on local FS.* **Recommend: in scope on local
FS.** Boundary: O_EXCL is the classic NFS weak spot (§E).

**D3 — Wrong-type object at the lock or claim path.** A directory, symlink, FIFO,
socket, or device at the path is **never stolen or deleted**. bash has a
pre-create type guard (`[ -f ] && ! [ -L ]`) plus a per-poll wrong-type
classifier with two-consecutive-poll confirmation to survive Windows
delete-pending ghosts (`git-commit-lock.sh:1322-1327, 1518-1570`); the same
guards apply to the claim path with independent per-path warn-once state
(`:1458-1487`). The FIFO case is *why the pre-create guard is mandatory*: a
noclobber `>` onto a FIFO blocks in `open(2)` before any timeout logic — a hang,
not a warning. *Tier 1 on bash, and on ps1-on-Windows.* Tested: Test 17
(dir/symlink/FIFO at lock path), Test 22 (claim path), Test 17d (churn must not
false-warn) (`U:818-892, 1156-1262, 894-1032`).

> **The one real D3 boundary — ps1 on POSIX (Tier 2, accepted).** The .NET API
> exposes no portable type bit for FIFO/device/socket on Unix; they stat as size
> 0 and take the **empty-orphan steal lane** (lock path) or empty-claim clear
> lane (`git-commit-lock.ps1:62-78, 520-525`; `docs/git-commit-lock.md:215-222`).
> Damage is capped at the one misconfigured inode (consumed by the rename). This
> is an **unsupported configuration** (ps1 is Windows-only; POSIX runs it solely
> as cross-impl protocol verification, `README.md:91-95`). **Recommend: accept,
> as documented.** Closing it would need a `stat(2)` shell-out the port avoids;
> not worth it for an unsupported config.

**D4 — Non-lock CONTENT at the path.** An age-gated content guard steals only
empty or `tok.`-prefixed line-1 content; a real user file at a typo'd path
survives forever (`git-commit-lock.sh:1411-1444`). *Tier 1.* Tested: Test 18
(user file untouched; sub-prefix torn write `to` never stolen; `tok.`-prefixed
torn write *is* stolen) (`U:1034-1076`). **Two accepted residuals** make the
guarantee precise (`git-commit-lock.sh:298-311`): (a) a stale **empty** user
file is indistinguishable from the crash orphan and *is* stolen; (b) a stale
user file whose line 1 happens to start `tok.` passes the wire test and *is*
stolen. Both are deliberate (a fuller shape check buys near-zero protection for a
harder-bound wire format). **Recommend: in scope, keep, with the two residuals
documented** (already are).

**D5 — Case-insensitive filesystem.** Not handled explicitly. The lock and claim
paths differ only by the `.next` suffix (`<lock>` vs `<lock>.next`), which never
collide under case folding, and the token content is case-exact regardless of FS
case sensitivity. The only theoretical exposure is two *different* configured
`AGENT_LOCK_PATH` values that differ only in case resolving to one file on
NTFS/APFS — but that would be a single shared lock, which is *correct* behavior
(they'd serialize), not a break. *Tier 3 (non-issue).* **Recommend: out of
scope as a non-issue; no action.** (Cheap to add one sentence to the design doc
if desired.)

### E. Network / shared filesystems and clocks

**E1 — Network/shared FS (NFS, SMB/CIFS, 9p, Dropbox/OneDrive sync).** The design
doc states this plainly: the repo must live on a **local FS with atomic
create/rename and sane mtimes**; "repos on network or sync-backed storage … are
outside the design's guarantees" (`docs/git-commit-lock.md:122-126`). This is the
honest boundary, because the protocol's *correctness* rests on D1 (atomic
rename-over) and D2 (O_EXCL create), and both are exactly the operations network
filesystems weaken:
- **NFS:** `O_EXCL` create is famously unreliable on older NFS (the client can't
  guarantee exclusive create across the network); `rename` atomicity and mtime
  granularity vary by version/server. On such a mount, **D2 can let two creators
  both "win"** → two live holders, and the read-back verification
  (`:1352-1361`) is the only backstop (it would catch *some* but not all
  interleavings).
- **SMB/CIFS:** delete/rename semantics and the no-delete-share handle behavior
  differ from both POSIX and local NTFS; mtime resolution and clock source may be
  the *server's*, not the client's.
- **Sync folders (Dropbox/OneDrive):** asynchronous replication means the lock
  file's existence and content are *not* globally consistent — two machines can
  both create "the" lock locally before sync reconciles. Fundamentally broken;
  not a tunable.

*Tier 3 (out of scope, stated).* Untested (CI runs local FS only). **Recommend:
keep out of scope — but consider making it harder to *fall into* accidentally.**
The current failure mode on a bad FS is *silent* (the tool runs, exclusion may
just not hold). Options, in increasing cost: (i) leave as-is, documented — the
default lock lives in `.git`, which is almost always local, so accidental
network use is rare; (ii) a one-line caveat in `README.md` (currently only in the
deeper design doc); (iii) an optional best-effort startup probe of the lock dir's
FS type with a stderr warning on a known-network type (cheap on Linux via
`stat -f`, awkward cross-platform, and inherently incomplete). **My
recommendation: (ii) now** (surface the boundary in the README, where an operator
actually looks), and treat (iii) as optional polish — do *not* try to *support*
network FS.

**E2 — Multi-host clock skew / NTP jumps / timezone.** *This is the one place
the documentation is genuinely thin, and it deserves a deliberate decision.*
Staleness is mtime-vs-`now` arithmetic (`git-commit-lock.sh:928, 1409`). The
lock file records `host=<hostname>` (`:519`), which *suggests* cross-host use —
but the staleness math implicitly assumes **the mtime and the comparing
process's clock come from the same time source.** Reasoning from first
principles about what can go wrong:
- On a **single host** (the actual supported case — all contenders share one
  checkout, hence one machine), mtime and `now` are the same clock; skew is a
  non-issue, and the **mtime floor** (946684800 / 2000-01-01,
  `git-commit-lock.sh:925`) already absorbs the only real local clock glitch:
  the Windows FILETIME-zero (1601) transient on fresh files
  (`docs/git-commit-lock.md:283-293`, probed at 0.04–0.5% of readings).
- A **large local clock correction** on the one host splits by sign, because
  staleness is `age = now - mtime` (`git-commit-lock.sh:928, 1409`): a **forward**
  jump (now leaps ahead) inflates the computed age, so a *live* lock can look
  stale → premature steal; a **backward** jump (NTP steps back) shrinks the age,
  so a genuinely *stale* lock can look fresh → delayed recovery. The
  forward/premature-steal case is the only worrying one — and it degrades into the
  *already handled* B5 lane: a premature steal of a still-live hold is detected at
  release as 98 (given cooperative unwind), never a silent double-commit. So even
  a local clock jump is **correctness-safe, liveness-degraded** — Tier 2.
- **Cross-host** use over a shared FS (already E1-out-of-scope) is where skew
  would actually bite: host A's mtime compared against host B's `now` with
  minutes of skew could steal live locks wholesale. But this only arises *on a
  network FS*, which is already excluded.
- **Timezone** is a non-factor: all arithmetic is in epoch seconds
  (`git-commit-lock.sh:439-449`, `git-commit-lock.ps1:448-451`), never local
  time.

*Tier 3 for cross-host (rides on E1); Tier 2 for a local NTP jump.* Untested.
**Recommend:** (a) **document explicitly** that the tool assumes a single time
source — i.e. single-host use (the common case) or a shared FS with a single
server clock — and that this is *why* network/multi-host is out of scope; the
current docs imply it but never say "one clock." (b) Note the reassuring part: a
*local* clock jump is correctness-safe (degrades to the detected-98 lane), so no
code change is warranted. This is a **doc gap, not a code gap.**

**E3 — mtime probe fails entirely (the staleness clock is unreadable).** Distinct
from a *wrong* clock (E2): here the lock file's mtime cannot be read at all. Both
ports retry three times on a *present* file, then warn loudly once per process —
bash via `stat -c %Y` / `stat -f %m` / `date -r` (`git-commit-lock.sh:629-645`),
pwsh via `Get-Item.LastWriteTimeUtc` (`git-commit-lock.ps1:531-560`): *"Staleness
detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges
waiters until MAX_WAIT."* The stale check then treats an unreadable mtime as **not
stale** — the floor guard `[ "$mt" -gt 946684800 ]` fails closed to "fresh"
(`git-commit-lock.sh:925-927`). **Safety is preserved**: the tool never steals a
lock whose age it cannot establish, so no premature steal and no corruption — but
**recovery of a genuinely crashed holder is disabled**, and waiters block to
MAX_WAIT (97). *Tier 2 (safety held, recovery lost — and loudly announced).*
Tested: unit Test 42 shadows the inner mtime probe to return empty on a present,
stale ghost and asserts the fail-safe lane — the "Staleness detection is BROKEN"
warn-once fires, the ghost is NOT stolen (left in place), and the waiter blocks to
MAX_WAIT → 97. **Recommend: accept and document** — it is a
host/FS-health failure the tool already detects and announces, and it fails *safe*
(no false steal); the loud warning is the right behavior. This is also the clean
reason recovery is a *Tier-1-within-envelope* property, not unconditional (see the
tier split under §1): it presumes a readable clock.

### F. Resource exhaustion

**F1 — Disk full (ENOSPC) during a claim/lock create or write.** The create is
one open+write+close in a subshell; if the write fails (ENOSPC), the subshell
fails and the acquirer falls through to wait (`git-commit-lock.sh:1336-1361`,
comment at `:1341-1343`). A created-but-write-failed file is an empty orphan that
ages into the steal lane. A torn write *shorter than `tok.`* (e.g. `to`) is the
accepted residual at `:299-304`: non-empty, non-prefixed → never stolen, loud,
fixed by one manual `rm`. *Tier 2 (degrades to wait/97) / Tier 3 (the torn-write
manual-fix residual).* **Tested** (per §4.5): unit Test 50 mounts a small 64k
tmpfs, fills it to ENOSPC, and asserts the waiter times out at 97 with the wrapped
command never running — no corruption, no false hold. ENOSPC injection needs a full
FS (root via a tmpfs; `ulimit -f` raises SIGXFSZ — the wrong lane), so the test runs
on **Linux with passwordless sudo** (the Linux CI leg) and skips-with-note elsewhere.
ENOSPC is a host-health failure; the tool degrades safely (no corruption, no false
hold) and the one sharp edge (sub-`tok.` torn write needing manual `rm`) is already
documented.

**F2 — ENOSPC during a LOG write.** All log writes end in `|| true`
(`git-commit-lock.sh:561`); a failed log write is silently lost. *Tier 2.*
**Tested** (per §4.5): unit Test 49 points `AGENT_LOCK_LOG` at a path *under a
regular file*, so every open/append fails ENOTDIR, and asserts the lock still
acquires + releases cleanly (rc 0), the wrapped command runs, the lock is cleaned
up, and no log file appears — i.e. the failing log write is swallowed and the lock
is unaffected. This is a portable injection (no chmod/perms), and it **also covers
J1**. Logging is best-effort by explicit design (it must never block or fail the
lock); the only downside is reduced post-mortem signal under disk pressure.

**F3 — Inode / FD exhaustion.** Same shape as F1: a create that can't get an
inode fails → wait → eventually 97. The tool holds at most a couple of FDs
briefly. *Tier 2.* **Document-only — no deterministic portable injection.** A
`ulimit -n` FD cap can't be driven deterministically here: the create needs only
~1 FD, so an FD-exhaustion test would have to pin the process at *exactly* the
limit across a poll loop without starving the harness itself — not portable or
stable. Inode exhaustion needs a full FS the way F1 does (and F1/Test 50 already
exercises the create-fails-→-wait-→-97 lane that F3 shares). So F3 is recorded as
a reasoned-but-untested boundary rather than given a flaky test; the safe-degrade
behaviour is the same as F1, which is tested.

**F4 — Read-only / unwritable lock dir or parent.** `lock_acquire` does a
best-effort `mkdir -p "$(dirname …)"` (`git-commit-lock.sh:1278`); if the dir is
unwritable the create fails every poll and the waiter times out at 97. No
corruption, no false hold. A *release* unlink blocked by an unwritable parent
routes to the LEFTOVER lane (`:1699-1711`). *Tier 2.* **Tested** (per §4.5 — the
highest-value one): unit Test 48 `chmod 0555`s the lock-dir parent and asserts the
waiter times out at 97, the wrapped command never runs, no lock file is created,
and the WAITING/TIMEOUT lines are logged — no corruption, no false hold. POSIX-only
(`chmod 0555` is a no-op for writes on Git-Bash/NTFS, so it skips-with-note on
Windows; the Linux/macOS CI legs exercise it). A correct, if blunt, outcome (97); an
*earlier, clearer* error would be nicer but is optional polish, low priority.

**F5 — Memory exhaustion.** The scripts allocate trivially (a few shell vars; the
leaked-token list is "almost always empty"). Not a meaningful failure surface.
*Tier 3 / non-issue.* **Recommend: no action.**

### G. Misconfiguration

**G1 — Lock path is a directory / `$HOME` / a real file.** Covered by D3/D4:
never stolen or deleted, loud one-time warning, waiters reach 97
(`U:818-840`). *Tier 1.* The security note (`docs/git-commit-lock.md:530-541`)
bounds the worst case even for a *hostile* repo redirecting the git dir: the tool
only ever creates its own small set of files at its own names and never deletes
recursively. **Recommend: in scope, keep.**

**G2 — Garbage numeric config.** Each knob is validated at source time; invalid
values fall back to default with a stderr note (`git-commit-lock.sh:481-500`).
The ps1 port *tightens* .NET's permissive parser to bash's grammar so the same
env var configures the same value on both impls — e.g. rejecting `"1e3"`,
trailing newlines, whitespace (`git-commit-lock.ps1:327-359`). *Tier 1.* Tested:
unit Test 13, interop Test 12 (cross-impl parity, including `1e3`/`+2`/`'   '`/
trailing-newline) (`U:695-703`, `I:554-608`). **Recommend: in scope, keep.**

**G3 — `run` outside a git repo, no `AGENT_LOCK_PATH`.** Refused with 96 — a
CWD-scoped lock would serialize against nobody (`git-commit-lock.sh:1768-1773`).
Sourcing keeps a CWD fallback with a stderr warning and creates no files
(`:570-572`; unit Test 14/14b). *Tier 1.* **Recommend: in scope, keep.**

**G4 — `MAX_WAIT ≤ STALE + CLAIM_STALE`.** A startup warning, gated on MAX_WAIT
being left at its default (a caller who set it chose the relationship). The
relation is the stacked worst-case recovery: a crashed holder *plus* a crashed
claimant (`git-commit-lock.sh:502-514`). *Tier 2 (advisory).* Tested: Test 8
exercises the gate and the stacking (`U:497-522`). **Recommend: in scope,
keep.**

### H. Signals, interrupts, cleanup-on-exit

**H1/H2 — bash INT/TERM/EXIT.** Handlers armed at acquire start; on a held lock
they release and re-raise the signal (wrapper dies 143, what a watchdog needs);
they restore the caller's pre-acquire traps exactly (`git-commit-lock.sh:1037-
1054, 1002-1023, 780-784`). *Tier 1.* Tested: Test 11 (TERM mid-hold → 143,
released), Test 12c (exit-while-holding chains the caller's EXIT trap), Test 12d/e
(trap restoration), Test 34 (TERM on a *steal*-acquired hold behaves identically
— all acquisition paths funnel through one hold helper) (`U:577-600, 633-693,
1989-2011`). One documented caveat: a SIGINT delivered to the `run` wrapper alone
while its foreground child survives is discarded by bash before any trap
(`git-commit-lock.sh:1030-1036`) — a real Ctrl+C hits the whole group and does
take the path. **Recommend: in scope, keep.**

**H3 — ps1 process death.** PowerShell has no `trap SIGTERM`. The port substitutes
(a) `try/finally` inside `Lock-Acquire`, which runs on Ctrl+C/pipeline-stop/
terminating errors and does the claim-window cleanup + discovery read
(`git-commit-lock.ps1:1378, 1672-1683, 1240-1295`); and (b) a `PowerShell.Exiting`
engine-event backstop for a *held* lock (`:704, 1303-1324`). **Documented limit:**
`PowerShell.Exiting` fires under `-Command` and interactively but **NOT under
`-File`**, and not on hard kill / `[Environment]::Exit()`
(`git-commit-lock.ps1:241-245, 1298-1302`). So a held lock abandoned by a
forgetful dot-source `-File` caller relies on the stale window, not the backstop.
The **`run` contract path is unaffected** — it pairs Acquire/Release in
try/finally (`:1928-1979`). *Tier 2 (for the dot-source `-File` gap).* The happy
path and trap-time claim cleanup are tested (interop Test 16e); the `-File`
non-firing is documented, not test-pinned. **Recommend: accept the `-File`
backstop gap as documented** — the stale window recovers it, and the supported
`run`/try-finally paths are covered. If you want to close it, the documented
option is handle-based ops (`git-commit-lock.ps1:146-151`), a larger change not
worth it for a forgetful-caller edge.

**H4 — Process termination/replacement *without wrapper unwind* (the no-silent-loss
boundary).** §1's safety guarantee — a displaced holder reports 98 rather than a
false success — relies on the wrapper *reaching its release path*. The bypass class
is any termination or replacement of the holding process that skips that unwind;
crucially it is **not** triggered by a normal `exit`. The instances:
- **External SIGKILL** — untrappable; no handler runs in either port.
- **bash `exec` that replaces the lock-holding shell** — `run` executes `"$@"`
  *in the wrapper shell itself* (`git-commit-lock.sh:1733`), so the bypass needs the
  exec to run in *that* shell: the wrapped command *is* an exec (`run -- exec …`),
  or a **sourced** caller does `lock_acquire; exec …` in its own shell. Then the
  exec replaces that shell's process image and *neither* the trailing `lock_release`
  *nor* the `EXIT` trap (`git-commit-lock.sh:1002-1013`, armed at `:1308`) runs. An
  exec **nested in a child** — the ordinary `run -- bash -c 'exec …'` — does **not**
  bypass (the child is replaced; the wrapper waits and releases normally). *Verified
  empirically 2026-06-17.*
- **PowerShell `[Environment]::Exit(n)`** — a CLR hard-exit that bypasses
  `Lock-Release`, the `finally`, *and* the `PowerShell.Exiting` backstop
  (`git-commit-lock.ps1:221-245`).

The useful contrast: a **plain `exit` is safe** — bash `exit` fires the EXIT trap
(which releases), and a plain `exit` inside the pwsh `run` body unwinds its
`finally` (`git-commit-lock.ps1:1928-1979`). Only *non-unwinding* termination or
replacement escapes. If such a process was *already displaced* (its lease stolen
past STALE) and exits **0**, its caller sees success with no 98 — the one
interleaving that defeats "no silent lost update." What keeps it narrow: an external
SIGKILL yields a non-zero wait status (`128+9`), so a caller checking exit codes does
*not* see success; the leak needs a command that *deliberately* replaces or
hard-exits the process **and** returns 0 **while displaced**. The *next* holder
still recovers via staleness; only the abruptly-exiting one is unwarned. *Tier 2 —
the residual edge of the fail-open lease.* Exercised indirectly: interop Test 5
*uses* `[Environment]::Exit()` to fabricate a no-release orphan, confirming the
bypass (`I:308-334`). **Recommend: document this as the explicit boundary of the
no-silent-loss guarantee**, alongside the "commits must be fast" golden rule — a
command that replaces/hard-exits the process mid-critical-section *after being
displaced* is exactly the fail-open case the STALE budget exists to make rare. No
code change closes it without the handle-based ops the design rejected (§H3).

### I. Cross-implementation

**I1 — Wire/format compatibility.** One on-disk format (token line 1, owner line
2, `tok.` prefix as wire contract), one read-retry schedule (8 attempts,
20/40/80/160/320/320/320 ms — verified byte-identical between
`git-commit-lock.sh:670` and `git-commit-lock.ps1:597-629`), one set of release
verdicts, one config grammar. *Tier 1.* The interop suite is built to break this:
mixed bash+pwsh exclusion (T1/T6), each side steals the other's genuine stale
lock (T4/T5), robbed-holder 98 both directions (T8), release-classification
agreement (T11), cross-impl claim staleness clearing (T16c), and a Windows
PowerShell 5.1 smoke lane (T17). **Recommend: in scope, keep — and keep the
interop suite as the guard.** Two independent implementations hammering one lock
is "cheap adversarial verification of the protocol" (`README.md:94`).

**I2 — Mixed-version tree.** Prevention (the claim protocol) holds only when
*all* parties run it; older releases stole with an unserialized move-aside, so a
mixed tree degrades prevention to detection (98) and can leave `.dead.*` litter
current versions don't clean (residual 4, `git-commit-lock.sh:261-265`). *Tier
3.* Untested (would require shipping an old version into the suite). **Recommend:
out of scope; keep the "upgrade both implementations together" deployment note**
— currently in the design doc only (`docs/git-commit-lock.md:251-255`), **not** in
`README.md`; surface it there too, where operators actually look. Acceptable
because the degraded mode is still *detected* (98), never silent.

### J. Logging subsystem failure

**J1.** Every log write is `|| true`; the log self-truncates past ~1 MB rather
than rotating (`git-commit-lock.sh:554-562`). A broken log never blocks or fails
the lock. Under a redirected git dir, log *content* (the owner line) is
attacker-influenceable — one-line text spoofing, no execution; the tool itself
writes only its token, owner line, and protocol events, never secrets
(`docs/git-commit-lock.md:543-551`). *Tier 2.* **Tested — covered by the F2
log-failure test (per §4.5): unit Test 49** proves a failing log path leaves the
lock fully working. Logging is best-effort by design, which is the right call for a
lock that must keep working when the disk is full or the log path is bad. The
follow-on (unchanged): don't build automation that *trusts* log text from an
untrusted repo (already documented).

### K. Behavior under extreme load / scheduling pressure, and internal time budgets

**This is the most important analytical section** — it separates "must hold under
any load" from "holds within an envelope," and tells the owner which apparent
flakes are real gaps vs harness concerns.

**The clean split: correctness is load-independent; liveness/latency is not.**

- **Load-independent (Tier 1 *safety*, must always hold):** no silent lost update
  (given cooperative unwind, §1/§H4), no corruption, and strict mutual exclusion
  *within the staleness window*. These rest on O_EXCL create + atomic rename +
  per-attempt-token discovery — *structural* properties that do not reference the
  clock for their *correctness*. (Recovery of lock-shaped orphans is also
  load-independent in *correctness* — only its latency degrades — but it presumes
  a readable clock, §E3, and does not extend to foreign objects, per the tier
  split under §1.) The mtime
  floor
  (`:925`) and the read-retry ladder (`:668-684`) exist precisely so that the
  one timing-sensitive input (mtime, and transient empty reads) cannot corrupt a
  correctness decision: a sub-floor or unsettled reading is treated as "wait,"
  never "steal." A 25-worker round can go 3s → 41s under load
  (`agents/600-claude.md` observation) and *still* lose no update.

- **Load-dependent (Tier 2, best-effort in an envelope):** every wall-clock bound.
  - **Recovery latency** ≈ STALE (+ CLAIM_STALE if a claimant also crashed) +
    poll cadence. Under CPU oversubscription or a slow FS, polls stretch, so
    recovery takes longer — but still completes.
  - **`MAX_WAIT` timeout (97):** a waiter on a genuinely squatted/blocked lock
    gives up at MAX_WAIT. Under load the *real* time to MAX_WAIT stretches with
    poll cadence; the guarantee is "bounded by MAX_WAIT polls," not "exactly
    MAX_WAIT seconds." Interop Test 14b explicitly checks that a blocked steal
    **never busy-spins past MAX_WAIT** and logs in a damped, bounded way
    (`I:746-817`) — a real correctness-adjacent property (no busy-spin), with a
    timing-dependent upper bound on the STALE-line count (`[1,8]`).
  - **The read-retry ladder (~1.26s budget):** sized to ride out a sub-second
    transient (AV scanner handle, probe-F create→write gap). Under pathological
    load a transient *longer* than ~1.26s would surface as the unverifiable-2 /
    run-1 verdict (a detected, non-corrupting outcome), not a wrong hold. Test
    16c pins that a 0.4s transient is ridden out (`U:784-817`).

**Internal time budgets, enumerated** (all tunable via `AGENT_LOCK_*`):

| Budget | Default | Role | Load sensitivity |
|---|---|---|---|
| `STALE_SECS` | 300s | steal threshold (the lease length) | the fail-open ceiling; raise for slow holds |
| `CLAIM_STALE_SECS` | 60s | crashed-claimant ageout | delays only steals |
| `POLL_SECS` | 2s | poll interval | cadence stretches under load |
| `MAX_WAIT` | 420s | total wait cap → 97 | real wall-clock stretches with cadence |
| read-retry ladder | ~1.26s | ride out transient empty reads | a longer transient → detected-2, not wrong hold |
| mtime floor | 2000-01-01 | reject FILETIME-zero | static, not load-sensitive |

**Judgments on the load-sensitive behaviors — gap, degradation, or harness
concern:**

1. **Protocol correctness under load — (c) non-issue / already guaranteed.**
   The stress branch wraps every suite in artificial CPU+disk load
   (`tests/with-load.sh`) specifically to widen timing windows and surface
   *latency/race flakes*, and the protocol assertions (exclusion, one-steal,
   zero-98) are written to hold regardless. **Recommend: nothing to harden.**

2. **Wall-clock test *bounds* under extreme load — (b) acceptable degradation;
   fix the TEST, not the code.** Two examples surfaced by the prior stress
   effort (which I verified independently against the code, not adopted):
   - *Test 21's `≤20s` recovery-latency assertion* (`U:1144`) and
   - *Test 22(a)'s claim-path warning* — the warning relies on the
     two-consecutive-poll confirmation (the mechanism Test 17d pins for the lock
     path) having poll *headroom* before MAX_WAIT, which an oversubscribed runner
     can starve (`U:1156-1172`); the test asserts the warning fires, not a specific
     poll count,
   - and *Test 29's `≥2 CLAIM lines` discriminator* (explicitly given `MAX_WAIT=6`
     headroom, `U:1514-1518`).

   Each asserts a wall-clock or poll-count bound that an oversubscribed runner
   (e.g. 8 hogs on 2 cores) can blow *without any protocol defect* — the
   protocol still recovers/warns correctly, just slower. **Recommend: where these
   flake only under extreme artificial load, relax the bound or scope the stress
   level for that test; do NOT change product code.** The correctness assertions
   in the same tests must stay strict.

3. **Test-*harness* race setup under load — (c) harness concern, already
   mitigated.** Tests 2b/16/16b carry heavy sync scaffolding (`sync_waiting_fresh`,
   token-guarded `backdate_ghost`, bounded discard-and-retry, `U:70-151`) because
   a fast waiter can complete an entire steal before the harness finishes setting
   up the race. This is purely about *constructing* the scenario deterministically;
   the protocol is fine. **Recommend: keep the scaffolding; it is the right fix.**

4. **No-busy-spin under a permanently blocked lock — (a) a real property, and
   it's guarded.** A failed-steal lane that `continue`d past the timeout+sleep
   would busy-spin and never reach 97 — a genuine bug class. Interop Test 14b is
   the regression guard (`I:746-817`). **Recommend: keep that test; treat any
   regression here as Tier 1.**

**Net K recommendation:** adopt the explicit envelope — *"correctness holds under
any load; wall-clock recovery/timeout latency scales with poll cadence and
scheduling, bounded by the configured knobs."* Put that sentence in the design
doc. Then audit the suite's wall-clock assertions and **scope each to the load
level it's meant to run at** (the stress branch's extreme `both/8-hog` mode is a
flake-hunting tool, not a contract the product must meet on a 2-core runner).
This is the cleanest way to stop chasing "flakes" that are really the test
asserting a Tier-1 bound on a Tier-2 quantity.

---

## 4. Open questions / recommended scope decisions

Ordered by how much they need an explicit owner decision.

**Status (Ben, 2026-06-17): reviewed and accepted — with two changes marked below.**
Item 3 (network FS) is **document-only**: do not build the FS-type probe. Item 5 is
**overridden** — the untested-but-robust lanes *will* get test coverage (actually-tested
edge cases make the tool more maintainable and give future users confidence), rather than
"accept untested". Every other recommendation is accepted as written.

1. **Define and document the load/timing envelope (§K) — highest value.**
   *Recommendation:* state in `docs/git-commit-lock.md` that correctness
   (exclusion, no silent loss, eventual recovery) is load-independent, while all
   wall-clock bounds (recovery latency, MAX_WAIT, the read ladder) are
   best-effort and scale with scheduling. Then **scope the suite's wall-clock
   assertions to a defined load level** so extreme-stress flakes (Test 21's 20s,
   Test 22a's warning timing, Test 29's poll count) are recognised as Tier-2
   envelope misses, not product regressions. *This resolves the recurring
   "flake" question structurally.* Cost: doc + a test-bound audit; no product
   change.

2. **Multi-host / clock-skew assumption is under-documented (§E2) — doc gap, not
   code gap.** The tool implicitly assumes a single time source; a *local* NTP
   jump is correctness-safe (degrades to the detected-98 lane), and cross-host
   skew only bites on a network FS that's already out of scope. *Recommendation:*
   add one explicit sentence — "assumes a single clock, i.e. single-host (the
   common case) or a shared FS with one server clock" — and the reassurance that
   a local clock jump cannot cause a silent double-commit. No code change.

3. **Network/shared FS is out of scope but fails *silently* if entered (§E1).**
   The boundary is correctly stated in the design doc but only there.
   *Decision (Ben — document-only):* surface the boundary in `README.md` (where
   operators look), since the failure on a bad FS is silent loss of exclusion. Do
   **not** attempt to *support* network FS, and **do not build** the optional
   FS-type startup probe — just document. (It would be cross-platform-awkward and
   incomplete anyway; Ben: "don't do the polish, just document.")

4. **ps1-on-POSIX FIFO/device residual (§D3) and ps1 `-File` exit backstop gap
   (§H3) — accept as documented.** Both are real but confined to an unsupported
   config (ps1-on-POSIX) or a forgetful-caller edge that the stale window
   recovers. *Recommendation:* no code change; confirm they stay documented.
   Reconsider only if PowerShell-on-POSIX ever becomes supported (it isn't,
   `README.md:91-95`).

5. **Untested-but-robust-by-code lanes (resource exhaustion F1/F3/F4, log-write
   failure F2/J1).** These degrade safely (wait/97, or silent best-effort log
   loss) but had **no fault-injection tests** — they were reasoned-correct, not
   verified. *Decision (Ben — overrides the prior "accept untested"):* **add test
   coverage** for these lanes. Rationale: actually-tested edge cases make the
   project easier to maintain and give future users confidence, versus
   "reasoned-correct but untested." Add deterministic fault-injection tests where
   feasible — **unwritable lock dir → clean 97** (F4, cheapest/highest-value and
   the most likely real-world misconfig); an **unwritable log path → the lock
   still works, the log write is swallowed** (F2/J1); and the **ENOSPC / inode /
   FD-exhaustion** lanes (F1/F3) where they can be injected deterministically and
   portably (e.g. a small dedicated tmpfs or quota for ENOSPC, `ulimit -n` for
   FDs). Flag in the plan any lane that proves genuinely impractical to fault-inject
   portably, rather than forcing a flaky test.

   *Status (done):* coverage added — **F4** unit Test 48 (POSIX `chmod 0555`,
   skip-with-note on Windows), **F2/J1** unit Test 49 (portable failing-log path via
   ENOTDIR), **F1** unit Test 50 (Linux + passwordless-sudo 64k tmpfs filled to
   ENOSPC; skip-with-note elsewhere). **F3** (inode/FD exhaustion) proved impractical
   to fault-inject deterministically and portably — the create needs only ~1 FD, so a
   `ulimit -n` cap can't be driven deterministically across a poll loop without
   starving the harness, and inode exhaustion needs a full FS the way F1 does (F1/Test
   50 already exercises the shared create-fails-→-wait-→-97 lane). Per the "flag any
   impractical lane" instruction above, F3 stays **document-only**, not a flaky test.

6. **Mixed-version tree (§I2) and case-insensitive FS (§D5) — out of scope,
   confirm.** The first degrades to detection (98), never silent, and is covered
   by the "upgrade both together" note. The second is a non-issue. *Recommendation:*
   leave both out of scope; optionally one sentence each in the design doc.

### Things explicitly NOT to do (the design already considered and rejected them)

- **A background heartbeat** to refresh the lease — would make the tool more than
  a single synchronous script; the fail-open-but-detectable lease is the
  deliberate alternative (`git-commit-lock.sh:217-218`).
- **A two-rename compare-and-swap** to prevent residual 5 (B3) — reintroduces
  crash litter + a sweep, for a failure that is already bounded and
  false-success-free (`git-commit-lock.sh:276-282`).
- **`File.Replace` in the ps1 port** — pinned out by interop Test 16d for good
  reasons (read-only-dest throw, partial-failure states).
- **Trying to support network/shared filesystems** — the protocol's correctness
  rests on local-FS atomic create/rename; this is a boundary to *document*, not
  to engineer around.
