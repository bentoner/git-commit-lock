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

## Phase 3 — integration suite (2026-06-11)

**`git-commit-lock.integration.test.sh` ported**: the suite used defaults and
`-e` assertions throughout, so — as the plan predicted — the port is small:
the `LOCKDIR` variable renamed `LOCKFILE` and the 3h assertion's wording
("no leftover lock file"); no knob references existed. TODO 58 folded in
with the unit/interop convention exactly: REDUCED default (1 round x 6 bash
workers + 3+3 mixed = 12 commits), FULL under `GCL_TEST_FULL=1` (2x12 + 5+5
= 34), `fan-out mode:` header line + `(fan-out: MODE)` in the RESULT line;
sizing comment rewritten for both modes (assertions stay STRICT in both).

**TODO 48 finished alongside (it lives in the suites Phase 3 touches):**
file-level info-level directives with rationale (SC2015 assert-idiom,
SC2312 no-errexit, SC2016 worker-quoting; mirroring the unit suite's header)
added to the interop and integration suites; one real fix — integration 3e's
`for f in $(grep -l ...)` word-split loop became a `while read -r` pipeline
(SC2013). `shellcheck -S info` is now clean on all five shell files
(style-level SC2292 etc. deliberately left unsuppressed, the same convention
Phases 1–2 set).

**Deviation from the plan text (with why):** Phase 3's local "all three
suites x3 with `GCL_TEST_FULL=1`" full-strength canary is delegated to CI
(Ben's call at phase hand-off): the dev box is live and shared — the very
motivation of TODO 58 — and CI runs the full-strength suites on 3 OSes when
the branch is pushed, which the plan's own sequencing section already made
the real verification layer (the POSIX/macOS claims are reasoned-not-probed
locally). Local verification ran all three suites in REDUCED mode, green:

    ==== RESULT: 92 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEROP RESULT: 63 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEGRATION RESULT: 11 passed, 0 failed (fan-out: REDUCED) ====

(Integration reports 11 in REDUCED — one bash round instead of two.)

## Phase 4 — docs, TODO, linters (2026-06-11)

**README.md:** "How it works" rewritten (atomic create-or-fail lock FILE,
token-as-content); "one lock directory and protocol" → "one lock file and
protocol"; the exit-96 row's `AGENT_LOCK_DIR` → `AGENT_LOCK_PATH`; "Running
the tests" gains the reduced-by-default fan-out paragraph (`GCL_TEST_FULL=1`
runs the full canary; CI sets it) and DELETES the known-issue paragraph
about the deliberately-red macOS leg (TODO 59 is closed by this branch; the
PR's CI run must show that leg green before merge). The platform scoping is
preserved as Ben specified: ps1 is supported on Windows only; the POSIX
interop CI legs are cross-implementation protocol verification, not
platform support. No badge added (post-merge step, per the CI plan).

**docs/git-commit-lock.md:** "How the lock works" rewritten for the file
protocol — acquire (O_EXCL create, content in the same open, read-back
verification that NEVER repairs by overwriting), the lock-shaped never-steal
guards (incl. the old-protocol-directory lane and the no-rm-rf claim),
release classification (foreign/gone ⇒ 98; empty-but-present ⇒ unverifiable,
no delete; delete-blocked ⇒ leftover with the D1 retry rationale), and the
mtime floor's file-era rationale (FILETIME-zero transients on plain file
creation, probed) — with the partial-`rm -rf` / rename-aside-release /
`.new.*` / epoch-file prose deleted. "Why not flock" kept (cross-references
verified; the races sentence now says "a few ... remain" and points at the
implementation headers' inventory, which carries the release-retry gap).
PowerShell-port bullets rewritten: through-the-creation-handle write,
delete-share `FileStream` reads, escalating-backoff release read. API:
`lock_release` verdicts re-pinned to the file-era classification; knob table
`AGENT_LOCK_PATH`. "Verifying on a new machine": fan-out mode lines +
`GCL_TEST_FULL=1` noted; unit/interop coverage paragraphs updated to the
ported/new tests. Sweep: no "lock dir(ectory)" wording remains in either doc
(the two surviving "directory" protocol mentions are the deliberate
old-protocol references).

**TODO-main.md:** deleted 11, 53, 54, 55, 56, 58, 59 — each verified landed
on this branch before deletion (no `rm -rf`/`AGENT_LOCK_DIR` anywhere in the
impls; symlink + content steal guards; lazy gitdir; sh builtins; marker
polling; WAITING line in both impls and asserted in the suites; the fan-out
knob in all three suites; the file protocol itself = the macOS fix) — and 48
(info-level triage completed in Phase 3, warning level clean). Items 60 and
61 left (CI follow-ups, out of this branch's scope); header sentence
rewritten; 60's now-dangling "TODO 59" cross-reference smoothed.

**Linters (final pass):** `shellcheck -S warning` clean on all five shell
files; `shellcheck -S info` also clean; `Invoke-ScriptAnalyzer -Path
./git-commit-lock.ps1 -Severity Warning,Error`: 0 findings.

## Round-1 review fix wave (2026-06-11)

Round-1 implementation review (fresh Claude + Codex, after the green 3-OS
full-strength CI run on PR #1) returned 7 findings; all fixed. Probes for the
blocking finding live at `.agent-testing/review-probes/busyspin{,-ps1}.sh`
(re-runnable; not committed).

**1 [BLOCKING] Blocked-steal lane bypassed `AGENT_LOCK_MAX_WAIT` and
busy-spun (BOTH impls).** When the steal decision was made but the rename
failed with the lock file still present (a no-delete-share handle squatting
it — probe D1's class — or an unwritable parent dir on POSIX), the iteration
ended in an unconditional `continue` that skipped the timeout check AND the
poll sleep: the waiter spun flat-out and could never reach 97. Probe
baselines (squatter holds 6s, MAX_WAIT=2): bash `rc=0 elapsed=7s`; ps1
`rc=0 elapsed=6s` with 1428 STALE lines / 126KB of log in those 6 seconds.
Fix in both impls: the failed-rename-with-file-present case now FALLS THROUGH
to the timeout check + poll sleep; the immediate `continue` is kept for a
successful steal and for the lost-the-race/file-gone case (re-race the
create); the mtime-changed abort is untouched. Logging damped via a
`steal_fail_last` epoch: the STALE/steal-FAILED pair logs on the first
failure, then at most once per stale window while the squat persists (damper
reset on success or file-gone). Post-fix probes: bash `rc=97 elapsed=4s`,
2 STALE lines, 754-byte log; ps1 `rc=97 elapsed=2s`, 3 STALE lines,
1024-byte log. Regression test: interop T14b (Windows-gated like T13/T14) —
stale lock + never-closing FileShare.Read squatter + MAX_WAIT=2 ⇒ both
impls' waiters exit 97 with bounded STALE/steal-FAILED counts; the squatter
is reaped via its go-marker + exact-pid wait.

**2 [MAJOR] ps1 accepted `AGENT_LOCK_POLL_SECS` forms bash rejects.**
`Get-LockNum` TryParsed with `NumberStyles::Float`, so `1e3` configured a
1000s poll and `+2`/whitespace forms diverged from bash — breaking the
"same rules as git-commit-lock.sh" contract. Fix: a raw-shape regex gate
mirroring bash's grammar (digits with at most one dot, at least one digit:
`^(?=.*[0-9])[0-9]*\.?[0-9]*$`) before TryParse, same stderr note + default
fallback. Interop T12 extended with a table-driven `1e3`/`+2` loop asserting
both impls reject identically (rc 0, exactly one note each).

**3 [MINOR] 1MB log-truncation cap ported to ps1 `Lock-Log`** (bash had it;
the plan's Logging section promised parity; finding 1's spin made the gap
material).

**4 [MINOR] Never-steal docs now carry the ps1-on-POSIX residual.**
docs/git-commit-lock.md's "never stolen or deleted" paragraph, plus the
ps1 `Lock-WarnNonLock`/`Lock-IsPlainFile` helper comments, now state the
scoped exception: ps1 on POSIX (unsupported, CI-only) has no .NET type probe
for FIFOs/devices/sockets, which stat as size 0 and take the empty-orphan
steal lane; bash — and ps1 on Windows — deliver the full guarantee.

**5 [NIT] Release boundary re-read width aligned:** ps1's second (boundary)
token read was `-MaxTries 2` vs bash's full ladder; now the full `-MaxTries
8` ladder, same as its first read.

**6 [NIT] Unverifiable-lane wording:** both impls' release warning now says
"EMPTY/unreadable" (log) / "empty/unreadable" (stderr) — the lane also covers
the persistently-won't-open state; wording kept identical across impls.

**7 [watch, comment only] Integration 3f** counts ACQUIRED/RELEASED on one
shared log while concurrent appends can drop lines (Windows FULL-mode flake
risk): a KNOWN-WATCH comment now records the per-worker-log fallback
(interop T1's pattern) to apply if it ever flakes. First full CI run passed.

**Verification:** probes re-run green (quoted above); all three suites
REDUCED-mode green on the live box —

    ==== RESULT: 92 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEROP RESULT: 69 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEGRATION RESULT: 11 passed, 0 failed (fan-out: REDUCED) ====

(interop 63→69: 2 new T12 POLL rows + 4 T14b assertions = 6 new passes.)
`shellcheck -S info` clean on
all five shell files; PSScriptAnalyzer (Warning,Error) 0 findings; ps1 still
pure ASCII.

## Round-2 review fix wave (2026-06-11)

Round-2 reviews (fresh Claude with empirical probes + Codex static) returned
six findings; all landed. Commits: `33476d1` (finding 1), `4af87c5`
(findings 2+3), `1081286` (finding 4), `452daea` (findings 5+6), `01bcf35`
(T17d readiness hardening).

**1 [MAJOR] bash per-poll type guard TOCTOU — spurious loud config warning
under normal contention.** The guard's existence (`-e || -L`) and
classification (`-f && ! -L`) checks are separate stats; a rival's
release/steal unlink between them routed a normal contended poll into
`_lock_warn_nonlock "it is not a regular file"`. The reviewer prescribed an
immediate existence re-check plus a second wrong-type probe — **implemented
and probed, and it did NOT fix it**: a churner repro still warned at the
pre-fix rate, because of a Windows **delete-pending ghost** (the unlink
queues behind a rival reader's transient handle; for up to ~ms the attribute
stats FAIL while a bare `-e` still reports existence), which outlives any
back-to-back re-probe of the same `-e`/`-f` pair. Landed fix (deviation
from the prescription, same intent): warn only on a **concrete** wrong type
— `-d`/`-L`/`-p`/`-S`/`-b`/`-c` — which a churned regular file can never
read as (vanished and delete-pending paths fail every concrete stat; a
rival's re-created lock is `-f` again), while a real misconfig object always
passes one, so its warning still fires on the same poll. Documented
residual: an object so exotic no stat classifies it starves waiters to 97
undiagnosed — ghosts are exactly that state, so they win the tie. ps1
confirmed immune (single `Get-Item` snapshot classified once), unchanged.
Probe evidence (`.agent-testing/review-probes/r2-toctou-churn.sh`, pwsh
create/delete churner ~400 unlinks/s + 3 rounds x 4 parallel waiters,
POLL=0.02 MAX_WAIT=2):

    pre-fix:  warnings in 5/5 reps (1..9 per rep), 97s 12/12 each
    re-probe: warnings in 2/5+ reps (ghost defeats it)
    landed:   8 reps — nonlock-warnings=0, timeouts-97=96/96

Regression test: unit **T17d** — single-process churner (pwsh on Windows,
perl elsewhere with a 2ms present-hold; reaped via stop marker + exact-pid
wait, hard-kill of that pid as last resort), 12 waiters, asserts ZERO
non-lock warnings and >=1 waiter at 97. Readiness gates on a one-shot
START MARKER, not the churned lock path: the same delete-pending state
makes Cygwin `[ -e ]` report ENOENT for 60s straight while pwsh Test-Path
says True (observed; flaked ~1-in-3 suite runs before regating). 6/6
consecutive Windows suite runs green after; WSL Ubuntu (perl branch) green
(9/12 waiters at 97 there — fast ext4 lets a few slip into the absent gap;
the >=1 floor is what the lane guarantees).

**2 [MINOR] ps1 knob regexes accepted trailing newlines bash rejects.**
.NET `$` matches before a final `\n` and TryParse tolerates trailing
whitespace, so `AGENT_LOCK_POLL_SECS=$'5\n'` configured ps1 5s vs bash
default 2, and `AGENT_LOCK_STALE_SECS=$'200\n'` gave different steal
thresholds. Both shape gates anchored `\A..\z` (ps1 integer + fractional).

**3 [MINOR] whitespace-only knob parity.** bash notes-and-defaults `"   "`
(non-empty passes `:-`, fails the validator); ps1's `IsNullOrWhiteSpace`
early-return silently defaulted. Now `IsNullOrEmpty`, pinning the contract:
EMPTY => silent default in both; whitespace-only / non-empty invalid =>
note + default in both. Interop T12 extended with whitespace-only,
trailing-newline AND empty rows (69 -> 72 passes); the reviewer's
`r2-poll-parity.sh` probe is all-agree, 17/17 rows (the `"   "` row
diverged pre-fix).

**4 [NIT] T14b hang-on-regression shape.** The squatted-steal waiters ran
foreground, so a busy-spin regression (the exact bug T14b guards) would
HANG the suite, not fail it. Converted to background + bounded reap (T17c's
`kill -0` poll pattern, 30s budget, hard-kill by exact pid) => clean FAIL.

**5 [MINOR, docs] "a typo'd user file is harmless" overstated.**
docs/git-commit-lock.md now bounds the claim with the two accepted
residuals already in the sh header: a stale EMPTY user file (crash-orphan
lane) and a stale file whose line 1 starts `tok.` (the prefix IS the wire
test) ARE stolen.

**6 [MINOR, docs] README exit-code contract omitted two run lanes.**
"anything else is the command's own exit code" now carries the caveats
(verified against `lock_run` sh:766 and `Invoke-WithLock` ps1:976):
unverifiable release (file reads EMPTY while present) fails a SUCCESSFUL
command with 1, a failing command keeps its own code; a LEFTOVER
(undeletable lock) keeps the command's code — cleanup failure, not a
serialisation failure.

**Verification:** all three suites REDUCED-mode green on the live box —

    ==== RESULT: 94 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEROP RESULT: 72 passed, 0 failed (fan-out: REDUCED) ====
    ==== INTEGRATION RESULT: 11 passed, 0 failed (fan-out: REDUCED) ====

(unit 92 -> 94: T17d's 2 assertions; interop 69 -> 72: 2 new T12 POLL rows
+ 1 empty row.) Unit also green on WSL Ubuntu 24.04 (the perl-churner
branch). `shellcheck -S info` clean on all five shell files; PSScriptAnalyzer
(Warning,Error) 0 findings; ps1 still pure ASCII.
