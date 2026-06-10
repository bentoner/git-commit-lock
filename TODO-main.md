# TODO — open items from the pre-publication review

Numbering is continuous from the original 57-item consolidated review (see git
history of this file for the full record); do not renumber; delete items as
fixed. Everything not listed here was fixed in the 2026-06-10 fix wave and
verified by the suites (unit 59/59, interop 30/30, integration 12/12) — see
commits 9b36f42..840a4fd.

11. **[MINOR]** `AGENT_LOCK_DIR` is `mv`'d and `rm -rf`'d unvalidated — a typo
    like `AGENT_LOCK_DIR=$HOME` becomes destructive once "stale". Validate
    (reject roots/home, require lock-shaped basename, reject symlinks).
    NOTE: the lockfile plan (.plans/2026-06-10-main-lockfile-plan.md) includes
    a steal guard rejecting symlinks and non-lock-shaped content — if that
    plan proceeds, it subsumes this item; otherwise implement standalone.
    (Codex#1.)

48. **[MINOR — residual]** shellcheck info-level triage (SC2015 `A && B || C`,
    SC2310/SC2312 errexit-interaction notes) — one deliberate review pass,
    suppress-with-rationale where intentional. Warning level is clean.
    The CI lint job itself is specified in the CI plan.

53. **[MINOR]** Perf: lazy gitdir resolution — both impls run `git rev-parse`
    at load even when AGENT_LOCK_DIR is explicitly set. Resolve lazily; the
    default path stays covered by the tests that test it.
54. **[MINOR]** Perf: replace hot forks in the sh impl with builtins
    (`_lock_now` → `printf '%(%s)T' -1` with `date` fallback for macOS bash
    3.2, `hostname` → `$HOSTNAME`, `tr` digit check → `case`). ~30% of
    per-invocation cost.
55. **[MINOR]** Perf: convert the remaining fixed sleep-holds to
    marker-polling (unit T6/T10/T11, interop T8a/T8b/T9; T4c 3s→2s; T9
    MAX_WAIT 2→1; parallelise interop T7's two CLI calls). Unit T4b/T8 were
    already converted during reconciliation after a load flake.
56. **[MINOR]** Perf+strength: add a one-line `WAITING` log entry on the first
    blocked poll iteration (both impls): lets unit T4 / interop T2/T3
    positively assert the waiter actually contended AND replaces their fixed
    2-3s holds. Do NOT touch the slow-for-good-reason set: unit T1's
    8×25/poll-rate/gap, interop T1/T6 fan-out, stale-window waits, unit T9's
    remaining MAX_WAIT, the integration suite's real-commit costs.

58. **[MINOR]** Heavy fan-out tests run at full strength by default, and
    agents run the suites routinely during development on a live shared
    machine — unit T1's ~200 bash spawns (8×25) alone can lag the whole box
    (observed: a dev-loop run during another agent's session). The tests are
    good; the default is the misuse vector. Make full concurrency opt-in:
    default to reduced fan-out (e.g. unit T1 3×8, interop T1/T6 and the
    integration swarms scaled similarly — still a real exclusion signal,
    ~1/8 the spawn load) and run full strength only when `GCL_TEST_FULL=1`
    is set. CI sets the flag (the CI plan's YAML carries it); pre-publish
    local verification runs set it explicitly. Suites print which mode ran
    so a reduced pass can't masquerade as the full canary. Reduced, not
    skipped — skipping would lose the signal entirely from routine runs.
