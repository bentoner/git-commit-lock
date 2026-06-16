# Plan: cover F2 — steal rename WON but read-back verification FAILED (coverage gap)

Status: **DONE** — implemented; reviewed clean (see changelog). Test-only addition; product
untouched.

## Reviewer notes (top; do not renumber)
_(none yet)_

## Context
A coverage audit (subagent + my own verification against the code) found that the product's
two acquire read-back-verification failure lanes are asymmetrically covered:
- **Create path (outcome I)** — `git-commit-lock.sh:1354-1360`: O_EXCL create wins, the path
  read-back ≠ our token → `WARNING: acquire verification FAILED — create won but read-back
  found ...` → re-enter wait. **Covered** by Test 32 (`tests/git-commit-lock.test.sh:1760`),
  whose `_lock_cur_token` shadow is gated `[ -z "$_LOCK_CLAIM_TOKEN" ]` (fires only at the
  create read-back).
- **Steal path (outcome F2)** — `git-commit-lock.sh:1168-1179`: the stealer WON the claim
  race AND won the rename-over (`STOLE-BY-CLAIM` already logged, ghost destroyed), but the
  post-rename read-back ≠ our token → `WARNING: acquire verification FAILED — steal rename
  completed but read-back found ...` → clear `_LOCK_CLAIM_TOKEN`, return 1, re-enter wait.
  **UNCOVERED.** Verified: no test greps the F2 string; Test 32's gate excludes it (at the
  steal read-back `_LOCK_CLAIM_TOKEN` is set); on the success-rename path `:1171` is the only
  `_lock_cur_token` call with the claim token set (`_lock_rename_over` `:961-979` makes none).

F2 is the higher-stakes twin: it fires AFTER `STOLE-BY-CLAIM` (ghost already destroyed), so a
future regression here (wrongly taking the hold on a mismatched read-back, or failing to clear
`_LOCK_CLAIM_TOKEN`) would be a silent false-hold / mis-attributed release. The code reads
correctly today — this is a missing-test (regression exposure), not a present bug.

The suite's closing NOTE (`:2119-2121`) says "lock_acquire's read-back-verification failure
lane … not suite-covered", but Test 32 already covers the create lane — the note is stale and
does not distinguish F2.

## Change (test-only)
1. Add **Test 32b** immediately after Test 32, mirroring Test 32 with the INVERSE token gate
   so the fault injection lands at the STEAL read-back:
   - Set up a stale ghost (`fabricate_lock` + `backdate 9999`) so a steal is attempted.
   - In a sourced subshell, `clone_fn _lock_cur_token _ct_orig`; shadow it to fire ONCE
     (flag FILE `$SF1`, subshell-safe) when `[ ! -e "$SF1" ] && [ "${_LOCK_HELD:-0}" = 0 ]
     && [ -n "$_LOCK_CLAIM_TOKEN" ]` — i.e. at the steal read-back (`:1171`), where the claim
     token is set and the hold is not yet taken. On firing: `backdate "$AGENT_LOCK_PATH"
     9999` (so the just-installed abandoned lock is immediately re-stealable — same trick as
     Test 32, keeps it fast/deterministic), `printf ""` (blank read-back → F2), `return 0`.
   - `lock_acquire || exit 72; lock_release || exit 74; exit 0`.
   - Flow: attempt 1 — claim won, rename won (`STOLE-BY-CLAIM`), read-back blanked → F2
     WARNING → re-enter wait; the abandoned lock is stale → attempt 2 steals it, read-back now
     real (SF1 set) → HOLD → `ACQUIRED` → release rc 0.
   - Assertions: rc 0; the **F2-specific** string `steal rename completed but read-back`
     fired (else `bad "F2 lane never ran"` — guards vacuity / proves the steering reached
     `:1171`); the WARNING precedes the final `ACQUIRED` (no false-hold on attempt 1);
     `STOLE-BY-CLAIM` count ≥ 2 (re-stole after the failed read-back); no leftover lock/claim
     after release.
2. Update the stale NOTE (`:2119-2121`): both read-back lanes are now suite-covered — create
   by Test 32, steal by Test 32b — via `_lock_cur_token` fault injection.

## Why deterministic / load-robust
Internal steering (no scheduling race); the backdate-9999 trick removes any aging wait so the
re-steal is immediate; `MAX_WAIT=30`, `POLL=0.1` give ample headroom under CI load. Same shape
as the already-load-robust Test 32.

## Logging
No product logging change. The new test asserts on existing product log lines (the F2 WARNING,
`STOLE-BY-CLAIM`, `ACQUIRED`).

## Out of scope / NOT changed
- Product code (`git-commit-lock.sh`, `.ps1`) — no defect; F2 reads correct.
- Lower-priority gaps from the audit (A2/G2 wrong-type appearing at the lock path mid-steal;
  platform-only feeder #3) — left for a separate decision.

## Testing
1. Static: `bash -n` + `shellcheck -S style` (v0.11.0, the CI gate).
2. Local: run the new test (and the full suite); it MUST exercise the F2 string (the
   `bad "F2 lane never ran"` guard fails loudly if the steering misses `:1171`).
3. Real proof: CI under load (the hunt) stays green with the new test.

## Changelog (implementation)
- Added Test 32b to `tests/git-commit-lock.test.sh` (after Test 32) and updated the closing
  NOTE so both read-back lanes read as covered (create by Test 32, steal/F2 by Test 32b).
  Product untouched.
- Verified the steering empirically: a standalone extract of Test 32b (suite header + the
  Test 32b block, `LIB` pinned absolute) passed 6/6 with the F2-specific line
  `the steal-path read-back-verification failure lane ran (F2)` firing — proving the fault
  lands at `git-commit-lock.sh:1171` (`_LOCK_CLAIM_TOKEN` set there; `_lock_rename_over`
  makes no read; the create read-back at :1353 has it empty).
- Static: `bash -n` + `shellcheck -S style` (v0.11.0) clean.
- Local: full unit suite **220 passed / 0 failed** (count varies run-to-run via the fan-out
  tests; 0 failed is the invariant). Test 32b: rc 0, F2 string fired, STOLE-BY-CLAIM x2,
  WARNING-before-ACQUIRED, no leftovers.
- Impl review (2 independent, both clean): fresh Claude reviewer ("VERDICT: CORRECT … No
  defects") — independently ran the suite twice (220/0), grepped every `_LOCK_CLAIM_TOKEN`
  set/clear and `_lock_cur_token` call site, confirmed gate precision (all `_lock_discover`
  branches clear the claim token first, so the `-n` gate excludes :820; release excluded via
  `_lock_take_hold`), determinism, non-vacuity, termination. Codex `exec` read-only ("No
  findings … correct and non-vacuous"), confirming the same with file:line cites. Two minor
  non-blocking notes (the SF1 flag file lives in the throwaway WORK dir; `_ct_orig "$@"` is
  harmless) — no action.
- Real proof: CI under load (the hunt) with Test 32b in the tree.
