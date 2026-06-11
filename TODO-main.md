# TODO — open items from the pre-publication review

Numbering is continuous from the original 57-item consolidated review (see git
history of this file for the full record); do not renumber; delete items as
fixed. Everything not listed here was fixed in the 2026-06-10 fix wave and
verified by the suites (unit 59/59, interop 30/30, integration 12/12 — counts
as of that wave; the suites have since grown, see the CI plan's Grounding) —
see commits 9b36f42..840a4fd.

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

59. **[MAJOR — known, fix = the lockfile port] The dir-protocol ps1 acquire
    is not an atomic gate on POSIX; macOS CI interop is expected-RED until
    the lockfile plan lands.** Evidence: first CI run (27314216372,
    macos-15): interop T1 violations=1 with steals=0 — lock log shows pwsh
    pid 40976 ACQUIRED then "lock LOST (ours=tok.ps.40976… now=tok.ps.41001…)"
    while pid 41001 acquired/released "normally"; T6 lost an update
    (counter 11/12, acquired=12 released=11, worker rc=98). Mechanism,
    probe-confirmed: .NET `Directory.Move` is `rename(2)` on Unix, and POSIX
    rename ATOMICALLY REPLACES an empty destination directory — so any
    holder's empty-dir window (post-mkdir / post-move, before the token
    write) can be hijacked by a concurrent ps1 acquirer. Windows is immune
    (MoveFile fails on an existing destination); bash-vs-bash is immune
    (mkdir fails, EEXIST); ubuntu passed on timing only — same exposure.
    No clean dir-era fix exists (.NET has no atomic create-dir-or-fail; the
    vulnerability is the DESTINATION being empty, so staging content in the
    source doesn't help). The file protocol eliminates the state by
    construction: O_CREAT|O_EXCL / `File.Open(CreateNew)` fails on ANY
    existing file, empty or not. Do not mask the failing tests — they are
    correctly reporting a real defect. Artifact: test-logs-macos-15, run
    27314216372 (expires 2026-06-24); copy in
    .agent-testing/macos-artifact/ locally.

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

## CI implementation review (2026-06-11, post first run)

60. **[MINOR]** CI step budgets have 5–10x headroom vs first-run reality —
    record the baseline now, tighten ONCE after the lockfile port lands.
    Observed in run 27314216372 (full-strength suites): ubuntu unit 32s /
    interop 40s / integration 6s (job 1m25s); macos 50s / 33s / 9s (job
    1m41s); windows unit 4m00s / interop 46s / integration 22s (job 6m05s,
    incl. 32s checkout + 18s toolchain); lint 16s. Budgets are unit 15/35,
    interop 10/12, integration 10/12, jobs 40/65 (Linux+macOS/Windows). The
    plan's own sizing formula (expected runtime + one internal MAX_WAIT hang
    + margin) with the now-observed expecteds yields roughly: unit 10/15,
    interop 10/10 (already right — the 7-min hang allowance dominates),
    integration 7/7, job backstops ~30/40. Do NOT tighten yet: the plan's
    revisit trigger is "after the perf pass (TODO 53–56) lands and after
    observing real runner times" — times are now observed, but the lockfile
    port (TODO 59) and the perf pass will change runtimes again, so one
    revision after the port lands (re-measured against that run) beats two
    churn commits. These numbers are the pre-port baseline.

61. **[NIT]** Optional workflow hardening before the repo is announced
    (zizmor-class, public repo): (a) pin `actions/checkout` and
    `actions/upload-artifact` to full commit SHAs instead of major tags —
    both are official actions and `permissions: contents: read` already
    bounds the blast radius, hence NIT not MINOR; (b) add
    `persist-credentials: false` to both checkout steps — neither job uses
    the token after fetch, so there is no reason to leave it sitting in
    `.git/config` for the job's duration.
