# Plan: claim-serialized stealing (claim-is-the-next-lock + atomic rename-over)

Status: DRAFT v3 — round-2 findings folded; awaiting round-3 review.

## Goal

Replace the current steal mechanism (racing `mv` to a grave, plus the wave-1
detect-and-restore machinery) with **claim-serialized stealing**: to steal a
stale lock you must first win an O_EXCL claim file; the claim file carries your
own token and *becomes* the new lock via one atomic rename-over. This
**prevents** the displaced-live race (a straggler stealing the recovery
winner's fresh lock) that wave 1 (`2843d4e`, `4e3f890`) could only detect and
repair.

Design lineage: Ben proposed serializing steals through a second
create-or-fail file; this plan adopts that with one refinement — the claim file
is the next lock itself, so the steal is a single atomic replace with no grave
and no path-absent window (bash and pwsh 7; the 5.1 lane accepts a claim-guarded
absent window, see Implementation notes). See "Alternatives considered".

## Why prevention wins over wave 1's detect+restore

- The verify-under-exclusivity step (re-read the lock's staleness while holding
  the claim) makes it impossible to `mv` a *fresh* lock: while the lock path is
  occupied, creates fail; steals require the claim you hold; the only other
  mutation (a live slow holder releasing) makes the steal target vanish, which
  is handled (see algorithm step 4a).
- Removes three novel wave-1 mechanisms: grave-token comparison, hard-link
  restore, restore grace. Removes graves entirely (and the age-gated grave
  sweep): rename-over destroys the ghost and installs the new lock in one op.
- No path-absent window during recovery ⇒ no thundering-herd create re-race;
  the claimant that did the recovery work deterministically wins the lock.
- Drops the hard-link filesystem dependency wave 1 introduced.

## The protocol

### Objects

| Object | Path | Content |
|--------|------|---------|
| Lock   | `$AGENT_LOCK_PATH` (default `<gitdir>/commit.lock`) | line 1 `tok.<uniq>`, line 2 `pid=<pid> host=<host>` (unchanged) |
| Claim  | `${AGENT_LOCK_PATH}.next` | identical wire format, the **claimant's own** token |

The claim is written through its creation handle exactly like the lock (bash:
noclobber redirect; ps1: `FileMode::CreateNew` + write through that handle), so
the empty-file crash-orphan lane and the mtime-floor rule apply to it
identically (a sub-floor claim mtime means "unsettled, treat as just-created",
never "ancient, clear" — tested). The claim path also gets the lock path's
**pre-create type guard**: in bash a noclobber `>` onto an existing FIFO blocks
in open(2) — omitting the guard on the claim path is a *hang*, not a warning,
so it must be stated and implemented, not inherited by accident.

### Steal algorithm (replaces the current steal lane in both impls)

When a poll judges the lock stale (existing rules: regular file, lock-shaped
content, plausible mtime ≥ floor, age > `AGENT_LOCK_STALE_SECS`):

1. **Claim**: O_EXCL-create `${LOCK}.next` with our token.
   - Create fails because a claim exists → someone else is stealing; fall
     through to the claim-staleness check (below), then keep waiting.
2. **Re-verify under the claim**: re-read the lock fresh (content + mtime +
   floor + shape).
3. **Still stale** → the ordered install sequence:
   1. **Claim recheck**: re-read `${LOCK}.next`. It must (a) carry OUR token
      and (b) be younger than `AGENT_LOCK_CLAIM_STALE_SECS`. Rationale: a
      long-suspended claimant must not proceed on a claim a waiter may have
      already judged stale — this closes the stale-claim TOCTOU that round-1
      review flagged (a cleared-then-renamed claim installing an unowned
      lock). Outcomes:
      - **Gone** → ownership-discovery read (global rule, below): our claim
        may already have been installed as the lock by a rival's rename.
        Not ours at the lock either → re-poll.
      - **Foreign token** → ownership-discovery read first (ours may have
        been installed as the lock *before* the rival claimed); otherwise a
        clearer removed ours and a rival claimed: leave the file, re-poll.
      - **Ours but overaged** → assume contested (a clearer may be acting on
        it right now); delete our own claim (token-checked, below),
        `CLAIM-ABORT (contested)`, re-poll.
      - **Unreadable after the retry ladder** → leave it (it ages out),
        re-poll.
   2. **Touch the claim** (refresh its mtime) — **non-creating**: bash
      `touch -c`, ps1 `[IO.File]::SetLastWriteTimeUtc` catching
      FileNotFound. A creating touch would resurrect a vanished claim as a
      fresh empty `${LOCK}.next` that blocks every rival claim until it
      ages out (O_EXCL fails on it; clearers must wait out CLAIM_STALE) — a
      self-inflicted steal outage — and it masks the gone-claim signal the
      ownership-discovery rule keys on. Touch fails because the claim is
      gone → ownership-discovery read, then re-poll.

      Purpose of the touch: because rename preserves mtime, **the installed
      lock's staleness clock after the rename IS the claim file's mtime**,
      so the touch makes the new holder's lease start ~now. This fixes the
      aged-lease defect (a claim created up to CLAIM_STALE ago would
      otherwise install a lock already that old). Two accuracy caveats: the
      touch does NOT defend the rename against a clearer whose staleness
      read predates the touch — what actually bounds things is the
      step-3.1 recheck (our claim is younger than CLAIM_STALE at recheck)
      plus the ownership-discovery rule catching any leak. And a claimant
      suspended between this touch and the rename still installs a
      correspondingly aged-mtime lock — the lease shortfall is bounded by
      the touch→rename gap (milliseconds when not suspended), not
      guaranteed ~zero. (Decision: no recheck margin — keep the spec
      simple; the discovery rule makes the gap-frequency question moot.)
   3. **Re-verify the lock** still stale (as step 2; unchanged).
   4. **Rename-over**: `mv ${LOCK}.next ${LOCK}` (ghost destroyed + our live
      lock installed in one operation). Then run the existing acquire
      read-back verification (must find our own token) — kept as
      defense-in-depth.
4. **Not confirmed** (at step 2 or 3.3) → delete our claim (token-checked) and
   keep waiting. Two sub-cases:
   - (a) lock **gone** (the "stale" holder was live-slow and released, or
     another mutation): `CLAIM-ABORT (gone)`; do NOT rename onto the
     now-absent path — that lane belongs to the normal create race and
     renaming there could clobber a rival's fresh create. Delete claim,
     re-race the normal create.
   - (b) lock **fresh** (mtime renewed / different token): ownership-
     discovery read first — the "fresh" lock may be OUR OWN claim,
     installed by a rival's rename; our token ⇒ we HOLD the lock (without
     this branch we would abort on our own lock and orphan it). Otherwise
     `CLAIM-ABORT (fresh)`; delete claim, continue waiting.

