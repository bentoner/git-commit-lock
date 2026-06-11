# TODO — open items

Numbering is continuous from the original consolidated review and later
additions (see git history of this file for the full record); do not
renumber; delete items as fixed. The pre-publication review items were
closed by the 2026-06-10 fix wave (commits 9b36f42..840a4fd) and the
2026-06-11 lockfile-protocol port
(.plans/2026-06-10-main-lockfile-plan.md, branch
worktree-lockfile-protocol — closed 11, 48, 53–56, 58, 59); only the CI
follow-ups below remain.

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
    revisit trigger is "after the perf pass (items 53–56, since landed with
    the lockfile port) and after observing real runner times" — times are
    now observed, but the lockfile port and perf pass change runtimes again,
    so one revision after the port lands (re-measured against that run)
    beats two churn commits. These numbers are the pre-port baseline.

61. **[NIT]** Optional workflow hardening before the repo is announced
    (zizmor-class, public repo): (a) pin `actions/checkout` and
    `actions/upload-artifact` to full commit SHAs instead of major tags —
    both are official actions and `permissions: contents: read` already
    bounds the blast radius, hence NIT not MINOR; (b) add
    `persist-credentials: false` to both checkout steps — neither job uses
    the token after fetch, so there is no reason to leave it sitting in
    `.git/config` for the job's duration.
