# Plan: de-flake unit Test 31(a) (leaked-claim discovery-route race) under load

Status: **DONE** — diagnosis converged across 4 independent reviews (my code-read +
leak.log + a fresh-context Claude subagent that did NOT read the prior diagnosis + Codex
foreign-model review); fix implemented; implementation reviewed clean (see changelog).
Test-only change; product untouched. Awaiting CI-under-load confirmation.

## Reviewer notes (top; do not renumber)
_(none yet)_

## Context
CI stress under both/load=2 (moderate, 4 hogs on a 4-core ubuntu runner — NOT the
8-hog oversubscription regime) failed ONE assertion in unit **Test 31 sub-leg (a)**
(`tests/git-commit-lock.test.sh:1582`), run 27626826865:
```
FAIL: no leaked-token-memory DISCOVERY-HOLD
```
Every other (a) assertion passed (recheck-unreadable feeder fired; rc 0; lock released
cleanly; no claim/lock leftover); sub-legs (b)(c)(d) passed.

### Mechanism (test-orchestration race; product correct)
The product has TWO valid, equally-correct ways to adopt a leaked claim that a rival has
installed at the lock path, and both log a `DISCOVERY-HOLD` line:
- **D1 — inline ownership-discovery read.** `_lock_discover` (`git-commit-lock.sh:819`,
  log at `:822` `DISCOVERY-HOLD: our claim ... installed ... by a rival's rename`) is the
  unconditional final act of every post-claim non-rename exit. In (a) the steered
  recheck-unreadable exit runs `_lock_leaked_add` (`:1112`, the `LEAKED-CLAIM` log) and
  then **immediately, one statement later**, `_lock_discover "$tok"` (`:1114`).
- **D2 — per-poll leaked-token-memory check.** `git-commit-lock.sh:1382`
  (`DISCOVERY-HOLD (leaked-token memory): ...`) fires on a LATER blocked poll while the
  memory list is non-empty.

Sub-leg (a)'s harness is open-loop: it `wait_for_grep`s the `LEAKED-CLAIM` line
(`:1574`) then does `mv -f -- "$LOCK.next" "$LOCK"` (`:1576`, the rival install). That
`mv` races the leaver's inline `_lock_discover` at `:1114`:
- mv lands **before** the inline discover → **D1** wins (the `:822` line). ← failing run
- mv lands **after** the inline discover (it misses; later poll) → **D2** wins (`:1382`).

The assertion at `:1582` hard-pins **D2** (`grep -q "DISCOVERY-HOLD (leaked-token
memory)"`). Under load the leaver was descheduled between `:1112` and `:1114`, the
harness `mv` landed first, D1 fired, D2 never logged → the assertion failed. The product
behaved correctly in BOTH cases (token remembered, same token observed installed,
adopted, rc 0, clean release, no residue). Classification: **test flake, product
correct** — the assertion over-specified an implementation-incidental, scheduler-chosen
route rather than the contract (a leaked claim installed by a rival is adopted and
cleaned up).

### Coverage (why relaxing (a) loses nothing)
- **D2 (memory route)** is covered DETERMINISTICALLY by **sub-leg (b)** (`:1592-1627`):
  it drives the rival install from inside `_lock_new_token` at NTC=2 so the leaver runs a
  full aborting claim attempt and adopts only on the per-poll memory check; it asserts
  `DISCOVERY-HOLD (leaked-token memory)` and the `leak < abort < adoption` ordering.
- **D1 (direct route)** is covered DETERMINISTICALLY by **Test 25** (`:1323-1425`), the
  discovery-position matrix: 7 internally-steered positions, each asserting the generic
  `grep -q "DISCOVERY-HOLD"` + rc 0 + no orphan. (Test 25 already uses the generic grep
  idiom this fix adopts for (a).)

So (a)'s distinct, irreplaceable job is the END-TO-END "external rival installs a
recheck-unreadable leaked claim → adopted & cleaned up" scenario, where either route is a
correct outcome.

## Fix (Option A — accept either discovery route; recommended by all four reviews)
Test-only, in `tests/git-commit-lock.test.sh` sub-leg (a):
1. Replace the single D2-pinning assertion (`:1582-1583`) with a three-way check that
   accepts EITHER route, records WHICH fired (telemetry for the load hunt), and only
   fails if NEITHER `DISCOVERY-HOLD` route adopted the claim:
   ```sh
   if grep -q "DISCOVERY-HOLD (leaked-token memory)" "$LOG"; then
     ok "... per-poll memory route ..."
   elif grep -q "DISCOVERY-HOLD:" "$LOG"; then
     ok "... inline direct-discovery route ... (memory route pinned by sub-leg (b)) ..."
   else
     bad "no DISCOVERY-HOLD adoption of the leaked claim by EITHER route"
   fi
   ```
   `"DISCOVERY-HOLD:"` (immediate colon) matches ONLY D1; D2's text is
   `DISCOVERY-HOLD (leaked-token memory):` (space+paren after the dash), so the two
   patterns are disjoint and D2 is checked first regardless.
