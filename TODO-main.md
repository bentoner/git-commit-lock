# TODO — pre-publication review findings (consolidated)

Consolidated from six independent reviews (bash-implementation, PowerShell-port,
test-suite, docs/ancillary, Codex foreign-model, integration-test build), each
verified against the code; empirically-demonstrated findings noted as such.
Mutation-testing results will be appended when that run completes.
Numbering is continuous and stable — do not renumber; delete items as fixed.

## Fixed during review

1. **[BLOCKER — FIXED, aff3018]** `Get-LockBase` in git-commit-lock.ps1 piped
   `git rev-parse` through `Select-Object -First 1`, which on pwsh 7 leaves
   `$LASTEXITCODE` unset; the `-ne 0` guard then discarded the git dir and the
   lock fell back to **CWD** — so `.ps1` and `.sh` holders never contended at
   default config. Found independently by the PS reviewer (6/6 deterministic
   repro) and by the integration suite's first run (real index.lock collisions
   + a sweep-up); fix verified by hand and by all three suites green.
   Residual work: regression test (item 32); the stray worktree
   `commit-lock.log` this bug wrote was deleted.

## Implementation — MAJOR

2. **[MAJOR] Staleness is silently dead on macOS/BSD.** `_lock_dir_mtime`
   (git-commit-lock.sh:111-113) uses GNU `stat -c %Y`; the `date -r FILE`
   fallback is GNU-only (BSD `date -r` takes seconds). On macOS the mtime is
   unreadable → stale locks are never stolen → a crashed holder wedges every
   waiter to timeout, forever. Docs repeat the wrong claim (docs:50-51).
   Fix: add `stat -f %m` to the chain; one-time loud warning if all probes
   fail; fix the docs sentence. Also make the suites' `backdate` portable
   (GNU `touch -d "@…"`, 3 sites). (bash#1, Codex#2, tests#10, CI planner.)

3. **[MAJOR] Sourcing imposes `set -euo pipefail` on the caller's shell**
   (git-commit-lock.sh:83 runs unconditionally; demonstrated). Guard:
   `if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; fi`. (bash#2.)

4. **[MAJOR] `lock_acquire` clobbers the caller's EXIT/INT/TERM traps and the
   shell stays signal-immune after release** (sh:133; both halves demonstrated
   — pre-existing EXIT trap never fires; post-release `kill -TERM` survived,
   rc 0). Fix: save/restore prior traps, or reset `trap - EXIT INT TERM` in a
   successful `lock_release`. (bash#3, Codex#3.)

5. **[MAJOR] `run` swallows SIGTERM/SIGINT** — bash defers the trap, releases,
   and continues; demonstrated: TERM'd wrapper let the command run to
   completion and exited 0. A watchdog can neither stop it nor see failure.
   Fix: re-raise pattern (`trap 'lock_release||true; trap - TERM; kill -s TERM $$' TERM`,
   analogue for INT). (bash#4.)

6. **[MAJOR] Check-then-act races in steal and release.** (a) Acquire-side: a
   stealer that read a stale mtime can `mv` aside a RIVAL stealer's brand-new
   live lock (no mtime re-read before the `mv`, sh:148-159). (b) Release-side:
   between the token check and `rm -rf` (sh:185-203; same shape ps1:221-236) a
   boundary steal + re-acquire gets its live lock deleted. Both are detected
   (victim's release exits 2 — no silent lost update) but cause a spurious
   "redo" + transient double-hold. Mitigations: re-read mtime immediately
   before the steal `mv`; release by renaming our own dir aside first and
   verifying the token inside the grave. (bash#5, PS#10.)

7. **[MAJOR — DECISION NEEDED before publishing] Exit-code ambiguity in three
   lanes.** `run` exits 2 for stolen-lease AND a command whose own rc is 2 AND
   CLI usage errors; timeout returns 1, indistinguishable from a command
   failing with 1 — though the command never ran. Changing this later is
   breaking; decide now. Recommendation: reserve high codes (e.g. 96 usage /
   97 timeout / 98 stolen) and document them. (bash#6, docs#8.)

agree on high codes. suggest document in repo documentation, not agent instructions, if that saves context. do agent instructions point to repo documentation? also consider whether other explicit items in agent instructions should point to docs instead.


8. **[MAJOR] ps1: `exit` inside the wrapped command bypasses the stolen→2
   override** (demonstrated: stolen lock + `exit 0` → process exit 0, warning
   on stderr only). The header caveat (ps1:28-29) is wrong in both directions
   (plain exit codes DO propagate). Fix the caveat; ideally detect the stolen
   state inside the `finally`. (PS#2.)

9. **[MAJOR] ps1: `$ErrorActionPreference='Stop'` leaks into the wrapped
   command**, and a terminating error skips `exit $LockRunRc` — in-session the
   caller's stale `$LASTEXITCODE` (often 0) reads a failed run as success
   (demonstrated). Fix: try/catch in `Invoke-WithLock`, map throw → nonzero,
   keep the lost→2 override. (PS#3.)

10. **[MAJOR] ps1 cannot be parsed by Windows PowerShell 5.1 at all** — the file
    is BOM-less UTF-8 and the em dash inside the string at ps1:224 decodes in
    cp1252 to a right smart quote that terminates the string (ParserError).
    The header nonetheless says "works on Windows PowerShell 5.1 too". Fix:
    replace that em dash with `-` (verified sufficient) or save with BOM, and
    decide whether 5.1 is claimed at all. (PS#7.)

## Implementation — MINOR / NIT

11. **[MINOR]** `AGENT_LOCK_DIR` is `mv`'d and `rm -rf`'d unvalidated — a typo
    like `AGENT_LOCK_DIR=$HOME` becomes destructive once "stale". Validate
    (reject roots/home, require dir-basename pattern, reject symlinks).
    (Codex#1.)
12. **[MINOR]** Reentrant `lock_acquire` self-deadlocks for the stale window,
    then steals its own lock. One-line `_LOCK_HELD` guard. (bash#7,
    demonstrated.)
13. **[MINOR]** No validation of `AGENT_LOCK_*` numerics in either impl: bad
    POLL busy-spins mkdir; bad STALE silently disables stealing (bash), throws
    at load (ps1). Validate once, fall back with a stderr note. (bash#8.)
14. **[MINOR]** Release that fails BOTH `rm -rf` and rename-aside still logs
    RELEASED and returns 0 — false success while waiters wedge until the stale
    window. Return distinct status. (bash#9.)
15. **[MINOR]** Outside any repo the CLI silently "succeeds" with a CWD-scoped
    lock (sh:88-90 fallback; ps1 same). Make `run` hard-fail when not in a git
    repo; keep the soft fallback only for sourcing, with a warning. (bash#10.)
16. **[MINOR]** Token I/O robustness asymmetry: bash has zero retries on token
    write/read (a Windows sharing-violation transient → false "stolen", exit
    2); ps1 retries 5×20ms but exhaustion both cries stolen AND leaves a live
    ownerless lock until the stale window. Add/lengthen retries; distinguish
    "token unreadable, dir present" from a real mismatch. (bash#11, PS#8.)
17. **[MINOR]** ps1 `run` with no command, or `run --` alone, acquires and
    releases the lock around an empty scriptblock and exits 0 (bash exits 2
    usage). `@($null).Count -eq 1` defeats the guard; `[1..0]` reverse-range
    on the `--` path. (PS#5, Codex#5.)
18. **[MINOR]** ps1 `run` with multiple arguments re-joins with spaces and
    re-parses, destroying quoting (`run Write-Output 'two words'` → split).
    Error (or quote) when more than one token. (PS#6.)
19. **[MINOR]** Dot-sourcing the ps1 flips the caller's `$ErrorActionPreference`
    to Stop and turns StrictMode off for the session, injects ~12 vars +
    functions; and there is no bash-EXIT-trap equivalent (forgotten
    `try/finally` → orphan lock for the full stale window). Scope the
    preferences; consider a `PowerShell.Exiting` event. (PS#4.)
20. **[NIT]** Grave/tmp litter: failed deletes leave `commit.lock.dead.*` /
    `.rel.*` (both impls) and `.new.*` (ps1) dirs in `.git/` forever; sweep
    opportunistically at acquire. (bash#12, PS#9.)
21. **[NIT]** Lock log grows unboundedly (~2 lines/commit). Size cap or
    rotation note. (bash#13.)
22. **[NIT]** `STALE >= MAX_WAIT` misconfiguration unguarded — other waiters
    then time out before any steal is possible, contradicting the comment at
    sh:67-68. Warn or auto-raise. (bash#14.)
23. **[NIT]** sh:34 header says files inside the lock dir are "for
    ownership/logging only" — the token file is load-bearing for theft
    detection (docs scope the claim correctly). Reword. (bash#15.)
24. **[NIT]** sh:20 still says "our Cygwin/Git-Bash environment" — last
    private-setup phrasing in a published file. (docs#6.)

## Tests — gaps and quality (mutation results pending; will append as items 48+)

25. **[MAJOR]** The mtime-floor (FILETIME-zero) guard has NO deterministic test
    in either suite — deleting the `-gt 946684800` clause passes everything.
    A ~3s test exists (verified by probe). (tests#1.)
26. **[MAJOR]** Worktree-gets-own-lock (README/docs guarantee) untested — no
    `git worktree add` anywhere. (tests#2.)
27. **[MAJOR]** EXIT-trap release on signal/death untested; a test would also
    document the ps1's asymmetry (no trap equivalent). (tests#3.)
28. **[MAJOR]** The sourced APIs (`lock_acquire`/`lock_release` bash;
    `Lock-Acquire`/`Lock-Release` ps1) have zero direct coverage — every test
    goes through `run`. (tests#4.)
29. **[MAJOR]** Acquire-timeout path (exit 1, command not run) untested.
    (tests#5.)
30. **[MAJOR]** Release-recovery rename-aside (sh:203-207 / ps1:236-245)
    untested — needs an open-handle simulation on Windows; at minimum document
    why in the suite. (tests#6.)
31. **[MAJOR]** ps1-side behavioural parity untested: non-zero exit-code
    propagation, robbed-holder→2, uncontended slow holder, orphan steal — all
    covered for bash only. (tests#7.)
32. **[MAJOR]** Default-lock-location regression test (the gap that let item 1
    survive): an interop case with `AGENT_LOCK_DIR` unset asserting both
    sides resolve `<gitdir>/commit.lock`. The new integration suite exercises
    defaults behaviourally; add the explicit assertion too. (PS#11.)
33. **[MAJOR]** Interop T1's exclusion probe has a blind window (non-overlapping
    write→30ms→read windows miss real double-holds) and excuses workers that
    fail to launch (NOTE, not failure) — cross-impl exclusion rests on a
    probabilistic probe. Port the bash suite's deterministic lost-update
    counter cross-impl. (tests#17, Codex#4.)
34. **[MAJOR]** Timing-margin flakes: interop T2/T3 give the holder only
    0.6-0.8s vs pwsh cold-start (≥1s under load); TEST T4 0.5s, T4b 1.5s with
    STALE=1 exposed to whole-second mtime truncation. False-FAIL direction.
    Fix with ready-markers (waiter starts only after holder's marker file).
    (tests#12.)
35. **[MINOR]** TEST T4b accepts any non-zero robbed-holder rc; contract says
    exactly 2 — tighten (verified 2 today). (tests#8.)
36. **[MINOR]** TEST T2 and INTEROP T4/T5 lack `AGENT_LOCK_MAX_WAIT` caps — a
    steal regression fails only after 420s each. (tests#13.)
37. **[MINOR]** TEST T6 asserts the LOG lands in the git dir, not the lock dir
    — docs claim "git-dir lock location" coverage it doesn't have. (tests#9.)
38. **[MINOR]** INTEROP T5's "stale lock left by pwsh" is actually created by
    bash `mkdir -p` (the pwsh preamble releases cleanly first). Make the pwsh
    side die mid-hold, or rename the test. (tests#14.)
39. **[MINOR]** Both suites `rm -rf $WORK` unconditionally on EXIT — failure
    post-mortems destroyed. Keep `$WORK` (print path) when FAIL>0; converges
    with the CI plan's preserve-logs knob. (tests#15.)

## Docs / ancillary

40. **[MAJOR]** docs/git-commit-lock.md tells readers to run the tests from
    `~/.local/bin` (lines 199-200) and its Files table claims all four files
    are installed there — install.sh links only the two scripts. Commands fail
    as written. (docs#1.)
41. **[MAJOR]** docs:115 PowerShell example has UNESCAPED `$LASTEXITCODE` — the
    interpolation happens before the lock runs, so the guard becomes
    `if (0 -eq 0)` and the commit runs even when `git add` failed. Every other
    instance in the repo escapes it. (docs#2.)
42. **[MINOR]** Doc never states defaults for POLL/MAX_WAIT/LOG though the
    README defers to it for exactly that. (docs#3.)
43. **[MINOR]** Insider remnants in the doc: "see below" pointing backwards
    (line 192); the WSL/SSH-signing failure stated as universal rather than
    setup-conditional (92-95, 117-118); private-fleet anecdotes; "Last
    verified 2026-06-03" will silently stale. (docs#4.)
44. **[MINOR]** .gitattributes comment still names pre-rename `commit-lock.sh`.
    (docs#5.)
45. **[MINOR]** install.sh: `~/.local/bin` existing as a FILE dies with a raw
    mkdir error; `ln -sf` silently clobbers a regular file at the destination
    and the "was:" line misreports it as `(none)`. (docs#7.)
46. **[MINOR]** README "the lock is released even if the shell dies mid-hold"
    overstates — traps don't run on SIGKILL/crash/power loss; stale-timeout is
    the recovery there. Reword. (Codex#6.)
47. **[NIT]** README's WSL warning covers all suites; the `C:/…` path rationale
    only applies to the interop suite. (docs#9.)

also delete html comment at top of doc

## Linting (baselines run 2026-06-10 on pre-fix-wave files; final pass after the wave)

48. **[MINOR]** shellcheck (0.11.0): 3 warnings across the five shell scripts —
    2× SC2155 (declare-and-assign masks the command's exit status) and 1×
    SC2034 (unused variable); ~40 info/style notes (SC2015 `A && B || C`,
    SC2310/SC2312 errexit-interaction notes) deserve one review pass given the
    tool's errexit-sensitive nature. Fix warnings; triage info-level
    deliberately (suppress with directives + rationale where the pattern is
    intentional).
49. **[MINOR]** PSScriptAnalyzer (1.25.0): 10× PSAvoidUsingEmptyCatchBlock —
    all deliberate swallow-and-continue sites; add SuppressMessage
    attributes/justifications rather than changing behaviour. 1×
    PSUseBOMForUnicodeEncodedFile — same encoding issue as item 10; whichever
    of em-dash-removal/BOM the fix wave lands, make the analyzer clean.
    Add both linters as a CI job (gate at warning severity, documented
    exclusions) — fold into the CI plan reconciliation.

## Mutation-testing results (run 2026-06-10; evidence in .agent-testing/mutation/)

Mutation runs CONFIRMED zero/weak coverage already tracked as items 25 (bash
mtime floor — survived in bash, only ~50%-probabilistic via ps1), 27
(EXIT/INT/TERM trap — removing it entirely still passes 19/19), 31 (ps1
stolen-lease detection AND ps1 exit-code propagation — both survived; a robbed
ps1 holder even deleted a successor's live lock unnoticed), 33/34/36/37/38
(static confirmations). Re-review acceptance criterion: the fix wave's new
tests must KILL these specific mutations. Six other bash-targeted mutations
were killed — the bash suite's core is genuinely strong, and the two-holders
release regression is covered deterministically (better than its comment
claims). Note: ps1 mutations were measured against the pre-b5bf803 file.

New items:

50. **[MINOR]** Interop T1 passes vacuously with ZERO workers launched (the
    gate is all-counts-zero-clean; launch failures only NOTE). Add a
    minimum-acquired floor (e.g. ≥ half) while keeping the flake allowance.
51. **[MINOR]** Concurrent appends to the single shared lock log are silently
    swallowed (`catch {}` / `|| true`), so the interop balance gate
    (released==acquired by grep count) can false-fail AND could mask a real
    imbalance. Use per-worker logs or count RELEASED of distinct tokens.
52. **[NIT]** The ps1 post-create mtime stamp and the token write/read retry
    loops have no individual coverage (fault injection would be needed);
    keep them as defence-in-depth but reword comments that imply the
    self-tests guard them.

## Performance pass (analysis 2026-06-10; suite slowness = fork fan-out, not sleeps; full report in session log)

53. **[MINOR]** Lazy gitdir resolution: both impls run `git rev-parse` at load
    even when AGENT_LOCK_DIR is explicitly set (every non-default-path test).
    Resolve lazily; the default path stays covered by the tests that test it.
    Biggest single win (~2 forks × 200 invocations in unit T1 alone).
54. **[MINOR]** Replace hot forks in the sh impl with builtins: `_lock_now` →
    `printf '%(%s)T' -1` (with `date` fallback for macOS bash 3.2),
    `hostname` → `$HOSTNAME`, `tr`-based digit check → `case`. ~30% of
    per-invocation cost; speeds production use too.
55. **[MINOR]** Convert remaining fixed sleep-holds to marker-polling (unit
    T4b/T6/T8/T10/T11, interop T8a/T8b/T9, T4c 3s→2s, T9 MAX_WAIT 2→1,
    parallelise interop T7's two CLI calls). ~12-14s unit + ~9-12s interop;
    also removes vacuous-pass/spurious-fail load sensitivity.
56. **[MINOR]** Add a one-line `WAITING` log entry on the first blocked poll
    iteration (both impls, contended path only): lets unit T4 / interop T2/T3
    positively assert the waiter actually contended (impossible today — they
    pass vacuously if the holder finishes early) AND replaces their fixed 2-3s
    holds with hold-until-WAITING-observed. Faster and stronger.
    Do NOT touch the slow-for-good-reason set: unit T1's 8×25/poll-rate/gap,
    interop T1/T6 fan-out, stale-window waits, unit T9's MAX_WAIT, the
    integration suite's real-commit costs.

## Fresh-context review of the lockfile plan (2026-06-10)

57. **[NIT]** docs/git-commit-lock.md:42 opens with "`flock` is unavailable in
    Git-Bash/Cygwin environments", but the new "Why not flock" section it
    points to is more precise: absent from Git for Windows (verified — no
    `flock(1)` on this box's MINGW bash), while Cygwin/MSYS2 *can* install one
    that is in any case invisible to .NET. Tighten the intro line to match the
    section (e.g. "not reliably available, and never cross-runtime — see
    below").