**Token-checked claim deletion (global rule).** Every "delete our claim" path
anywhere in this algorithm reads the claim first and unlinks **only if line 1
is our token**. Foreign → run the ownership-discovery read (below; ours may
already have been installed as the lock before the rival claimed), then leave
the claim (it's a rival's live claim). Unreadable → leave it to age out.
Never blind-unlink the claim path. (The deletion's own read→unlink gap can in
principle unlink a rival's just-created claim — clearer and rival inside a
microsecond window; benign: the rival's recheck finds its claim gone →
ownership-discovery rule → it retries. Implementations must NOT add machinery
for this.)

**Ownership-discovery rule (global rule).** A rival's rename can install OUR
claim file as the lock while we are anywhere past the claim create. So on
EVERY post-claim-create exit path — claim gone or foreign at the step-3.1
recheck; step-3.2 touch failure; a step-2/3.3 abort for a fresh or changed
lock (step 4b); rename source-gone; a token-checked deletion finding a
foreign claim — first read the lock path's line 1: **our own token ⇒ we HOLD
the lock** — proceed to the acquire read-back verification; otherwise
continue with that lane's normal outcome. Cost: one extra read per abort
path, all of which already read files. This rule is what makes "no unowned
orphan" structural rather than per-lane: whichever claim file gets installed
at the lock path, its token's owner takes SOME exit path, and the discovery
read on that path finds ownership; every other party reads a foreign token
and backs off.

#### Rename-failure lanes

