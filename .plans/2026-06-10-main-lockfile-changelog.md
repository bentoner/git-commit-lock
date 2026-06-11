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

## Phase 2 — ps1 implementation + interop suite (2026-06-11)

**`git-commit-lock.ps1` rewritten to the file protocol** (commit 4606f92),
mirroring Phase 1's wire format, knob name and exact log wordings: acquire =
one `[IO.File]::Open(CreateNew, Write, FileShare ReadWrite|Delete)` with
token+owner written/flushed/closed THROUGH the creation handle; any open
exception ⇒ contended ⇒ `$false` (dir-at-path throws
`UnauthorizedAccessException` — re-verified, arrives wrapped in
`MethodInvocationException`, so the catch-all is doubly required); path
read-back verification (8-try 20→320ms ladder) with NEVER-overwrite;
temp-dir dance / `.new.*` sweep arm / `SetLastWriteTimeUtc` stamp deleted.
Per-poll type guard via a link-aware `Get-Item -Force` probe (PSIsContainer +
ReparsePoint attribute; dangling symlink reads as exists-but-wrong-type);
age-gated content guard with stat-based emptiness (`FileInfo.Length -eq 0`,
no open — the ps1-on-Unix FIFO hazard; the FIFO/device/socket residual is
documented in the ps1 header per the bash header's cross-reference) and the
`tok.` prefix test; unreadable ⇒ skip+log (never the config-warning lane);
owner read in the same open as line 1, BEFORE the final mtime re-read; steal
via `File.Move` + grave delete. Release pinned to the bash classification:
empty-after-ladder ⇒ 'unreadable', no delete — including at the boundary
re-read (the dir-era proceed-to-delete is gone); gone/foreign ⇒ 'stolen'
(run ⇒ 98); ours ⇒ `File.Delete` + 5×20ms retry ⇒ 'leftover' (run keeps the
command's code). ALL lock-file reads (release ladder, content guard, exiting
backstop) use FileStream with `ReadWrite|Delete` sharing. `PowerShell.Exiting`
backstop ported (read line 1 via the same shared-stream pattern, compare
token, `File.Delete`). Folded in: `AGENT_LOCK_PATH` rename (no alias),
`[Environment]::MachineName`, TODO 53 lazy gitdir with Phase 1's refinement
(lazy only when BOTH lock path and log are explicit), WAITING line.

**Deviation from the plan text (with why):** the plan calls the ps1
pre-create type guard "optional symmetry, not load-bearing" — that is true
only on Unix. Probed 2026-06-11 on Windows: `CreateNew` on a DANGLING
symlink resolves the link and **creates the target** (CreateFile resolves
the final component before the disposition check; POSIX `O_CREAT|O_EXCL`
refuses instead). So the ps1 acquire carries the bash-style pre-create guard
as a LOAD-BEARING piece on Windows (create attempted only on absent or
plain-regular-file paths), documented in the header's PORT-SPECIFIC NOTES.
Interop T15(b) regression-tests exactly this (asserts no target is created
through the link).

**`git-commit-lock.interop.test.sh` ported** (commit c3594c1): T4/T5
fabricate/inspect lock files (portable `epoch_to_stamp`/`backdate`
preserved; T4 adds a cross-impl holder-from-line-2 assertion); T11 re-split
— truncate ⇒ both impls exit 1 + file left, delete ⇒ both impls 98 (the new
gone⇒theft agreement). NEW: T13 blocked release via a pwsh `FileShare.Read`
holder (Windows-gated, skip-note on POSIX) — sourced `lock_release` rc 1 +
LEFTOVER log, `run` keeps the command's own exit code (5), ps1
`Lock-Release` ⇒ `$false`/`LockReleaseStatus='leftover'`, then recovery
after handle-close + stale window (TODO #30's untestable lane now
deterministic); T14 blocked steal (Windows-gated) — the ps1 stealer's
`File.Move`-throws⇒re-poll path exercised, acquires once the handle closes;
T15 ps1 guard parity — dir (97 + warning, no throw), dangling symlink (97,
link untouched, no tunnel-created target), stale user file (97, content
intact). TODO 55: T8a/T8b marker-holds, T9 3s→2s, T7 parallelised. TODO 58:
REDUCED default (T1 4+4, T6 3+3; FULL 8+8/6+6), mode header + RESULT-line
tag, same convention as the unit suite.

**Verification (this box, REDUCED only — full strength is CI's):** interop
3× back-to-back `==== INTEROP RESULT: 63 passed, 0 failed (fan-out:
REDUCED) ====`; unit re-run `==== RESULT: 92 passed, 0 failed (fan-out:
REDUCED) ====`; `Invoke-ScriptAnalyzer -Severity Warning,Error` clean
(1.25.0); `shellcheck -S warning` clean (0.11.0) on the interop suite.

**For Phase 3 (integration + full matrix):**

- The integration suite still uses defaults (no `AGENT_LOCK_DIR` refs), so
  the knob rename should not touch it — but verify, then run all three
  suites ×3 with `GCL_TEST_FULL=1` (coordinate timing with Ben; live box).
- CI's POSIX legs will exercise for the first time: the ps1 guards on real
  Unix symlinks/FIFOs (T15; the .NET-on-Unix O_EXCL-refuses claim is
  reasoned-not-probed), the T13/T14 skip lanes, and `host=` population via
  `MachineName`. Watch the ubuntu/macos interop logs for those.
- The ps1 read ladder (8 tries, 20→320ms) makes interop T11(i)'s pwsh leg
  take ~1.6s of deliberate retrying — expected, not a hang.
- Phase 4 must still fix docs/README wording + TODO items (11, 48, 53–56,
  58, 59 closure per the plan's table).
