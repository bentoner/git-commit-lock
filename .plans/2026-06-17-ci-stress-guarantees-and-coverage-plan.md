# Plan proposal: guarantees spec + close the failure-modes follow-ups

Status: **PROPOSAL — awaiting Ben's review.** No implementation until approved.
This is the action list + proposed workflow Ben asked for after the `/c` pass on
`docs/failure-modes.md` (his comments converged at commit a5df9d9; recorded 534a0073).

## Where this comes from
`docs/failure-modes.md` is the **analysis / decision-support** doc (current behavior,
3-tier classification, recommendations). Ben has now decided on its §4 (agree, with two
overrides). The follow-ups below turn those decisions into work, and add the new doc Ben
asked for: a **normative spec** ("what we guarantee / what's out of scope") — distinct from
the analysis doc.

## Action list (requirements / things to do)

### Bucket 1 — NEW normative guarantees spec (Ben's explicit ask)
- **A1.** Create a normative spec doc — *what the tool guarantees* and *what is out of
  scope* — derived from `failure-modes.md`'s tiers but written as a contract, not analysis.
  - Guarantees: the Tier-1 **safety** properties (no silent lost update given cooperative
    unwind; strict mutual exclusion within the staleness window; no corruption) and the
    Tier-1 **recovery** properties (lock-shaped orphans reclaimed), each with their stated
    conditions/envelope.
  - Out of scope: network/shared FS, multi-host/clock-skew, mixed-version trees,
    ps1-on-POSIX, the non-unwinding-exit boundary (§H4) — the documented boundaries.
  - Defines the **operating envelope** precisely (the load/timing envelope from §4.1) — the
    reference Bucket 4 scopes tests against.
  - *Open decision D-a:* location/name — `docs/guarantees.md` (new), or a normative section
    inside `docs/git-commit-lock.md`? (Recommend a dedicated `docs/guarantees.md` — a crisp
    contract is easier to point users/CI at than a section.)

### Bucket 2 — Test coverage for the untested-but-robust lanes (§4.5, Ben's override)
Decision (Ben): tested edge cases > reasoned-correct-but-untested. Add deterministic,
**portable**, fault-injection tests; flag any lane that can't be injected portably rather
than shipping a flake. **All test execution via CI** (local runs are banned — they lag
Ben's box).
- **B-F4.** Unwritable lock dir/parent → clean 97 (cheapest, highest-value; `chmod`).
- **B-F2/J1.** Unwritable / failing log path → lock still works, the log write is swallowed.
- **B-F1.** ENOSPC during claim/lock create+write (small dedicated tmpfs or quota).
- **B-F3.** FD exhaustion via `ulimit -n` (portable); inode exhaustion only if cleanly
  injectable.
- **B-E3 (candidate).** mtime probe unreadable → staleness-detection-disabled, fail-safe
  (no steal), 97 + the once-per-process warning. (Also a ○ untested lane; fits the same
  decision — include unless Ben says skip.)
- *Open decision D-b:* scope — just the §4.5 set (F1-F4, J1) + E3, or also fold in the two
  **deferred F2-audit gaps**: #7 wrong-type object appearing *at the lock path mid-steal*
  (A2/G2 — `CLAIM-ABORT (wrong-type)`/`(rename-refused)`), and #8 the Windows-only
  blocked-unlink legs? (Recommend: do F4/F2/J1/F3 now; treat F1-ENOSPC, E3, and #7/#8 as a
  second tier to confirm.)
- Platform reality: several lanes are POSIX-only (tmpfs, `ulimit`, chmod semantics) — guard
  by platform like the existing suite does; Windows-specific lanes (no-delete-share) already
  have their own gated tests.

### Bucket 3 — Documentation gaps (all "document" decisions: §4.1-4.3, §4.6, §I2)
- **C-envelope (§4.1).** Document the load/timing envelope in `docs/git-commit-lock.md`:
  "correctness is load-independent; wall-clock bounds (recovery latency, MAX_WAIT, the read
  ladder) are best-effort and scale with scheduling."
- **C-clock (§4.2).** One sentence: the tool assumes a single time source (single-host, or a
  shared FS with one server clock); a local clock jump is correctness-safe.
- **C-netfs (§4.3).** Surface the network/shared-FS boundary in `README.md` (document-only,
  **no** FS-type probe).
- **C-mixedver (§I2).** Add the "upgrade both implementations together" note to `README.md`
  (currently design-doc-only).
- **C-misc (§4.6, optional).** One-line each for mixed-version + case-insensitive FS in the
  design doc.

### Bucket 4 — Scope the wall-clock test bounds (§4.1 — the Test 21/22a resolution)
- **S1.** Relax / scope the wall-clock assertions that flake only under extreme artificial
  load — **Test 21** (≤20s recovery), **Test 22a** (claim-warning timing), **Test 29**
  (≥2-CLAIM poll count) — to the envelope Bucket 1 defines, so the protocol's correctness
  assertions in those tests stay strict while the latency/poll-count bounds get headroom (or
  are gated to a defined load level). *Depends on Bucket 1's envelope.*
- *Open decision D-c:* relax the numbers in place, or split the suite into a
  "correctness" tier (always strict) and a "latency/envelope" tier the extreme-stress runs
  don't hard-fail on? (Recommend the latter — it makes the envelope explicit and stops
  future stress runs re-raising these as "flakes".)

