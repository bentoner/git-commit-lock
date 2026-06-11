# Plan: claim-serialized stealing (claim-is-the-next-lock + atomic rename-over)

Status: DRAFT — awaiting review (Codex + fresh Claude review/fix cycles to clean).

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
and no path-absent window. See "Alternatives considered".

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
identically.

### Steal algorithm (replaces the current steal lane in both impls)

When a poll judges the lock stale (existing rules: regular file, lock-shaped
content, plausible mtime ≥ floor, age > `AGENT_LOCK_STALE_SECS`):

1. **Claim**: O_EXCL-create `${LOCK}.next` with our token.
   - Create fails because a claim exists → someone else is stealing; fall
     through to the claim-staleness check (below), then keep waiting.
2. **Re-verify under the claim**: re-read the lock fresh (content + mtime +
   floor + shape).
3. **Still stale** → `mv ${LOCK}.next ${LOCK}` (atomic rename-over: ghost
   destroyed + our live lock installed in one operation). Then run the existing
   acquire read-back verification (must find our own token) — kept as
   defense-in-depth even though the claim makes a same-instant rival steal
   impossible.
4. **Not confirmed** → delete our claim and keep waiting. Two sub-cases:
   - (a) lock **gone** (the "stale" holder was live-slow and released, or
     another mutation): do NOT rename onto the now-absent path — that lane
     belongs to the normal create race and renaming there could clobber a
     rival's fresh create. Delete claim, re-race the normal create.
   - (b) lock **fresh** (mtime renewed / different token): delete claim,
     continue waiting.

### Claim staleness (the "free-for-all" backstop)

- New knob `AGENT_LOCK_CLAIM_STALE_SECS`, default **60** (claims are held for
  milliseconds; 60s says "claimant crashed").
- A claim older than the window, judged by the same mtime+floor rules, and
  **claim-shaped** (empty, or `tok.`-prefixed line 1) is unlinked by any
  waiter, which then re-races the claim create. The never-steal wrong-type
  guards (directory/symlink/FIFO/socket/device at the claim path, with the
  two-consecutive-poll confirmation) apply to the claim path exactly as to the
  lock path — refuse + loud config warning, never delete what we can't
  identify.
- A crashed claimant therefore delays only *steals* by ≤ the claim window;
  normal acquisition on a free path is never blocked by a claim.
- Knob relation (documented + validated like the existing numeric knobs):
  worst-case recovery = `AGENT_LOCK_STALE_SECS` + `AGENT_LOCK_CLAIM_STALE_SECS`
  must stay < `AGENT_LOCK_MAX_WAIT` (defaults: 300 + 60 < 420 ✓).

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
   the acquire read-back (if still inside it) or at release (98). Window is a
   few ms with no fork inside it (bash: stat → mv) — strictly narrower than the
   pre-wave-1 race and the same class as wave 1's unrestorable residual.
2. **stale-claim unlink TOCTOU**: a waiter unlinks a claim it judged stale just
   as the claimant (long-suspended) proceeds; two claimants can then exist and
   the second rename-over displaces the first's lock — detected exactly as (1).
   One recursion level; consequences degrade into the detected-98 lane, so
   there is no infinite regress.
3. Existing residuals unrelated to stealing (release-time classification,
   delete-blocked leftovers, FILETIME-zero floor) are unchanged.

### What gets removed (wave-1 and pre-wave-1 machinery)

- Grave files, the grave naming, the age-gated grave sweep.
- Grave-token comparison, `STEAL-DISPLACED-LIVE` lane, hard-link restore,
  restore grace (both impls).
- Doc/README passages describing restore; residual entries superseded by the
  list above.
- Wave-1 tests T2b (unit) and T16 (interop) are **kept and adapted** — they are
  the regression harness that proves the new protocol: same scenario (1 ancient
  stale lock + N waiters, tight knobs), new assertions (exactly one steal per
  recovery, zero displacements, zero spurious 98s, no claim/grave leftovers).

## Implementation notes

### bash (`git-commit-lock.sh`)

- `mv` on the same NTFS volume maps to MoveFileEx(REPLACE_EXISTING) under
  MSYS — **probe before building**: tight reader loop asserting the lock path
  never reads absent across the replace, and content flips atomically
  ghost→ours.
- Rename-over onto a *directory* fails (fail-safe for a wrong-type object that
  appeared at the lock path after re-verify); handle the error by deleting our
  claim and re-polling (the wrong-type guard will classify next poll).
- Reuse the existing helpers: token generation, write-through-create, read
  ladder, mtime read + floor, wrong-type classifier (parameterize by path).

### PowerShell (`git-commit-lock.ps1`)

- pwsh 7 / .NET Core: `[IO.File]::Move($src, $dst, $true)` (overwrite
  overload) — probe atomicity on NTFS as for bash.