- **Source (claim) gone at rename** → the ownership-discovery rule (this
  lane is simply one case of the global rule): our token at the lock path →
  a rival's rename installed our claim file as the lock; token uniqueness
  makes this sound — **we HOLD the lock**; proceed to the read-back
  verification. Foreign/absent → our claim was abandoned/cleared; re-poll.

  Self-healing here is structural, not a property of this lane alone: per
  the ownership-discovery rule, whichever claim file gets installed at the
  lock path, its token's owner runs the discovery read on whatever exit
  path it happens to take (recheck-gone, touch failure, fresh-lock abort,
  this source-gone lane, or the read-back itself), and everyone else reads
  a foreign token and backs off — **no unowned orphan is possible**. That
  answers round 1's wedge scenario structurally, not probabilistically.
- **Destination wrong-type** (rename onto a directory fails) →
  `CLAIM-ABORT (rename-refused)`, token-checked claim deletion, damped
  warning, re-poll; the next poll's wrong-type guard classifies the object.
- **Rename blocked** (Windows sharing violation / a no-delete-share handle on
  the ghost — the existing blocked-steal lane) → keep today's handling:
  token-checked claim deletion, damped once-per-stale-window `steal FAILED`
  log, re-poll, honour MAX_WAIT. A failed steal must NOT cost a 60s
  claim-stale delay — the claimant deletes its own claim immediately rather
  than leaving it to age out.

### Claim staleness (the "free-for-all" backstop)

- New knob `AGENT_LOCK_CLAIM_STALE_SECS`, default **60** (claims are held for
  milliseconds; 60s says "claimant crashed").
- A claim older than the window, judged by the same mtime+floor rules, and
  **claim-shaped** (empty, or `tok.`-prefixed line 1) is unlinked by any
  waiter, which then re-races the claim create. The never-steal wrong-type
  guards (directory/symlink/FIFO/socket/device, with the two-consecutive-poll
  confirmation) apply to the claim path exactly as to the lock path — refuse +
  loud config warning, never delete what we can't identify.
- **Per-path guard state**: the wrong-type classifier's two-consecutive-poll
  confirmation state and warn-once flag are today single lock-path-shaped
  variables (`nonlock_prev`, `_LOCK_NONLOCK_WARNED`). They must become
  per-path (lock vs. claim) — a shared flag would cross-suppress the warning
  or cross-confirm the two-poll state between the two paths.
- A crashed claimant therefore delays only *steals* by ≤ the claim window;
  normal acquisition on a free path is never blocked by a claim.
- Knob relation: worst-case recovery = `AGENT_LOCK_STALE_SECS` +
  `AGENT_LOCK_CLAIM_STALE_SECS` must stay < `AGENT_LOCK_MAX_WAIT` (defaults:
  300 + 60 < 420 ✓). Warn-once at startup when `MAX_WAIT ≤ STALE +
  CLAIM_STALE`, but **only when MAX_WAIT was left at its default** — a
  caller who set both knobs chose the relationship deliberately. This new
  warning **REPLACES** the existing `STALE ≥ MAX_WAIT` warning
  (git-commit-lock.sh:296-304): it strictly subsumes it, under the same
  left-default explicitness gate. Consequence: tight-knob tests must set
  `AGENT_LOCK_CLAIM_STALE_SECS` alongside the other knobs.

### Crash-lane inventory

| Crash point | Outcome |
|-------------|---------|
| After claim create, before rename | Claim ages out (≤60s); steals resume. |
| Between claim create and content write | Empty claim file; the empty-orphan + staleness rules clear it. |
| After rename-over | Stealer is now just a normal holder that crashed; lock staleness rules apply. No grave exists at any point. |

### Residual races (all detected, none silent — replaces the wave-1 entries)

1. **verify→rename gap**: a live-slow holder releases between our re-verify
   and our rename, and a waiter's create lands in that same instant; our
   rename-over then replaces that fresh lock. The displaced winner detects via
   the acquire read-back (if still inside it) or at release (98). The window
   is a few ms; it does contain forks (the mtime stat is a command
   substitution, `mv` is an exec), but it is strictly narrower than the
   pre-wave-1 race and the same class as wave 1's unrestorable residual.