### Bucket 5 — Branch hygiene (standing, NOT part of this workflow unless wanted)
- The mergeable commits (the 4 test fixes 58c3741/06c6d8e/51a1753/19a28fd + the docs) vs the
  **stress-only, do-not-merge** commits (980856b concurrency tweak, b430d73 load wrapper).
  When this lands on `main`, cherry-pick the mergeable set and leave the stress scaffolding.
  *Open decision D-d:* do this work on `ci-stress` and cherry-pick later, or branch a clean
  `failure-modes` off `main` now? (Recommend: keep working on `ci-stress`; cherry-pick at the
  end — the stress wrapper is useful for CI-verifying the new tests under load.)

### Bucket 6 — Principled load-&-matrix testing STRATEGY (Ben "f", 2026-06-17) — RECOMMENDATION DOC, not code
The current load injection (`tests/with-load.sh`: N CPU spin-loops + N disk write/fsync/delete
loops) was thrown together from a few lines of discussion. Ben wants a **considered,
first-principles rethink** — explicitly **not anchored on the existing approach** — whose
**deliverable is a recommendation doc for Ben, NOT an implementation.** Scope:
- **Is the load injection right?** From first principles: which KINDS of load actually stress
  *this* tool's timing-critical windows (claim→rename, read-back, discovery, mtime/staleness,
  fsync durability, scheduler preemption at critical points)? Are CPU-spin + disk-fsync the
  right proxies, or are better mechanisms warranted (cgroup CPU throttling, `taskset`/`nice`,
  `ionice`, `stress-ng` stressors, FUSE/FS-latency injection, memory pressure)? Faithfulness,
  reproducibility, and calibration (load relative to runner core count).
- **Expand the CI matrix** on free public GitHub runners: run the suite across
  {OS} × {load level} × {load kind} × {config} in parallel. How many cells is *considered* vs
  *blowing it up* — diminishing returns, signal-per-cell, GitHub concurrency limits, a small
  per-PR tier vs a larger nightly tier.
- **Get more from EXISTING tests, routinely:** parametrize the fan-out/timing tests across
  waiter counts and knob values (STALE / CLAIM_STALE / POLL / MAX_WAIT) so each run exercises
  more surface — without adding flakiness. Which tests benefit most.
- **Considered, not maximalist:** principles for choosing the matrix + a routine cadence.
Output: `docs/load-testing-strategy.md` (recommendation). Runs EARLY (Phase 1b) because it
shapes Buckets 2 & 4 and the Phase-2 plan.

## Workflow (settled: spec → plan → implement → review)

Each phase ends with **Claude + Codex review rounds to convergence** and a **Ben gate**.
Test execution is **CI-only** throughout (local runs lag Ben's box).

**Phase 1a — Guarantees spec.** Write `docs/guarantees.md` (D-a) — what we guarantee / what's
out of scope, as a normative contract + the precise operating envelope. Review (Claude +
Codex) against the code + `failure-modes.md`. → Ben gate.

**Phase 1b — Load-&-matrix testing STRATEGY recommendation (Bucket 6 / Ben "f").** Run a
considered, first-principles process (parallel research agents on distinct facets: the tool's
timing-window→load-type mapping + critique of the current wrapper; CI-matrix design on free
runners; existing-test parametrization), synthesize into `docs/load-testing-strategy.md`,
review (Claude + Codex). **Recommendation only — NO implementation.** → Ben reviews; his chosen
recommendations feed Phase 2. Runs early because it shapes Buckets 2 & 4. (1a and 1b are
independent and can run in parallel.)

**Phase 2 — Plan.** Concrete implementation plan for Buckets 2-4, incorporating Ben's chosen
load/matrix recommendations: per-test injection method (tmpfs / `ulimit` / chmod) + platform
guard + CI wiring; the matrix/parametrization to adopt; exact doc edits; the
correctness/envelope test split (D-c); a logging/observability note. Record in `.plans/`,
review. → Ben gate.

**Phase 3 — Implementation.** Build the fault-injection tests (Bucket 2, tiered per D-b), apply
the doc edits (Bucket 3), scope the wall-clock bounds + split the tiers (Bucket 4 / D-c), wire
the agreed CI matrix (Bucket 6). Commit incrementally under the commit-lock. **Verify via CI**
(dispatch `tests.yml` on `ci-stress`) — never locally.

**Phase 4 — Review.** Review the diff (Claude + Codex); run the full suite via CI **across the
agreed matrix** to confirm new tests pass + are non-flaky, the scoped bounds hold, and the
matrix surfaces no new flakes. Iterate to clean. → Ben's final review. Then (D-d) cherry-pick
the mergeable commits to `main`.

## Decisions (settled 2026-06-17)
- **D-a → new `docs/guarantees.md`** (dedicated normative doc).
- **D-b → accept rec:** F4 / F2-J1 / F3 first tier; F1-ENOSPC, E3, and the deferred F2-audit
  gaps (#7 wrong-type-mid-steal, #8 Windows blocked-unlink) as a second tier.
- **D-c → split the suite** into a strict-correctness tier (always enforced) and a
  latency/envelope tier (not hard-failed by extreme-stress runs).
- **D-d → keep on `ci-stress`**, cherry-pick the mergeable commits to `main` at the end.
- **D-e → my choice:** hand-run Phases 1-2; decide Phase 3-4 (hand vs Workflow) once the
  test/matrix count is known.
- **"f" → Bucket 6**, above: a considered, first-principles load-&-matrix testing
  **recommendation doc** (not implementation), run early as Phase 1b.

## Out of scope for this plan
- Anything the design already rejected (heartbeat, two-rename CAS, `File.Replace`, supporting
  network FS) — see `failure-modes.md` §4 "Things explicitly NOT to do".
- No product *behavior* changes are implied by any of the above — these are tests + docs +
  test-bound scoping. (If a new test surfaces a real product bug, that's a separate loop.)
