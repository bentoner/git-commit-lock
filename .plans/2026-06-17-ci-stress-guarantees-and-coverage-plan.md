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

## Proposed workflow (our usual approach: spec → plan → implement → review)

Each phase ends with **Claude + Codex review rounds to convergence** and a **Ben gate**.
Test execution is **CI-only** throughout.

**Phase 1 — Spec.** Write the Bucket-1 guarantees/scope spec + the precise operating
envelope. Review (Claude + Codex) against the code and `failure-modes.md`. → Ben approves the
spec before any implementation. (This is where the new doc Ben asked for gets created.)

**Phase 2 — Plan.** A concrete implementation plan for Buckets 2-4: per-test injection method
(tmpfs / `ulimit` / chmod) + platform guard + CI wiring; the exact doc edits; the test-bound
scoping approach (per D-c). Include a logging/observability note (what each new test asserts
in the logs). Record in `.plans/`, review (Claude + Codex). → Ben approves the plan.

**Phase 3 — Implementation.** Build the fault-injection tests (Bucket 2), apply the doc edits
(Bucket 3), scope the wall-clock bounds (Bucket 4). Commit incrementally under the
commit-lock. **Verify via CI** (dispatch `tests.yml` on `ci-stress`) — never locally.

**Phase 4 — Review.** Review the diff (Claude + Codex); run the full suite via CI **under the
stress load wrapper** to confirm (a) the new tests pass and are non-flaky, and (b) the scoped
bounds stop Test 21/22a/29 flaking at extreme load while keeping correctness strict. Iterate
to clean. → Ben's final review.

**Execution mechanics (open decision D-e):** run the phases by hand (subagent review rounds as
this session has been doing), or drive Phases 3-4 with a Claude Code **Workflow** (multi-agent
fan-out — one agent per test lane, adversarial verify, etc.)? (Recommend: hand-run Phase 1-2;
consider a Workflow for Phase 3-4 if the test count grows. Your call.)

## Decisions I need from Ben (summary)
- **D-a:** new `docs/guarantees.md` vs a section in the design doc. (rec: new doc)
- **D-b:** test scope — §4.5 set + E3 now, defer #7/#8? (rec: F4/F2/J1/F3 first; F1/E3/#7/#8 second tier)
- **D-c:** scope test bounds by relaxing numbers vs a correctness/envelope test split. (rec: split)
- **D-d:** keep on `ci-stress` + cherry-pick later vs clean branch now. (rec: ci-stress)
- **D-e:** hand-run vs Workflow for Phase 3-4. (rec: hand-run 1-2, decide later for 3-4)

## Out of scope for this plan
- Anything the design already rejected (heartbeat, two-rename CAS, `File.Replace`, supporting
  network FS) — see `failure-modes.md` §4 "Things explicitly NOT to do".
- No product *behavior* changes are implied by any of the above — these are tests + docs +
  test-bound scoping. (If a new test surfaces a real product bug, that's a separate loop.)