2. **recheck→rename gap**: the step-3.1 recheck bounds what a clearer can
   legitimately act on (at the recheck our claim is younger than
   CLAIM_STALE) — but a clearer whose staleness read predates the recheck
   (the touch does not defend this either) can still clear our claim and
   let a rival claim inside the recheck→rename gap. Every such two-claimant
   interleaving is **self-healing** per the ownership-discovery rule:
   exactly one claim file ends up installed, its token's owner discovers
   ownership on whatever exit path it takes, everyone else detects a
   foreign token — no unowned orphan is possible; any displacement degrades
   into the detected-98 lane. No infinite regress. (Decision: no recheck
   margin — the discovery rule makes the gap-frequency question moot.)
3. **Lease rule**: the installed lock's lease starts at the claim's
   step-3.2 touch (rename preserves mtime). A claimant suspended between
   touch and rename installs a correspondingly aged-mtime lock — the lease
   shortfall is bounded by the touch→rename gap (milliseconds when not
   suspended), not "always ~full lease".
4. **Version skew**: prevention holds only when *all* parties in a tree run
   the claim protocol. A mixed-version tree (an old stealer doing mv-to-grave)
   degrades to detection (98) and can leave grave litter the new code does not
   sweep — upgrade both implementations together (one doc line).
5. Existing residuals unrelated to stealing (release-time classification,
   delete-blocked leftovers, FILETIME-zero floor) are unchanged.

### What gets removed (precise inventory)

- Grave files, the grave naming, and the age-gated grave sweep — and with the
  sweep, unit **T15** (grave-sweep test) is deleted.
- Grave-token comparison, the `STEAL-DISPLACED-LIVE` lane, hard-link restore,
  and the wave-1 RESTORE-GRACE **outer loop** (sh ~566–573, ps1 ~644–650) —
  both impls. **KEEP** `_lock_cur_token`'s internal empty-read retry ladder
  (pre-wave-1, probe F); only the outer grace loop goes.
- Docs: the test-inventory passage (docs/git-commit-lock.md ~441–466) and the
  README recovery sentences (~67–72) both describe restore — both are
  rewritten, not just the lease sentence.
- The ps1 header's PORT-SPECIFIC hard-link probe notes (~74–91) go with the
  header rewrite.
- Wave-1 tests T2b (unit) and T16 (interop) are **kept and adapted** — they
  are the regression harness that proves the new protocol: same scenario (1
  ancient stale lock + N waiters, tight knobs), new assertions (exactly one
  steal per recovery, zero displacements, zero spurious 98s, no claim/grave
  leftovers).

## Implementation notes

### bash (`git-commit-lock.sh`)

- `mv` on the same NTFS volume maps to MoveFileEx(REPLACE_EXISTING) under
  MSYS — **probe before building**: tight reader loop asserting the lock path
  never reads absent across the replace, and content flips atomically
  ghost→ours.
- Rename-over onto a *directory* fails → the `rename-refused` lane above.
- Reuse the existing helpers: token generation, write-through-create, read
  ladder, mtime read + floor, wrong-type classifier — **parameterized by
  path, with per-path confirmation/warn-once state** (see Claim staleness).

### PowerShell (`git-commit-lock.ps1`)

- pwsh 7 / .NET Core: `[IO.File]::Move($src, $dst, $true)` (atomic overwrite
  overload) — probe on NTFS as for bash. bash keeps `mv`.
- Windows PowerShell 5.1 / .NET Framework: **no `File.Replace`** — round-1
  review showed it is unsafe here (throws on a read-only destination, and has
  partial-failure states when called without a backup file). Instead the 5.1
  steal completes as: **unlink the ghost, then `File.Move` (fail-if-exists)
  the claim in**. The transient absent window between unlink and Move is
  *safe under the claim*: a rival waiter's create landing in that window
  merely wins the lock — our Move fails-if-exists → token-checked claim
  deletion, re-poll. A fairness loss (the claimant did the recovery work and
  lost the lock), never a clobber. Ladder sub-lanes: (a) the ghost unlink
  finds the lock already gone (the live-slow holder released first) →
  `CLAIM-ABORT (gone)` for symmetry with step 4(a); do NOT proceed to the
  Move. (b) the ghost unlink is blocked by a no-delete-share handle → the
  existing damped blocked-steal lane (token-checked claim deletion, damped
  log, re-poll).