2. Update sub-leg (a)'s header comment (`:1550-1552`) to state honestly that adoption may
   go through either route, that the choice is a load-sensitive scheduling race, and that
   the memory route is pinned deterministically by (b) and the direct route by Test 25.

### Why A (not B/C)
- **A** matches (a)'s real intent; not vacuous — still requires the recheck-unreadable
  feeder (`:1574`), rc 0 (`:1581`), clean release + no leftover (`:1584-1585`), AND a
  `DISCOVERY-HOLD` adoption (the log line only appears when `_lock_take_hold` runs via a
  discovery path). No new timing introduced. Keeps (a) as the load-tolerant main leg.
- **B** (force the memory route via internal steering) duplicates (b).
- **C** (force the direct route) duplicates Test 25; also `_lock_discover` direct
  coverage is already comprehensive there. (NB: the subagent's specific C steering — do
  the mv inside the fire-once read shadow before returning empty — would actually
  mis-classify the claim as `gone` not `unreadable`, killing the leak feeder; another
  reason to avoid C. Verified against `_lock_claim_state`, `git-commit-lock.sh:840-850`.)

## Out of scope / NOT changed
- Product code (`git-commit-lock.sh`, `.ps1`) — no defect.
- Sub-legs (b)(c)(d), Test 25, any other test.

## Logging
No product logging change. The new three-way `ok` line records which discovery route
adopted the claim each run — a small telemetry win making the previously-hidden route
choice visible in every (a) run's output (helps confirm load is exercising both routes).

## Testing
1. Static: `bash -n` + `shellcheck -S style` (v0.11.0, the CI gate) on the test file.
2. Local: run the unit suite on this box; Test 31 (all sub-legs) must pass; confirm the
   new `ok` line reports a route. Run Test 31 in a loop to confirm no regression.
3. Real proof: CI under both/load=2 where (a) previously failed — the unit leg must stay
   green and report a route each run.

## Changelog (implementation)
- Implemented Fix A in `tests/git-commit-lock.test.sh` sub-leg (a): the single
  D2-pinning assertion became a three-way `if/elif/else` (memory route → ok; direct route
  via `grep "DISCOVERY-HOLD:"` → ok; neither → bad). Rewrote (a)'s header comment to
  document both routes, the load-sensitive race, and the deterministic coverage of each
  (sub-leg (b) for memory, Test 25 for direct). No product code, no other test touched.
- Static: `bash -n` + `shellcheck -S style` (v0.11.0, the CI gate) clean.
- Local (Windows MSYS bash, pwsh 7.5.5): full unit suite **207 passed / 0 failed**
  (fan-out auto-REDUCED under the box load). Sub-leg (a) passed via the memory route on
  this UNLOADED box (`adoption went through the leaked-token memory (per-poll route ...)`),
  confirming the normal path still fires and the new assertion accepts it; (b)(c)(d) green.
- Diagnosis review (4 independent, all converged: test flake / product correct / Fix A):
  my code-read + the verbatim leak.log, a fresh-context Claude subagent that did NOT read
  the prior diagnosis, and a Codex foreign-model review. Codex additionally noted D1 is
  already covered by Test 25's discovery-position matrix → option C (a new D1 sub-leg) is
  redundant. (I verified Test 25 covers all 7 positions deterministically myself.)
- Implementation review (2 independent, both clean / no findings): a fresh Claude reviewer
  ("the change is correct ... no defect found") and Codex `exec` read-only ("None. The fix
  is correct."). Both verified: grep patterns disjoint (BRE parens literal; `DISCOVERY-HOLD:`
  needs an immediate colon, absent from the memory line), non-vacuity (a `DISCOVERY-HOLD`
  line is logged one statement before the pure-assignment `_lock_take_hold`, so it reliably
  implies a taken hold; backstopped by rc 0 + no-leftover + the feeder assertion), no new
  race (greps run only after `wait "$w31"`), `$LOG` leg-dedicated (no cross-talk), and the
  comment's sh:822/1382/1112/1114 line refs accurate.
- Real proof pending: CI under both/load=2 where (a) previously failed (run 27626826865).
