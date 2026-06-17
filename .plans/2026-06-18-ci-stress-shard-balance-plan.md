# Subplan: balance the Windows-unit shards with a fixed (measured) split

**SUPERSEDED 2026-06-18** by `.plans/2026-06-18-ci-stress-canary-split-plan.md`. The "Test 1 vs
rest" insight here was right, but the cleaner realization is to make Test 1 its own *file* (no
sharding at all) — so the `GCL_TEST_SHARD` machinery was unwound (`89de803` + `143e280`) and the
canary is extracted instead. Original status retained below for record.

Status: **ENDORSED by Ben (2026-06-18) — split = "Test 1" vs "not Test 1"; implementing.**
The change is a tiny assignment swap on the already-3-round-reviewed shard mechanism, so the
local proof + CI run are the gates (no separate review rounds). Follow-on to
`2026-06-18-ci-stress-windows-unit-shard-plan.md` (the shard *mechanism*, shipped in `a01a8e3`
+ `2de66ff`). That used naive round-robin-by-index and balanced poorly in practice (242s vs
99s). This plan replaces the *assignment* with a **fixed, measured split** — still a static
deterministic assignment (no live cost-table maintenance, per Ben), but chosen to balance.
No implementation until review converges + Ben's go.

## Review issues (record at top; do not renumber on resolution)
*(reviewers: add numbered findings here)*

---