- ps1-on-POSIX residual (extends the existing PORT-SPECIFIC notes): a
  FIFO/device/socket at the **claim** path stats as size 0 there and takes the
  empty-claim clear lane — damage capped at the one misconfigured inode,
  CI-only configuration. Consequence for tests: the claim wrong-type
  "refused" assertion is bash-only.
- Keep strictly ASCII; keep 5.1-compatible syntax.

### Probes (phase 1)

- bash `mv` replace atomicity on NTFS (no-absent-window, atomic content flip).
- pwsh 7 overwrite-`Move` atomicity, same assertions.
- **Post-rename lock mtime freshness**: from bash `mv`, pwsh 7
  overwrite-Move, AND the 5.1 `File.Move` leg, confirm rename preserves the
  claim's just-touched mtime (the lease rule rides on it in all three
  lanes).
- **5.1 `File.Move` fail-if-exists atomicity** (exactly one of N concurrent
  Moves onto one destination wins).
- **`touch` semantics on the claim from both runtimes** (bash `touch -c`,
  ps1 `[IO.File]::SetLastWriteTimeUtc` catching FileNotFound): mtime visibly
  refreshed, content untouched, and **a missing target is NOT created** —
  the no-create semantics the algorithm depends on.
- (Dropped: all `File.Replace` probes.)

Abort criteria: if rename-over is not reliably atomic-no-absent-window on NTFS
from bash/pwsh 7, **or the installed lock's mtime is not the claim's fresh
mtime**, fall back to Ben's original grave variant (claim still prevents the
race; the no-absent-window and lease-touch bonuses are lost).

### Logging (design, per house rules)

To the existing lock log (same damping conventions):
- `CLAIM <path> by <owner>` on claim create.
- `CLAIM-ABORT (<reason>)` — reasons enum:
  `fresh | gone | wrong-type | rename-refused | contested`.