- Windows PowerShell 5.1 / .NET Framework has no overwriting Move:
  `[IO.File]::Replace($src, $dst, $null)` when the destination exists, falling
  back to `Move` on FileNotFoundException (destination vanished = released
  meanwhile — but per step 4a we *abort* rather than install on an absent path,
  so the fallback lane should delete the claim and re-poll; spell this out in
  code). Probe `Replace` semantics (atomic on same NTFS volume; it must not
  leave a window where the path is absent).
- Keep strictly ASCII; keep 5.1-compatible syntax.

### Logging (design, per house rules)

To the existing lock log (same damping conventions):
- `CLAIM <path> by <owner>` on claim create; `CLAIM-ABORT (<reason: fresh|gone|wrong-type>)` on step 4.
- `STOLE-BY-CLAIM <lockpath> ghost=<ghost line2> by <owner>` on the rename-over
  (replaces the old STOLE line; always attributes the true ghost — we hold its
  identity from the verified re-read, and no displacement is possible).
- `CLAIM-STALE-CLEARED <path> age=<s>` when a stale claim is unlinked.
- Existing once-per-window damping applies to the contended lanes.

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
   free lock path UNaffected.
6. Live-slow holder: claim + re-verify sees fresh mtime → CLAIM-ABORT, no
   steal; the slow holder releases normally.
7. Knob validation: `AGENT_LOCK_CLAIM_STALE_SECS` numeric checks; the
   MAX_WAIT > STALE+CLAIM_STALE relation warning (if we adopt one — decide:
   warn, don't fail).

Interop (`git-commit-lock.interop.test.sh`):
8. bash claimant vs ps1 claimant racing one ghost → one winner, both sides
   parse each other's claim files (wire format), loser waits correctly.
9. Cross-impl claim-staleness agreement: each side clears the other's aged
   claim.
10. Adapted T16 (as T2b above, mixed runtimes).
11. 5.1 lane: the rename-over/Replace ladder exercised under `powershell` where
    available (skip-with-note otherwise) — coordinates with the parallel
    finding-3 work; whichever lands second wires the 5.1 smoke into these.

Integration: unchanged scenario; assert no `*.next` leftovers in the final
sweep alongside the existing no-leftover-lock check.

All three suites green (REDUCED locally, FULL is CI's job), shellcheck
`-S warning` (or `-S info` once the parallel CI bump lands) + PSScriptAnalyzer
clean.

## Docs

- `docs/git-commit-lock.md`: rewrite the steal bullet + "The protocol in
  detail" steal/grave passages for claim+rename-over; update the residual
  inventory and the golden-rule recovery paragraph (wave-1 text); knobs table
  gains `AGENT_LOCK_CLAIM_STALE_SECS`.
- `README.md`: the lease sentence in "How it works" — recovery is serialized
  by a claim and hands the lock to the recovering waiter; one clause, not a
  protocol dump.
- Both implementation headers: protocol description + residual inventory
  rewrite.

## Alternatives considered

- **Ben's original (claim file + mv-to-grave + re-race)**: same prevention
  property; keeps graves, keeps the path-absent recovery window and the create
  re-race, claimant may lose the lock it recovered. Rename-over strictly
  improves on those without weakening anything identified.
- **Wave-1 detect+restore (currently in tree)**: repair, not prevention;
  near-certain displacement under contended recovery repaired by hard-link
  restore; three subtle mechanisms; hard-link dependency. Superseded.
- **Ticket queue** (`commit.lock.d/<ts>.<token>`, lowest non-stale ticket
  holds): no destructive steal at all, FIFO fairness — but a total wire-format
  rewrite, "lowest non-stale" must be evaluated identically across runtimes,
  and it reintroduces directory semantics + deleting-others'-files on Windows
  (delete-pending ghosts as routine). Rejected for this project's stage.

## Phases

1. Probes (MSYS `mv` replace atomicity; ps1 `Move`/`Replace` semantics incl.
   5.1) — recorded in the changelog; abort criteria: if rename-over is not
   reliably atomic-no-absent-window on NTFS from either runtime, fall back to
   Ben's original grave variant (claim still prevents the race; only the
   no-absent-window bonus is lost).
2. bash implementation + unit tests (incl. removal of wave-1 machinery).
3. ps1 port + interop tests.
4. Docs + README + headers.
5. Full suites, shellcheck/PSScriptAnalyzer, review/fix cycles (fresh Claude +
   Codex) to clean.

Changelog: `.plans/2026-06-11-aa-claude-a-steal-claim-changelog.md` during
implementation.

## Open questions (recommendations inline; silence = adopt)

1. Claim suffix: `.next` (recommended — says what it becomes) vs `.steal`.
2. `AGENT_LOCK_CLAIM_STALE_SECS` default 60s (recommended) vs 300s (symmetric
   but doubles worst-case recovery).
3. MAX_WAIT relation: warn-once at startup when
   `MAX_WAIT ≤ STALE + CLAIM_STALE` (recommended) vs hard usage error.