## The finding that drives the design (measured, not estimated)
Per-test **full-mode Windows** durations, parsed from the green CI run `27723744798`'s job-log
timestamps (each `== Test N ==` header line is timestamped; the delta to the next header is that
test's duration; combined across both shard logs). Method is reproducible from the run log via
`gh run view <id> --log`; raw table in `.agent-testing/shard-timing/` (gitignored).

- **Test 1 (the 8×25 FULL-width concurrency canary) = ~151s — about HALF of the entire ~309s
  suite.** It is one indivisible test.
- The other 56 tests sum to ~158s; the next-largest are Test 22 (~20s), Test 2b (~12s), Test 17
  (~9s), Test 33 (~8s), then a long tail ≤7s.
- So the round-robin imbalance (shard1 odd = 226s vs shard2 even = 83s of test time) was **not**
  "heavies scattered on odd indices" — it was **one dominant test (the canary, index 1 → shard
  1)** plus the rest happening to land light on shard 2.

**Consequences:**
- A balanced n=2 split is nearly trivial: **canary alone on one shard (~151s), the other 56
  tests on the other (~158s).** ~151 vs ~158 — well balanced.
- Windows-unit leg wall-clock → ~**167s** (151 + ~16s job overhead). That is **below macOS's
  210s**, so macOS becomes the overall CI floor: **overall 242s → ~210s** (the ~32s the previous
  plan predicted, now confirmed and explained).
- **More shards don't help:** Test 1's 151s is an irreducible per-shard floor; n=3 still yields a
  ~151s shard. So **n stays 2**.

## Approach: a fixed, measured assignment (NOT round-robin, NOT a live cost table)
Replace the round-robin gate with a **static per-test→shard assignment**, derived **once** from
the measured costs by greedy LPT (longest-processing-time: sort tests desc, put each on the
currently-lighter shard) and **frozen** into a small hard-coded list in `tests/_harness.sh`.

For the current data the greedy result is essentially **shard 1 = {Test 1}; shard 2 = {all
others}** (151 vs 158). Because shard 1's membership is tiny, encode it as "shard-1 label
prefixes; everything else → shard 2":

```sh
# n=2 fixed split (measured 2026-06-18; re-tune if the per-shard wall-clock drifts — see below).
# Test 1 (the FULL-width canary) is ~half the suite, so it gets its own shard.
_shard_of() {   # echoes the shard (1..n) that owns the test label "$1"
  case "$1" in
    "Test 1:"*) echo 1 ;;
    *)          echo 2 ;;
  esac
}
```

`section()` (still gated on `GCL_TEST_SHARD=i/n`, lazy-parsed, mutually exclusive with
`GCL_TEST_ONLY` — all unchanged from the shipped mechanism) runs a block iff
`[ "$(_shard_of "$1")" = "$SHARD_I" ]` instead of the round-robin residue test. The CI interface
(`tests.yml` matrix passing `1/2` and `2/2`) is unchanged.

### Why this is a "fixed split," not the rejected "cost-aware split"
- It is a **static, hand-frozen assignment** set from **one** measurement — no per-run cost
  computation, no maintained cost table, no dynamic bin-packing in the harness.
- New/unknown tests fall to the **default shard (2)** — they always run (never dropped), and a
  new *light* test just nudges shard 2 (which has ~7s of headroom and is the lighter side
  anyway). Only a new *heavy* test (or the canary changing) would need a re-tune, which the
  drift log surfaces (below). That is occasional manual re-tuning, not continuous cost tracking.

## Coverage-safety
- **Partition by construction:** `_shard_of` is a total function returning exactly one shard per
  label, so every test belongs to exactly one shard — union == full suite, no overlap, for any
  membership list. (Same guarantee the round-robin had, via a different total function.)
- **Empty-shard guard** (keep): in shard mode, `selector_report` bails if `SECTIONS_RUN < 1`
  (a misconfigured shard with no members). The exact-count guard is dropped as near-tautological
  (it recomputes `_shard_of`, the same function the gate uses — established in the mechanism
  plan's round-2 review).
- **One-time union proof** (the real partition check): run `GCL_TEST_SHARD=1/2` + `=2/2`, assert
  their run-line sets (`^(PASS:|FAIL:|PASS\[env\]:|WARN\[env-relaxed\]:)`) union to the unsharded
  set with **no duplicates** — catches any assignment bug (a label in both/neither shard).

## Maintenance / drift (the low-maintenance story)
- Each sharded run already logs `GCL_TEST_SHARD=i/n: ran R of T sections` and the CI job
  duration is visible. If the two shards' wall-clock skews materially (say >25%), re-measure
  (parse a fresh run log the same way) and adjust the `_shard_of` list. Expected cadence:
  rarely — only when the canary's cost changes or a new ≥~30s test lands.
- The measurement method is recorded above so a successor can regenerate the cost table.

## Phasing (implementation)
1. **`tests/_harness.sh`:** replace the round-robin residue gate in `section()` with
   `_shard_of`; add the static `_shard_of` (current measured assignment). Drop the now-unused
   round-robin residue arithmetic + the exact-count guard branch (keep the empty-shard guard).
   `SECTION_IDX` is no longer needed for assignment — keep it only if still used elsewhere
   (it isn't, post-change), else remove it and the `RAN:` marker stays shard-gated.
2. **Local proof:** (a) unsharded byte-identical (315/0, 141/0); (b) `1/2` runs only Test 1
   (1 section, ~the canary), `2/2` runs the other 56; union == unsharded, no dup; (c) empty/
   malformed/mutual-exclusion bails unchanged; (d) `shellcheck -S style` clean.
3. **CI verify:** dispatch `tests.yml`; confirm shard 1 ≈ shard 2 (~167s / ~174s incl. overhead),
   overall CI ≈ 210s (macOS-gated), both green, full legs unchanged.
4. Commit incrementally under the lock; ships on `ci-stress`, lands via the merge PR.

`tests.yml` needs **no change** (the matrix already passes `1/2`/`2/2`); the assignment swap is
entirely in the harness.

## Logging / observability
- Keep the per-shard verdict line (`ran R of T sections`) + the shard-gated `RAN:` marker.
- The CI job-log timestamp method (above) is the standing way to re-measure per-test cost — no
  permanent timing instrumentation needed (kept out to avoid output churn).

## Related observation (out of scope here — flagging for a separate decision)
The canary (Test 1) being **~50% of the whole suite** is the real cost driver; sharding only
works *around* it. If its FULL width (8×25) could be reduced without losing meaningful
concurrency coverage, that would lower the ~151s floor and help more than sharding — but that's
a **test-design change** (the width *is* its coverage), so it's deliberately out of scope for
this balance plan. Worth raising separately.

## Out of scope
- `n > 2` (Test 1's 151s floor makes more shards pointless), cost-aware/dynamic bin-packing
  (rejected — this is the fixed alternative), sharding other legs/suites/kcov, or changing the
  canary itself (above).
