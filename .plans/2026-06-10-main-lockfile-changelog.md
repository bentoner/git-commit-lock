# Implementation changelog — lockfile protocol port

Plan: `.plans/2026-06-10-main-lockfile-plan.md` (converged after 7 review
rounds). Branch `worktree-lockfile-protocol`, based on main @ 2c1555c.

## Phase 1 — bash implementation + unit suite (2026-06-11)

**`git-commit-lock.sh` rewritten to the file protocol** exactly per the plan's
protocol section: pre-create type guard; noclobber create with token+owner as
content (epoch dropped — open question 3); path read-back verification with
NEVER-overwrite (failed verify ⇒ loud log ⇒ not acquired ⇒ re-enter wait);
steal with per-poll type guard (warn on exists-but-wrong-type only, existence
= `-e || -L`), floor, age gate, content guard (empty via `! [ -s ]` OR line 1
`tok.`-prefixed; unreadable ⇒ skip+log; sub-`tok.` torn prefix ⇒ never-steal),
owner read in the same open as the content guard (BEFORE the final mtime
re-read), rename-aside steal (open question 2); age-gated grave sweep
(`rm -f` of `.dead.*` only, non-recursive); release with the pinned
classification (boundary re-read classified by the same rules; empty-present
⇒ rc 2 no-delete; gone/foreign ⇒ 98; ours ⇒ `rm -f` with 5×20ms retry ⇒
leftover warn rc 1). Traps/signals/reentrancy/exit codes/knob validation/log
cap carried over unchanged. Header rewritten (WHY / LOCK FILE FORMAT /
STALENESS / ACQUIRE VERIFICATION / RESIDUAL RACES incl. the release-retry
gap / ACCEPTED RESIDUALS incl. torn-prefix, prefix-collision, ps1 FIFO/device
reference, read-only attribute).

**Folded in:** knob rename `AGENT_LOCK_DIR` → `AGENT_LOCK_PATH` (open
question 1; no back-compat alias); TODO 53 lazy gitdir; TODO 54 builtins
(`printf '%(%s)T'` probed once with `date` fallback for macOS bash 3.2 — also
used for log stamps; `$HOSTNAME`; `case` instead of `tr` for the zero check);
TODO 48 residual (info-level SC2015/SC2310/SC2312/SC2249/SC2329/SC2016 triaged
with directives + rationale in the two rewritten files).

**`git-commit-lock.test.sh` ported:** T2/T9 fabricate via `printf`+`backdate`
(T2 also asserts holder parsed from line 2); T3 = empty-file orphan
regression; T6/T10 assert `-f`; T15 = file graves (age gate kept; plus a
non-recursiveness assertion: an aged DIRECTORY at a grave name survives);
T16 = truncate ⇒ rc 2 / run 1 / failing-command-keeps-code; NEW: T16b
gone-at-release ⇒ 98 (sourced + run), T17 non-file refusal (dir, dangling
symlink guarded by `[ -L ]` post-create, FIFO behind `command -v mkfifo`
with a bounded external wait + exact-PID kill so a guard regression can't
hang the suite), T18 content-guard (user file survives intact; `to` torn
write never stolen; `tok.`-prefixed torn write IS stolen), T19 wire format
(token line 1 = `$_LOCK_TOKEN`, `tok.` prefix, owner line shape, release
parses line 1 with owner present), T4 WAITING-line assertion. TODO 55:
marker-polling for T4/T6/T10/T11; T4c 3s→2s; T9 MAX_WAIT 2→1; slow-for-good-
reason set untouched. TODO 58: default REDUCED fan-out (T1 3×8), full 8×25
only under `GCL_TEST_FULL=1`; mode printed at start and in the RESULT line.

**Verification:** `shellcheck -S warning` clean on both files (0.11.0).
Suite run 3× back-to-back in REDUCED mode on the dev box:
`==== RESULT: 92 passed, 0 failed (fan-out: REDUCED) ====` each time
(symlink and FIFO legs both exercised, not skipped, on this box).

**Deviations from the plan text (with why):**

- TODO 53's wording says "skip `git rev-parse` when AGENT_LOCK_PATH is
  explicitly set"; implemented as *skip when AGENT_LOCK_PATH AND
  AGENT_LOCK_LOG are both explicit*, because the log still defaults into the
  git dir — skipping on lock-path-explicit alone would silently move a
  defaulted log to the CWD. Behaviour-preserving; covers the perf case
  (tests/sub-agents set both).
- The plan's "strip CR/whitespace" on token reads is implemented as a single
  trailing-`[:space:]` strip (covers CR); leading whitespace is preserved —
  a token never starts with whitespace, and a foreign value that does simply
  fails the compare, which is the safe verdict anyway.

**For Phase 2 (ps1 + interop) — choices to mirror exactly:**

- Knob: `AGENT_LOCK_PATH` (everywhere; no alias).
- Wire format: line 1 `tok.`-prefixed token, line 2 `pid=<pid> host=<host>`,
  LF, no epoch line.
- New log lines (exact wording):
  - `WAITING for lock (pid=<pid> host=<host> tok=<token>)` — once per
    acquire, on the first blocked poll;
  - `WARNING: acquire verification FAILED — create won but read-back found
    '<val|<empty-or-gone>>' (ours=<token>); not acquired, re-entering wait`;
  - `steal skipped: stale lock content unreadable (age=<n>s); re-polling`;
  - `WARNING: non-lock object at lock path (<reason>) — never stolen; waiters
    reach 97 until it is removed by hand` (+ matching stderr line containing
    "is not a lock file"; once per process). Reasons used: "it is not a
    regular file" / "its content is not lock-shaped";
  - release lanes: empty-present logs `WARNING: lock file present but EMPTY
    at release (after retries); ownership unverifiable...` (rc 2); leftover
    logs `WARNING: release FAILED — could not delete the lock file after 5
    attempts; LEFTOVER (tok=...)` (rc 1); theft keeps the existing
    `WARNING: lock LOST before release ...` (98).
- `STOLE`/`STALE (age=..s holder=...)`/`ACQUIRED`/`RELEASED`/`TIMEOUT`/
  `SWEPT stale litter <name>` survive verbatim; holder comes from line 2,
  read in the same open as the content guard.
- Suite conventions: `GCL_TEST_FULL=1` ⇒ full width, else reduced; the suite
  prints `fan-out mode: FULL|REDUCED (...)` at start and `(fan-out: <MODE>)`
  in the RESULT line. Markers: holders touch a READY file inside the lock
  and hold until a GO file appears; waiter contention is gated on the
  WAITING log line (`wait_for_grep`).