- `STOLE-BY-CLAIM <lockpath> ghost=<ghost line2> by <owner>` on the rename-over
  (replaces the old STOLE line). Attribution caveat: this names the last
  *verified* ghost (from the step-3.3 re-read); residual 1's verify→rename gap
  means the object actually replaced could in principle differ — the log claim
  and the residual inventory must stay consistent (no "always the true ghost /
  no displacement possible" wording).
- `CLAIM-STALE-CLEARED <path> age=<s>` when a stale claim is unlinked.
- Damping: the `rename-refused` and blocked-steal lanes use the existing
  once-per-stale-window damper; existing damping on the other contended lanes
  unchanged.

## Test plan

Unit (`git-commit-lock.test.sh`):
1. Claim contention: N concurrent stealers over one ancient ghost → exactly one
   claim winner, one `STOLE-BY-CLAIM`, N−1 `CLAIM`-failed waiters that then
   acquire normally in sequence; no leftovers.
2. Adapted T2b multi-waiter recovery: zero spurious 98s, zero displacement
   lines, clean final state (mutation check: must fail against the wave-1
   implementation — e.g. by asserting no grave file is ever created and the
   STOLE-BY-CLAIM line shape).
3. Crashed claimant: plant an aged claim file → a waiter clears it
   (`CLAIM-STALE-CLEARED`) and completes the steal; recovery latency bounded.
4. Empty claim orphan: ages out via the same lane.
5. Claim wrong-type guards: directory/symlink/FIFO at `${LOCK}.next` → refused,
   warned once (two-consecutive-poll), steals blocked, normal acquire on a
   free lock path UNaffected. (bash-only for FIFO/device/socket; see the
   ps1-on-POSIX residual note.)
6. Live-slow holder: claim + re-verify sees fresh mtime → `CLAIM-ABORT
   (fresh)`, no steal; the slow holder releases normally.
7. Knob validation: `AGENT_LOCK_CLAIM_STALE_SECS` numeric checks; the
   `MAX_WAIT ≤ STALE + CLAIM_STALE` warning fires when MAX_WAIT is default and
   stays silent when MAX_WAIT was set explicitly.
8. **Aged-claim contested abort**: suspended claimant (backdated own claim) →
   the step-3.1 recheck finds it overaged → `CLAIM-ABORT (contested)`, NO
   rename (mutation check: an implementation that proceeds on an overaged
   claim must fail this).
9. **Post-recheck claim substitution** (discovery-position matrix): a clearer
   + a rival act AFTER the claimant's recheck passes; steer the rival's
   claimant to EACH discovery position — recheck-gone, step-2-fresh,
   rename-source-gone — asserting in every case exactly one final owner,
   everyone else backs off, and no unowned lock.
10. **Delayed-claim lease**: claim aged close to CLAIM_STALE, then recovery →
    the installed lock's mtime is fresh (the step-3.2 touch), the holder gets
    a full lease.
11. **Step-4a abort-on-gone**: live-slow holder releases under a claimant →
    `CLAIM-ABORT (gone)`, NO install on the absent path (mutation check: an
    implementation that renames onto the absent path must fail this).
12. **Claim mtime floor**: a sub-floor claim mtime is NOT cleared — treated as
    just-created.
13. **Per-path guard state**: a lock-path wrong-type warning must not suppress
    a claim-path warning, and vice versa (warn-once and two-poll confirmation
    are independent per path).
14. **Blocked-steal claim cleanup**: the deterministic blocked-steal test
    gains an assertion that the claim is deleted immediately after the failed
    rename — no 60s ageout penalty.
15. **No-`File.Replace` static check**: assert `git-commit-lock.ps1` contains
    no `File.Replace` (anti-regression for the round-1-rejected primitive).

Interop (`git-commit-lock.interop.test.sh`):
16. bash claimant vs ps1 claimant racing one ghost → one winner, both sides
    parse each other's claim files (wire format), loser waits correctly.
17. Cross-impl claim-staleness agreement: each side clears the other's aged
    claim.
18. Adapted T16 (as the adapted T2b above, mixed runtimes).
19. 5.1 lane: the **unlink+`File.Move` ladder** exercised under `powershell`
    where available (skip-with-note elsewhere). The suite already has a 5.1
    smoke lane — interop Test 17, landed in `51e55a3` — hook into it.

The 5.1 absent-window fairness case (a rival's create winning inside the
unlink→Move window) is deliberately left untested — non-deterministic, and
benign by design.

Integration: unchanged scenario; the final no-leftover sweep gains `*.next`
alongside the existing no-leftover-lock check.

Tight-knob tests across all suites set `AGENT_LOCK_CLAIM_STALE_SECS` alongside
the existing knobs (the warning gate assumes coherent explicit settings).

All three suites green (REDUCED locally, FULL is CI's job), shellcheck
`-S info` (the CI gate since `51e55a3`) + PSScriptAnalyzer clean.

## Docs

- `docs/git-commit-lock.md`: rewrite the steal bullet + "The protocol in
  detail" steal/grave passages for claim+rename-over; update the residual
  inventory and the golden-rule recovery paragraph (wave-1 text); rewrite the
  test-inventory passage (~441–466); knobs table gains
  `AGENT_LOCK_CLAIM_STALE_SECS`; one version-skew line (upgrade both impls
  together).
- `README.md`: rewrite the recovery sentences in "How it works" (~67–72) —
  recovery is serialized by a claim and hands the lock to the recovering
  waiter; a clause or two, not a protocol dump.
- Both implementation headers: protocol description + residual inventory
  rewrite; the ps1 header drops the hard-link probe notes (~74–91) and gains
  the 5.1 unlink+Move lane and the claim-path POSIX residual.

## Alternatives considered

- **Ben's original (claim file + mv-to-grave + re-race)**: same prevention
  property; keeps graves, keeps the path-absent recovery window and the create
  re-race, claimant may lose the lock it recovered. Rename-over strictly
  improves on those without weakening anything identified. (Retained as the
  probe-failure fallback.)
- **Wave-1 detect+restore (currently in tree)**: repair, not prevention;
  near-certain displacement under contended recovery repaired by hard-link
  restore; three subtle mechanisms; hard-link dependency. Superseded.
- **`File.Replace` for the 5.1 lane**: rejected in round 1 — read-only
  destination throws; partial-failure states without a backup file. The
  unlink+fail-if-exists-Move ladder is safe under the claim (see notes).
- **Ticket queue** (`commit.lock.d/<ts>.<token>`, lowest non-stale ticket
  holds): no destructive steal at all, FIFO fairness — but a total wire-format
  rewrite, "lowest non-stale" must be evaluated identically across runtimes,
  and it reintroduces directory semantics + deleting-others'-files on Windows
  (delete-pending ghosts as routine). Rejected for this project's stage.

## Decisions adopted (round-1 open questions, silence = adopt)

1. Claim suffix `.next`. 2. `AGENT_LOCK_CLAIM_STALE_SECS` default 60s.
3. Knob relation: warn-once, gated on MAX_WAIT being default (not a hard
   error).

## Coordination

Waves landed since this plan was first written; the implementation builds on
them, not around them:
- Interop suite now has **Test 7b** (ps1 exit verdicts) and **Test 17**
  (Windows PowerShell 5.1 smoke lane) from `51e55a3` — the 5.1 steal-ladder
  test (item 19) hooks into Test 17's lane rather than duplicating detection.
- Integration test uses **per-worker lock logs** from `0339dbe` — new
  assertions (e.g. the `*.next` no-leftover sweep) follow that structure.
- **Wave C (read-ladder parity) landed as `d40616f`**: shared 8-attempt
  20→320ms-capped retry schedule (≈1.26s) at release/read-back only;
  sourced-outside-a-repo warns on stderr and creates no file; `--help` →
  stdout/exit 0 in both impls; the doc's ladder definition updated. The
  implementation builds on that tree state.

## Phases

1. Probes (see "Probes" above) — recorded in the changelog; abort criteria as
   stated there.
2. bash implementation + unit tests (incl. the removal inventory).
3. ps1 port + interop tests.
4. Docs + README + headers.
5. Full suites, shellcheck/PSScriptAnalyzer, review/fix cycles (fresh Claude +
   Codex) to clean.

Changelog: `.plans/2026-06-11-aa-claude-a-steal-claim-changelog.md` during
implementation.

## Review history

- **Round 1 (2026-06-11)**: two independent reviewers (fresh Claude + Codex).
  Three blocking defect families: (1) stale-claim TOCTOU / unowned-orphan
  wedge (both reviewers' top finding) → claim recheck + token-checked
  deletions + self-healing rename-failure lanes; (2) aged lease at install →
  the pre-rename claim touch + lease rule + probe; (3) `File.Replace` unsafe
  on 5.1 (Codex) → unlink+fail-if-exists-Move ladder. Plus guard/knob/logging
  /test-coverage findings (per-path guard state, claim-path pre-create type
  guard, MAX_WAIT warning gate, attribution softening, CLAIM-ABORT enum,
  six test additions, precise removal inventory, version-skew note,
  coordination with `51e55a3`/`0339dbe`). All folded into v2.
- **Round 2 (2026-06-11)**: fresh Claude (2 blocking + 6 non-blocking) +
  Codex (0 blocking + 3 non-blocking); all folded into v3. Blocking family —
  make self-healing structural: (1) v2 wired own-token discovery into only
  the rename-source-gone lane, leaving three of the four positions a
  claimant can occupy when a rival's rename installs its claim (recheck-gone,
  step-2/3.3 fresh-abort, touch-target-gone) to orphan an own-token lock for
  a full STALE window → the global ownership-discovery rule on every
  post-claim-create exit path; (2) a creating `touch` would resurrect a
  vanished claim as an empty `${LOCK}.next` blocking all steals and masking
  the gone signal → non-creating touch (`touch -c` /
  `SetLastWriteTimeUtc`+FileNotFound). Non-blocking: residual/lease wording
  accuracy (recheck + discovery rule bound things, not the touch; lease
  shortfall bounded by the touch→rename gap), deletion-gap note, 5.1 ladder
  sub-lanes (unlink-finds-gone → `CLAIM-ABORT (gone)`; unlink-blocked →
  damped blocked-steal lane) + 5.1 `File.Move` mtime-probe leg, test-plan
  splits/additions (contested abort vs. discovery-position matrix,
  blocked-steal cleanup assertion, no-`File.Replace` static check, untested
  5.1 fairness note), stale shellcheck parenthetical dropped, MAX_WAIT
  warning stated as replacing the STALE≥MAX_WAIT warning, wave-C
  (`d40616f`) coordination.
