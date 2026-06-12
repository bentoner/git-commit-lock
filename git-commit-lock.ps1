# git-commit-lock.ps1 - the git-commit-lock mutex (PowerShell port).
# Reachable at runtime as ~/.local/bin/git-commit-lock.ps1
# (symlinked there by this repo's install.sh).
#
# Works on PowerShell 7+ (pwsh) and on Windows PowerShell 5.1 - 5.1 is
# covered by an interop smoke lane (git-commit-lock.interop.test.sh Test 17),
# not just claimed. The file is plain ASCII, so the BOM-less encoding parses
# identically on both engines - keep it ASCII.
#
# PowerShell port of git-commit-lock.sh, for agents whose native shell is PowerShell
# (notably Codex on Windows). It is WIRE-COMPATIBLE with git-commit-lock.sh: the lock
# is the same regular FILE created with an atomic create-or-fail open, whose CONTENT
# is the ownership token (line 1, "tok."-prefixed; line 2 the informational
# "pid=<pid> host=<host>" owner), with the same file-mtime staleness /
# CLAIM-SERIALIZED steal / token-compare-release protocol - so a .ps1 holder and a
# .sh holder in the SAME working tree (e.g. Codex and Claude) correctly serialise
# against EACH OTHER. The claim file (`${AGENT_LOCK_PATH}.next`, identical wire
# format, the claimant's OWN per-attempt token) is shared wire format too: to
# steal a stale lock either implementation must first win the O_EXCL claim
# create; the claim is touched fresh and renamed OVER the stale lock; both
# sides parse, age (AGENT_LOCK_CLAIM_STALE_SECS) and clear each other's
# claims. git-commit-lock.sh remains the authoritative design (its header
# carries the full protocol: lock/claim file format, staleness, the steal
# protocol's ordered install sequence, token-checked claim deletion, the
# ownership-discovery rule, the leaked-token memory, per-attempt tokens,
# acquire verification, fail-open lease ceiling, known residual races);
# docs/git-commit-lock.md is the "why". Keep the two in lock-step.
#
# WHY A SEPARATE PS PORT (instead of Codex calling git-commit-lock.sh):
#   On Windows the bare name `bash` on the plain PATH resolves to
#   C:\Windows\system32\bash.exe = the WSL launcher, whose Linux git cannot reach
#   the Windows SSH signer (the private key isn't in WSL, and SSH-agent
#   forwarding into WSL typically only fires in *interactive* shells, not an
#   agent's `bash -c`).
#   So a bash-wrapped commit under Codex runs WSL git and fails to sign
#   ("No private key found ... fatal: failed to write commit object"). Codex's
#   native shell is PowerShell, where `git` = Git-for-Windows and signs fine, so
#   running the lock + commit in PowerShell avoids bash/WSL entirely. Claude keeps
#   using git-commit-lock.sh (it ships its own MINGW64 Git-Bash, immune to this).
#
# PORT-SPECIFIC NOTES (where this implementation differs in MECHANISM, never
# in protocol, from git-commit-lock.sh):
#   * Acquire is one [IO.File]::Open(CreateNew) - atomic create-or-fail - and
#     the token+owner content is written, flushed and closed THROUGH that
#     creation handle, so the write is bound to the file object we created and
#     cannot land on a successor's file. ANY exception on the open means
#     "contended/refused", not an error: an existing directory at the path
#     throws UnauthorizedAccessException (verified, pwsh 7.5), not IOException,
#     and must degrade to the wait loop's config warning, never throw out.
#   * The pre-create type guard is LOAD-BEARING here on Windows, not just
#     symmetry with bash: CreateFile resolves a symlink at the final path
#     component, so CreateNew on a DANGLING symlink tunnels through the link
#     and creates the TARGET (probed 2026-06-11) instead of failing like
#     POSIX O_CREAT|O_EXCL. The guard routes any non-regular-file path to the
#     never-steal warn lane before the create is attempted. (On Unix, .NET's
#     open uses O_CREAT|O_EXCL, which refuses symlink/FIFO/device paths with
#     an exception; the guard is symmetry there.)
#   * All reads of the lock file go through a FileStream opened with
#     FileShare ReadWrite|Delete (never ReadAllText's Read-only share), so our
#     own readers can never block another party's steal rename or release
#     unlink, even transiently (probe D2).
#   * The steal's content guard determines "empty" by STAT (Length -eq 0)
#     WITHOUT opening the file, and opens for read only when size > 0: on
#     Unix a FIFO at the lock path is neither a container nor a reparse
#     point, and a read-open on a writer-less FIFO blocks in open(2) before
#     any timeout logic runs. ACCEPTED RESIDUAL (ps1-on-Unix only; bash
#     refuses all of these via its `[ -f ]` guard): a typo'd-path FIFO -
#     and likewise a device node or socket, for which .NET has no clean
#     portable type probe - stats as size 0 and takes the empty-orphan
#     steal lane (replaced by the steal's rename-over), so damage is capped
#     at the one misconfigured inode (in practice /dev permissions make real
#     device nodes unrenamable anyway). Same accepted class as the
#     empty-user-file residual. The SAME residual applies at the CLAIM path
#     (CI-only configuration): a FIFO/device/socket at `${LOCK}.next` passes
#     the plain-file probe, stats as size 0, and - once aged - takes the
#     empty-claim CLEAR lane (CLAIM-STALE-CLEARED unlinks it). bash refuses
#     it via `[ -f ]` and warns; consequence for tests: the claim wrong-type
#     "refused" assertions are bash-only.
#   * RENAME-OVER, the steal's install op (the claim file becomes the lock):
#     - pwsh 7 / .NET Core: the 3-arg atomic overwrite overload
#       [IO.File]::Move($src, $dst, $true). Probed (P1, 2026-06-12, NTFS):
#       400 replaces under a tight reader loop, ZERO absent reads, ZERO torn
#       reads - the no-path-absent-window property, like bash's `mv`.
#     - Windows PowerShell 5.1 / .NET Framework has no such overload (and
#       File.Replace was REJECTED in design review: it throws on a read-only
#       destination and has partial-failure states without a backup file),
#       so the 5.1 steal completes as: UNLINK the ghost, then 2-arg
#       fail-if-exists Move the claim in. The transient absent window
#       between unlink and Move is safe UNDER THE CLAIM: a rival waiter's
#       create landing in it merely wins the lock - our Move fails-if-exists
#       (probed: exactly 1 of 6 concurrent Moves wins, P3c), a fairness
#       loss, never a clobber. Ladder sub-lanes: ghost already gone before
#       the unlink -> CLAIM-ABORT (gone), the Move is NOT attempted; unlink
#       blocked by a no-delete-share handle -> the damped blocked-steal lane.
#     - BOTH lanes preserve the SOURCE's mtime exactly (probed P2, both
#       engines), so the installed lock's lease starts at the claim's
#       pre-rename touch, as the protocol requires.
#     - A DIRECTORY destination is refused by .NET's Move itself with both
#       files intact (probed P5/Q3, both engines, both forms - native
#       `mv -T` semantics): no extra dir guard is needed, unlike bash's
#       no-`-T` fallback.
#   * ACCEPTED RESIDUAL (this port, Windows): .NET's rename uses CLASSIC
#     Windows semantics, not FILE_RENAME_POSIX_SEMANTICS - so the rename-over
#     fails (UnauthorizedAccessException) while ANY rival handle is open on
#     the destination, even one granting full ReadWrite|Delete sharing
#     (probed Q4: 129/400 attempts deferred under a tight reader loop).
#     Cygwin/MSYS `mv` uses POSIX semantics, so bash is immune. The failure
#     leaves both files intact and routes into the damped blocked-steal lane
#     (claim deleted immediately, re-poll) - a transient DEFERRAL of the
#     steal by one poll, never an atomicity break or a clobber. Steals only
#     happen on crashed/stale locks, so the cost is recovery latency under
#     reader contention, bounded by the poll cadence.
#   * The claim's pre-rename TOUCH is [IO.File]::SetLastWriteTimeUtc -
#     non-creating by construction; on a missing claim it throws
#     FileNotFoundException (probed Q1, both engines; PowerShell wraps it in
#     MethodInvocationException, so the catch walks the inner-exception
#     chain), which IS the gone signal the discovery rule keys on (bash needs
#     an explicit -e check instead, `touch -c` exiting 0 on missing).
#   * Release is File.Delete with a brief retry (~5x20ms) and NO rename-aside
#     fallback: probe D1 shows the handle class that blocks our unlink blocks
#     a rename identically for files (both need DELETE access on the source),
#     so the fallback could never fire usefully. One non-handle exception: the
#     Windows READ-ONLY attribute fails File.Delete but not File.Move (and
#     bash `rm -f` clears it). Nothing in the protocol ever sets read-only;
#     if something external does, the leftover warning fires and the stale
#     steal (a rename) recovers the path.
#   * The trap equivalent: bash installs EXIT/INT/TERM handlers at acquire
#     start (claim-window cleanup mode). PowerShell has no traps; the
#     equivalents here are (a) a try/finally INSIDE Lock-Acquire - PowerShell
#     executes finally blocks on Ctrl+C/pipeline-stop and on terminating
#     errors, the engine's nearest "trappable exit" - which runs the
#     token-checked claim deletion (one bounded retry) + the final discovery
#     read, releasing a discovery-HOLD inline per the NORMAL release rules
#     (boundary re-read, bounded delete retries, honest LEFTOVER warning -
#     never a false RELEASED; no 98 semantics on a mere claim; a hard kill
#     is the untrappable lane, residual 5); and (b) the
#     existing best-effort PowerShell.Exiting backstop for a HELD lock
#     (registered by the shared take-hold helper, so steal- and
#     discovery-acquired holds get it exactly like create-acquired ones).
#     The cleanup path sticks to .NET primitives ([Threading.Thread]::Sleep,
#     [IO.File]) because cmdlet invocation inside a stopping pipeline's
#     finally can throw PipelineStoppedException. Same residual-5 class as a
#     mid-create signal (see the bash header's trap-time rule): a claim
#     create failing AFTER line 1 reached disk (e.g. ENOSPC mid-write)
#     leaves an own-token claim the process doesn't know it wrote.
#   * Future option, this side only (recorded per the plan; NOT implemented):
#     handle-based ops (open with delete sharing, fstat the mtime / read the
#     token / delete via FILE_DISPOSITION on that one handle) could close the
#     residual check-then-act windows outright here. bash has no handle
#     persistence, so the protocol-level claim stays "shrunk, detected, not
#     closed" - see KNOWN RESIDUAL RACES in git-commit-lock.sh.
#
# PROBE RECORDS (this port; Win11 NTFS, pwsh 7.5.5 + Windows PowerShell
# 5.1.26100, 2026-06-12 - see also the bash header's R1-R4 and the shared
# A/C/D1/F records):
#   P1  3-arg File.Move overwrite: 400 atomic replaces, zero absent/torn
#       reads when it succeeds (pwsh 7; the overload is absent on 5.1).
#   P2  both rename lanes preserve the source's mtime EXACTLY (tick-level) -
#       the lease rule rides on this.
#   P3  2-arg Move is atomic fail-if-exists (1 of 6 concurrent winners; loser
#       sources intact); File.Delete is silent on a missing file (so the 5.1
#       ladder's gone-detection is the pre-delete existence check).
#   P4/Q1  SetLastWriteTimeUtc refreshes mtime without touching content;
#       on a missing file it throws FileNotFoundException and creates
#       NOTHING - the non-creating touch + its gone signal.
#   P5/Q3  Move onto a DIRECTORY throws (3-arg: UnauthorizedAccessException;
#       2-arg: IOException) with dir + source intact, source NOT moved into
#       the dir - native `mv -T` semantics on both engines.
#   P6  a no-delete-share handle on the dest blocks 3-arg Move AND
#       File.Delete alike (everything intact) - the blocked-steal lane.
#   Q4  3-arg Move fails on a dest held open EVEN with ReadWrite|Delete
#       sharing (classic, non-POSIX rename) - the accepted deferral residual
#       above.
#   Q5  File.Delete of a dest whose open handle grants Delete sharing
#       succeeds and frees the NAME immediately (POSIX delete on Win11), and
#       the freed name is immediately re-creatable - the 5.1 ladder is not
#       blocked by friendly readers.
#   (SUPERSEDED, kept for history: the wave-1 hard-link probes - New-Item
#   -ItemType HardLink without -Force refuses an existing destination and
#   preserves the inode mtime - backed the grave-token restore removed
#   2026-06-11/12 with the claim protocol.)
#
# USAGE (Codex's normal path - run ONE quoted command string under the lock):
#   & ~/.local/bin/git-commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
#
# EXIT CODES of `run` (identical contract to git-commit-lock.sh):
#   the command's own exit code - including a code set via `exit N` INSIDE the
#       command (the command runs as a child script, so its `exit` is contained
#       and propagates cleanly; it does not abort the lock release);
#   96  usage / configuration error: bad arguments, more than one command
#       argument, an empty or unparseable command, or `run` outside a git repo
#       with AGENT_LOCK_PATH unset. The lock was NEVER acquired and the command
#       NEVER ran. An explicit --help/-h/-? is NOT an error: usage goes to
#       stdout, exit 0.
#   97  timed out waiting for the lock (AGENT_LOCK_MAX_WAIT). The command
#       NEVER ran.
#   98  the lock was STOLEN mid-hold (held past the stale window while a
#       contender waited): at release the lock file is GONE, or carries a
#       non-empty FOREIGN token - both definitive, because acquire's read-back
#       verified our token at the path. The command DID run but was NOT
#       serialised - verify with `git log` and redo it under the lock.
#   1   the command itself threw a terminating error; or its FINAL statement
#       failed without setting a native exit code (a failing cmdlet's
#       non-terminating error never sets $LASTEXITCODE - the full verdict
#       table is at Invoke-WithLock; a one-line note goes to stderr); or
#       (with its own distinct warning) the lock file still reads EMPTY after
#       the release-time retry ladder while the file is present: ownership is
#       unverifiable (that is the create->write window of a successor after a
#       boundary steal, or external truncation - not proof of theft), the
#       file is left in place, and success is NOT reported. A failing command
#       keeps its own exit code. Same verdicts as git-commit-lock.sh for the
#       same on-disk states.
#
#   KNOWN LIMITATION of the failing-cmdlet mapping: only the command string's
#   FINAL statement is consulted (via the staged child script's closing $?).
#   A non-terminating error in the MIDDLE of the command followed by a
#   succeeding final statement is invisible (exit 0) - the same blind spot as
#   bash's last-command $?. Chain with `if ($?) { ... }` /
#   `if ($LASTEXITCODE -eq 0) { ... }` if intermediate failures must gate
#   later steps.
#   Avoid exit codes 96-98 as meaningful codes of your own command: they are
#   reserved by this contract and a wrapped command exiting 98 is
#   indistinguishable from a stolen lock.
#
#   RESIDUAL CAVEAT: a command that calls [Environment]::Exit() (a hard CLR
#   process kill, unlike plain `exit`) bypasses release entirely - the lock is
#   left held until the stale window reclaims it and no 96-98 mapping happens.
#   Plain `exit N` inside the command is fine.
#
#   Chain steps inside the command with `if ($LASTEXITCODE -eq 0) { ... }`
#   rather than `&&` so the string also parses on Windows PowerShell 5.1.
#
# Or dot-source for the primitives (mirrors `source git-commit-lock.sh`):
#   . ~/.local/bin/git-commit-lock.ps1
#   if (-not (Lock-Acquire)) { exit 1 }
#   try { git add -- path; git commit -m 'msg' } finally { Lock-Release | Out-Null }
#
#   Dot-source notes:
#   * Dot-sourcing injects the public functions (Lock-Acquire, Lock-Release,
#     Invoke-WithLock), the script:-scoped helpers (Lock-* / Get-Lock*),
#     and the script-scope $Lock* variables into your session. It does NOT
#     change your $ErrorActionPreference or StrictMode: both are set inside
#     the functions (function-scoped, restored automatically on return).
#   * You MUST pair Lock-Acquire with Lock-Release in try/finally - there is
#     no bash-style EXIT trap in PowerShell. A best-effort PowerShell.Exiting
#     backstop is registered while the lock is held, but it only fires in
#     hosts that raise that event (pwsh/powershell -Command and interactive
#     sessions; verified NOT to fire under -File on either engine,
#     2026-06-10), so do not rely on it.
#   * Lock-Acquire is NOT reentrant: a second Lock-Acquire while holding is
#     refused ($false, message on stderr) rather than self-deadlocking for the
#     stale window and then stealing its own lock (mirrors git-commit-lock.sh).
#   * Lock-Acquire NEVER repairs a failed post-create read-back by writing to
#     the path: after winning the create it re-reads line 1 and claims the
#     hold only on its own token; anything else (foreign, empty, gone after
#     the retry ladder) is logged loudly and treated as NOT acquired - see
#     ACQUIRE VERIFICATION in git-commit-lock.sh.
#   * Lock-Release returns $true on a clean release; $false otherwise, with
#     $script:LockReleaseStatus set to 'stolen' (file gone, or a non-empty
#     foreign token: your work was NOT exclusive - redo; `run` maps this to
#     98), 'unreadable' (the file still reads EMPTY after the retry ladder
#     while present, or persistently would not open: exclusivity unproven,
#     file left in place for the staleness backstop; do not report success),
#     or 'leftover' (token verified - the work WAS exclusive - but the file
#     could not be deleted; it is left blocking waiters until the stale
#     window elapses AND the blocking handle closes - the same handle blocks
#     a stealer's rename (probe D1), so until then waiters re-poll and may
#     reach 97; `run` keeps the command's exit code and warns on stderr,
#     mirroring git-commit-lock.sh).
#
# Hold the lock ONLY for the stage+commit (seconds). Decide what to stage,
# build any patch, resolve hook failures OUTSIDE the lock. See README.md
# ("Suggested agent instructions").
#
# CONFIG (env, mainly for tests) - identical names/semantics to git-commit-lock.sh:
#   AGENT_LOCK_PATH (lock file path; default <gitdir>/commit.lock; the claim
#   lives beside it at ${AGENT_LOCK_PATH}.next),
#   AGENT_LOCK_STALE_SECS (default 300), AGENT_LOCK_CLAIM_STALE_SECS (claim
#   ageout, default 60 - claims are normally held for milliseconds),
#   AGENT_LOCK_POLL_SECS (default 2), AGENT_LOCK_MAX_WAIT (default 420; keep
#   it > STALE + CLAIM_STALE - a warning is printed when it is not, gated on
#   MAX_WAIT being left at its default), AGENT_LOCK_LOG.
#   Invalid numeric values are reported on stderr and replaced by the default
#   (never a load-time throw). STALE_SECS, CLAIM_STALE_SECS and MAX_WAIT must
#   be positive integers, POLL_SECS may be fractional - same rules as
#   git-commit-lock.sh.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
    Justification = 'Deliberate throughout: lock-path I/O must never abort the holder. Every swallow is conservative (retry, skip, or fall through to a guarded slow path) and the file-mtime stale window is the recovery backstop. See docs/git-commit-lock.md.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Deliberate, one variable: $global:__gclRunOk carries the staged child script''s final $? back to the runner - the global scope is the only one shared across the `& file.ps1` boundary (the caller-side $? reads True even when the script''s last cmdlet failed; probed on both engines 2026-06-11). Sentinel-initialised before each run and removed in the finally.')]
param(
    [Parameter(Position = 0)]
    [string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

# NOTE (dot-source hygiene): no Set-StrictMode / $ErrorActionPreference at the
# top level - dot-sourcing executes top-level statements in the CALLER's scope
# and would silently reconfigure their session. Each function below sets its
# own (function-scoped) preferences instead. Top-level code is strict-mode-safe.

# --- resolve defaults (git-dir aware, CWD-independent within the repo) --------
# Mirrors git-commit-lock.sh: lock + log live in `git rev-parse --absolute-git-dir`
# (e.g. C:/repo/.git/commit.lock). Windows git prints a forward-slash drive path
# (C:/repo/.git), exactly what MINGW git prints for git-commit-lock.sh, so both sides
# compute the SAME lock-path string and contend on the same NTFS file.
function script:Get-LockGitDir {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    $gd = $null
    try {
        # Collect ALL output - do NOT pipe through `Select-Object -First 1`:
        # -First stops the upstream native command early, and on pwsh 7.5 that
        # reliably leaves $LASTEXITCODE unset, which read as "git failed" and
        # silently fell back to CWD - putting the default lock at
        # <cwd>/commit.lock instead of <gitdir>/commit.lock, so the .ps1 and
        # .sh sides no longer contended on the same lock (caught by
        # git-commit-lock.integration.test.sh, 2026-06-10).
        $out = @(& git rev-parse --absolute-git-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) { $gd = [string]$out[0] }
    } catch { $gd = $null }
    if ($gd) { return ([string]$gd).Trim() }
    return $null
}

# Validated numeric config: garbage in an AGENT_LOCK_* var must never throw at
# load (this file is dot-sourced into agent sessions) - note it on stderr and
# fall back to the default instead.
function script:Get-LockNum {
    param([string]$Name, [string]$Raw, [double]$Default, [switch]$IntegerOnly)
    Set-StrictMode -Off
    # EMPTY (or unset) means "use the default", silently - exactly like
    # git-commit-lock.sh's ${VAR:-default}. Whitespace-only is NOT empty
    # there (it reaches the validator and earns the stderr note), so it must
    # fall through to the shape gates below, not early-return here.
    if ([string]::IsNullOrEmpty($Raw)) { return $Default }
    $val = 0.0
    $ok = [double]::TryParse($Raw, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)
    # Integer knobs (STALE_SECS / MAX_WAIT) take plain digit strings only,
    # exactly like git-commit-lock.sh's validator: a fractional stale window
    # would otherwise be silently rounded here but rejected there - same
    # input, different steal threshold across the two impls. Anchors are
    # \A..\z, not ^..$: .NET's $ also matches BEFORE a trailing newline (and
    # TryParse tolerates trailing whitespace), so "5\n" would configure this
    # side while bash rejects it - same env var, different knob values.
    if ($IntegerOnly -and $Raw -notmatch '\A[0-9]+\z') { $ok = $false }
    # The fractional knob (POLL_SECS) takes the same raw shape as
    # git-commit-lock.sh's grammar: digits with at most one dot and at least
    # one digit (e.g. "2", "0.5", ".5"). TryParse(Float) alone is WIDER - it
    # accepts exponents ("1e3" = 1000s between polls!), signs ("+2") and
    # leading/trailing whitespace, all of which bash rejects, so the same
    # env var would configure different poll intervals across the two impls.
    if (-not $IntegerOnly -and $Raw -notmatch '\A(?=.*[0-9])[0-9]*\.?[0-9]*\z') { $ok = $false }
    if (-not $ok -or $val -le 0) {
        $want = 'positive number'; if ($IntegerOnly) { $want = 'positive integer' }
        [Console]::Error.WriteLine("git-commit-lock: ignoring invalid $Name='$Raw' (want a $want); using default $Default")
        return $Default
    }
    return $val
}

# Lazy gitdir resolution (perf): the `git rev-parse` child process exists only
# to DEFAULT the lock/log paths, so skip it entirely when BOTH are explicit
# (the common test/sub-agent-override case). When only AGENT_LOCK_PATH is
# explicit the log still defaults into the git dir, so the resolution stays.
# (Mirrors git-commit-lock.sh.) The two not-in-repo guards below stay correct
# when skipped: both are gated on AGENT_LOCK_PATH being unset.
if ($env:AGENT_LOCK_PATH -and $env:AGENT_LOCK_LOG) {
    $script:LockGitDir = $null
} else {
    $script:LockGitDir = script:Get-LockGitDir
}
$script:LockInRepo = [bool]$script:LockGitDir
if ($script:LockInRepo) { $script:LockBase = $script:LockGitDir } else { $script:LockBase = (Get-Location).Path }
# Not in a repo: the CLI `run` path hard-fails (exit 96) unless AGENT_LOCK_PATH
# is set; dot-sourcing keeps the CWD fallback (so sourcing never explodes) but
# says so out loud.
if (-not $script:LockInRepo -and -not $env:AGENT_LOCK_PATH -and $MyInvocation.InvocationName -eq '.') {
    [Console]::Error.WriteLine("git-commit-lock: WARNING - not inside a git repository; defaulting the lock to $script:LockBase/commit.lock (CWD). Set AGENT_LOCK_PATH to control this.")
}

if ($env:AGENT_LOCK_PATH) { $script:LockPath = $env:AGENT_LOCK_PATH } else { $script:LockPath = "$script:LockBase/commit.lock" }
if ($env:AGENT_LOCK_LOG) { $script:LockLog = $env:AGENT_LOCK_LOG } else { $script:LockLog = "$script:LockBase/git-commit-lock.log" }
$script:LockStale      = [int](script:Get-LockNum -Name 'AGENT_LOCK_STALE_SECS' -Raw $env:AGENT_LOCK_STALE_SECS -Default 300 -IntegerOnly)
$script:LockClaimStale = [int](script:Get-LockNum -Name 'AGENT_LOCK_CLAIM_STALE_SECS' -Raw $env:AGENT_LOCK_CLAIM_STALE_SECS -Default 60 -IntegerOnly)
$script:LockPoll       = [double](script:Get-LockNum -Name 'AGENT_LOCK_POLL_SECS' -Raw $env:AGENT_LOCK_POLL_SECS -Default 2)
$script:LockMaxWait    = [int](script:Get-LockNum -Name 'AGENT_LOCK_MAX_WAIT' -Raw $env:AGENT_LOCK_MAX_WAIT -Default 420 -IntegerOnly)

# Worst-case recovery stacks BOTH ageouts: a crashed holder costs a full
# STALE window, and a crashed claimant on top costs a CLAIM_STALE window
# before the steal can complete - so a waiter needs MAX_WAIT > STALE +
# CLAIM_STALE to be guaranteed a recovery chance before giving up (defaults:
# 300 + 60 < 420). Warn only in the documented footgun case - knobs raised
# while MAX_WAIT was left at its default; a caller who set MAX_WAIT chose the
# relationship deliberately (test suites do this constantly). This warning
# REPLACES the former STALE >= MAX_WAIT warning (2026-06-11): it strictly
# subsumes it under the same left-default explicitness gate. (Mirrors
# git-commit-lock.sh.)
if (-not $env:AGENT_LOCK_MAX_WAIT -and $script:LockMaxWait -le ($script:LockStale + $script:LockClaimStale)) {
    [Console]::Error.WriteLine("git-commit-lock: warning - AGENT_LOCK_MAX_WAIT ($($script:LockMaxWait), default) <= AGENT_LOCK_STALE_SECS ($($script:LockStale)) + AGENT_LOCK_CLAIM_STALE_SECS ($($script:LockClaimStale)): waiters may time out before a crashed holder (and a crashed claimant) can be recovered; raise AGENT_LOCK_MAX_WAIT too")
}

# Floor for a PLAUSIBLE lock mtime (epoch secs; 2000-01-01). A freshly created
# file can transiently report the Windows FILETIME zero (1601-01-01 -> a NEGATIVE
# unix epoch) to an observer (probes C/C1b - files, not just the old dirs), which
# would compute as a ~400-year "age" and trigger a spurious steal of a live,
# just-acquired lock. Any mtime below this floor is an unsettled/garbage reading,
# not a genuinely stale lock, so we refuse to steal on it and wait instead.
$script:LockMtimeFloor = 946684800

$script:LockHeld = $false
# The HOLD token: set by Lock-TakeHold from the WINNING attempt's token
# (per-attempt tokens - see PER-ATTEMPT TOKENS in git-commit-lock.sh's
# header); Lock-Release verifies the on-disk lock against it. Empty while not
# holding. pid alone isn't enough (pids get reused across the stale window),
# so tokens mix in Get-Random + the epoch + an in-process sequence number (so
# two attempts inside one second can never collide). The "tok." prefix is
# WIRE FORMAT (the steal's content guard keys on it - see LOCK FILE FORMAT in
# git-commit-lock.sh); the ".ps" marker just helps when reading a mixed log.
$script:LockToken = ''
$script:LockSeq = 0
# The claim path (set at acquire start: ${AGENT_LOCK_PATH}.next) and the
# token of the claim attempt currently in flight (non-empty exactly while a
# claim we created may exist on disk unresolved - the acquire's
# finally-block cleanup, the trap equivalent, keys on it).
$script:LockClaimPath = ''
$script:LockClaimToken = ''
# LEAKED-TOKEN MEMORY (see the rule in git-commit-lock.sh's header): array of
# attempt tokens whose claim file was left in place without a verifiable
# unlink. Almost always empty.
$script:LockLeaked = @()
$script:LockLeakWarned = $false
# Squatted-steal log damper (shared between the acquire loop and the steal
# install helper, like bash's globals): epoch of the last logged failed-steal
# attempt, 0 when the last attempt did not fail that way; and the per-attempt
# "may we log" verdict derived from it.
$script:LockStealFailLast = 0
$script:LockStealLogOk = $true
# [Environment]::MachineName, not $env:COMPUTERNAME: the latter is Windows-only,
# so `host=` would be blank on the POSIX CI legs.
$script:LockMe = "pid=$PID host=$([Environment]::MachineName)"
$script:LockRunRc = 0
# Set by Lock-Release when it returns $false: 'stolen', 'unreadable' or 'leftover'.
$script:LockReleaseStatus = 'ok'
# Set by Lock-Acquire when it returns $false: 'timeout' or 'reentrant'.
$script:LockAcquireFail = ''
# PSEventJob for the best-effort PowerShell.Exiting release backstop.
$script:LockExitJob = $null

function script:Lock-Now {
    Set-StrictMode -Off
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function script:Lock-Log([string]$msg) {
    Set-StrictMode -Off
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        # Dumb size cap (same 1MB rule as git-commit-lock.sh): if the log has
        # grown past ~1MB (it gains ~2 lines per commit and nothing ever
        # prunes it), start it over rather than rotating.
        try {
            $li = New-Object System.IO.FileInfo $script:LockLog
            if ($li.Exists -and $li.Length -gt 1048576) {
                [System.IO.File]::WriteAllText($script:LockLog, "$ts [pid=$PID] log exceeded 1MB; truncated`n")
            }
        } catch { }
        [System.IO.File]::AppendAllText($script:LockLog, "$ts [pid=$PID] $msg`n")
    } catch { }
}

# Loud, once-per-process config warning for a non-lock object at the lock path
# (a directory - e.g. a leftover old-protocol dir lock or a typo like
# AGENT_LOCK_PATH=$HOME - a symlink, or a regular file whose content is not
# lock-shaped). Such a path is NEVER stolen or deleted; waiters will reach 97
# until a human fixes the path or removes the object. CAVEAT (ps1-on-POSIX
# only, an unsupported CI-only config): FIFOs/devices/sockets are NOT routed
# here - .NET has no clean portable type probe for them, so they stat as
# length 0 and take the empty-orphan steal lane instead (the ACCEPTED RESIDUAL
# in PORT-SPECIFIC NOTES). bash, and this port on Windows, deliver the full
# never-steal guarantee.
$script:LockNonLockWarned = $false
function script:Lock-WarnNonLock([string]$reason) {
    Set-StrictMode -Off
    if ($script:LockNonLockWarned) { return }
    $script:LockNonLockWarned = $true
    [Console]::Error.WriteLine("git-commit-lock: WARNING - $script:LockPath exists but is not a lock file ($reason). Refusing to steal or delete it; waiters will time out (97). If AGENT_LOCK_PATH is a typo, fix it; if this is a stray file or a leftover old-protocol lock directory, remove it by hand.")
    script:Lock-Log "WARNING: non-lock object at lock path ($reason) - never stolen; waiters reach 97 until it is removed by hand"
}

# The claim-path twin (PER-PATH warn-once state, mirroring bash: a shared
# flag would let a lock-path warning suppress a claim-path one, hiding the
# second misconfiguration). A non-claim object squatting ${LOCK}.next blocks
# STEALS only - normal acquisition on a free lock path is unaffected - but a
# stale lock then wedges waiters to 97.
$script:LockNonLockWarnedClaim = $false
function script:Lock-WarnNonLockClaim([string]$reason) {
    Set-StrictMode -Off
    if ($script:LockNonLockWarnedClaim) { return }
    $script:LockNonLockWarnedClaim = $true
    [Console]::Error.WriteLine("git-commit-lock: WARNING - $script:LockClaimPath exists but is not a claim file ($reason). Refusing to delete it; stale locks cannot be stolen while it squats the claim path (waiters may time out, 97). If AGENT_LOCK_PATH is a typo, fix it; otherwise remove the object by hand.")
    script:Lock-Log "WARNING: non-claim object at claim path ($reason) - never deleted; steals are blocked until it is removed by hand"
}

# Link-aware existence probe: the FileSystemInfo for the path ITSELF (a
# dangling symlink included - it must read as "exists but wrong type" so the
# guard warns instead of classing it as normal contention every poll), or
# $null when the path is absent. Get-Item -Force sees the link, not the
# target; [IO.File]::Exists would report a dangling link as absent.
function script:Lock-GetItemAt([string]$Path) {
    Set-StrictMode -Off
    try { return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop) } catch { return $null }
}
function script:Lock-GetPathItem {
    Set-StrictMode -Off
    return (script:Lock-GetItemAt $script:LockPath)
}

# Is this FileSystemInfo a plain regular file (not a directory, not any kind
# of symlink/reparse point)? The only shape acquire may create over and the
# steal may rename - everything else is the never-steal config-warning lane.
# CAVEAT (ps1-on-POSIX only): this probe cannot tell a FIFO/device/socket
# from a regular file (.NET surfaces no portable type bit for them), so on
# Unix those pass as "plain", stat as length 0, and end in the empty-orphan
# steal lane - the documented ACCEPTED RESIDUAL in PORT-SPECIFIC NOTES. bash
# refuses them all via its `[ -f ]` guard; on Windows the reparse/container
# checks make this guard complete.
function script:Lock-IsPlainFile($item) {
    Set-StrictMode -Off
    if ($null -eq $item) { return $false }
    if ($item.PSIsContainer) { return $false }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

# mtime (epoch secs) of the lock file itself, stamped by the creating write -
# the staleness clock, same value the .sh side reads via `stat -c %Y`. $null
# if the file vanished mid-check. If the read keeps failing while the file
# EXISTS, staleness detection is broken on this system - crashed holders can
# then never be stolen - so say so loudly, once per process (parity with
# git-commit-lock.sh's warning). The retry loop is anti-false-alarm: under
# contention the file routinely vanishes (release/steal) between probes,
# which must not be misdiagnosed as a broken clock - only persistent failure
# on a present file counts.
$script:LockMtimeWarned = $false
function script:Lock-PathMtime {
    Set-StrictMode -Off
    $m = $null; $present = $false
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $item = Get-Item -LiteralPath $script:LockPath -Force -ErrorAction Stop
            $m = ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
            break
        } catch {
            $m = $null
            if (Test-Path -LiteralPath $script:LockPath) { $present = $true } else { $present = $false; break }
        }
    }
    if ($null -eq $m -and $present -and -not $script:LockMtimeWarned) {
        $script:LockMtimeWarned = $true
        [Console]::Error.WriteLine("git-commit-lock: WARNING - cannot read the lock file's mtime on this system. Staleness detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges waiters until AGENT_LOCK_MAX_WAIT.")
        script:Lock-Log 'WARNING: lock-file mtime unreadable (probes failed with the file present); staleness detection disabled'
    }
    return $m
}

# Read line 1 of the lock file (the token of whoever holds it now),
# distinguishing three outcomes so Lock-Release can be honest about what it saw:
#   Status='ok'         Token = line 1, trailing whitespace stripped (non-empty)
#   Status='gone'       the lock file no longer exists
#   Status='unreadable' the file exists but no token came back after escalating
#                       retries - it persistently would not open (a Windows
#                       sharing violation) or it still reads EMPTY. An empty
#                       read is the rival create->write gap (probe F) or
#                       external truncation - NOT proof of theft, and not
#                       proof of ownership either. Mirrors git-commit-lock.sh's
#                       empty-after-retries lane: BOTH impls route this state
#                       to the conservative unverifiable verdict, never to
#                       "stolen".
# Retries with escalating backoff: under heavy contention a read can
# transiently hit a sharing violation or the empty window, and crying
# "stolen" on that would be false. A REAL steal renames the file away, so a
# successful read then returns a DIFFERENT token (still a mismatch) - retrying
# never hides a genuine theft. The FileStream opens with ReadWrite|Delete
# sharing so this read can never block a rival's steal/release (probe D2).
#
# SHARED RETRY SCHEDULE (keep in lock-step with git-commit-lock.sh's
# _lock_read_tok/_lock_cur_token): up to 8 read attempts with inter-attempt
# sleeps of 20/40/80/160/320/320/320 ms - ~1.26s total budget, enough to ride
# out a sub-second transient (e.g. an AV scanner's no-delete-share open). No
# sleep follows the FINAL attempt (it would only delay the verdict). The full
# ladder runs ONLY where a verdict hangs on the read - release verification,
# the acquire read-back, the claim recheck / token-checked deletion, and the
# discovery read - never inside the acquire poll loop (the steal content
# guard and the per-poll leaked-memory read are short reads), so a healthy
# lock costs one attempt and the poll cadence is unaffected. The sleep is
# [Threading.Thread]::Sleep, not Start-Sleep: this read also runs inside the
# acquire's finally-block cleanup (the trap equivalent), where cmdlet
# invocation can throw PipelineStoppedException mid-Ctrl+C.
function script:Lock-ReadTok {
    param([string]$Path, [int]$MaxTries = 8)
    Set-StrictMode -Off
    $delay = 20
    for ($i = 0; $i -lt $MaxTries; $i++) {
        try {
            $line = $null
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $sr = New-Object System.IO.StreamReader($fs)
                $line = $sr.ReadLine()
            } finally { $fs.Dispose() }
            if ($null -ne $line) { $line = $line.TrimEnd() }   # CRLF tolerance
            if ($line) { return @{ Status = 'ok'; Token = $line } }
            # Empty read with the file present: the create->write window of a
            # rival (probe F) - retry before classifying as unverifiable.
        } catch [System.IO.FileNotFoundException] {
            return @{ Status = 'gone'; Token = '' }
        } catch [System.IO.DirectoryNotFoundException] {
            return @{ Status = 'gone'; Token = '' }
        } catch {
            # Transient open failure (e.g. a sharing violation): retry, unless
            # the file is genuinely gone.
            if (-not (Test-Path -LiteralPath $Path)) { return @{ Status = 'gone'; Token = '' } }
        }
        if ($i -lt ($MaxTries - 1)) { [System.Threading.Thread]::Sleep($delay) }
        if ($delay -lt 320) { $delay = $delay * 2 }
    }
    if (Test-Path -LiteralPath $Path) { return @{ Status = 'unreadable'; Token = '' } }
    return @{ Status = 'gone'; Token = '' }
}
function script:Lock-ReadCurToken {
    param([int]$MaxTries = 8)
    Set-StrictMode -Off
    return (script:Lock-ReadTok -Path $script:LockPath -MaxTries $MaxTries)
}

# Atomic create-or-fail for the lock or claim FILE, with the token+owner
# content written, flushed and closed THROUGH the creation handle: the write
# is bound to the file object we created and cannot land on a successor's
# file, whatever happens to the path meanwhile. CreateNew + the content write
# stamp the mtime (the staleness clock); no post-create stamp is needed - the
# floor guard is the backstop for unsettled readings. The handle shares
# ReadWrite|Delete so a waiter's probes never collide with the creation.
# Returns $true iff we created the file. ANY exception means "not created":
# IOException = a rival's live lock/claim (normal contention); an existing
# directory throws UnauthorizedAccessException; on Unix a FIFO/device path
# fails the O_CREAT|O_EXCL open with its own exception. All of them must
# degrade to the wait loop - which diagnoses the non-file cases - never throw
# out of acquire. A created-but-write-failed file (e.g. ENOSPC) returns
# $false too; the empty or torn orphan it leaves ages into its steal lane.
function script:Lock-TryCreateFile {
    param([string]$Path, [string]$Token)
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        # BOM-free UTF-8, LF line ends: the shared wire format (line 1 token,
        # line 2 owner), readable by the .sh side's plain `read`.
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes("$Token`n$script:LockMe`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
}

# --- steal-protocol helpers (claim-serialized stealing; mirrors the bash
# helpers in git-commit-lock.sh - the design rationale lives in that header).

# Fresh token per create/claim ATTEMPT (per-attempt tokens - see the bash
# header): pid + Get-Random + epoch + an in-process sequence number, so two
# attempts inside one second can never collide.
function script:Lock-NewToken {
    Set-StrictMode -Off
    $script:LockSeq = $script:LockSeq + 1
    return "tok.ps.$PID.$(Get-Random).$(script:Lock-Now).$($script:LockSeq)"
}

# Best-effort single mtime probe (epoch secs) of an arbitrary path; $null if
# unreadable/absent (mirrors bash's _lock_stat_mtime: one probe, no retries -
# the lock path's retrying variant is Lock-PathMtime below).
function script:Lock-StatMtime([string]$Path) {
    Set-StrictMode -Off
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch { return $null }
}

# Claim the hold: adopt the winning ATTEMPT token as the hold token. ONE
# helper for all three acquisition paths - create read-back, steal
# rename-over, and discovery-HOLD - so every hold runs the same
# HELD/backstop machinery (mirrors bash's _lock_take_hold).
function script:Lock-TakeHold([string]$Token) {
    Set-StrictMode -Off
    $script:LockToken = $Token
    $script:LockClaimToken = ''
    $script:LockHeld = $true
    script:Lock-RegisterExitBackstop
    script:Lock-Log "ACQUIRED ($script:LockMe tok=$script:LockToken)"
}

# The OWNERSHIP-DISCOVERY read (see the rule in git-commit-lock.sh's header):
# the unconditional final act of every post-claim-create exit that did not
# end in a successful rename. One read of the lock path's line 1 (full ladder
# - a verdict hangs on it); our attempt token there means a rival's rename
# installed OUR claim as the lock => we hold it. Returns $true iff the hold
# was taken.
function script:Lock-Discover([string]$Token) {
    Set-StrictMode -Off
    $rb = script:Lock-ReadTok -Path $script:LockPath -MaxTries 8
    if ($rb.Status -eq 'ok' -and $rb.Token -eq $Token) {
        script:Lock-Log "DISCOVERY-HOLD: our claim (tok=$Token) was installed at the lock path by a rival's rename - taking the hold"
        script:Lock-TakeHold $Token
        return $true
    }
    return $false
}

# --- leaked-token memory (see the rule in git-commit-lock.sh's header) ------
function script:Lock-LeakedAdd([string]$Token, [string]$Lane) {
    Set-StrictMode -Off
    $script:LockLeaked = @($script:LockLeaked) + $Token
    script:Lock-Log "LEAKED-CLAIM (${Lane}): claim tok=$Token left in place without a verifiable unlink - added to the leaked-token memory; polls will watch the lock path for it"
    if (-not $script:LockLeakWarned) {
        $script:LockLeakWarned = $true
        [Console]::Error.WriteLine("git-commit-lock: warning - a claim file of ours could not be verified/deleted ($Lane); its token is remembered and ownership stays discoverable (see the lock log)")
    }
}
function script:Lock-LeakedMember([string]$Token) {
    Set-StrictMode -Off
    return ([bool](@($script:LockLeaked) -contains $Token))
}
function script:Lock-LeakedDrop([string]$Token) {
    Set-StrictMode -Off
    $script:LockLeaked = @(@($script:LockLeaked) | Where-Object { $_ -ne $Token })
}
# Is the leaked token verifiably RESOLVED at the lock path? Used after the
# claim-side resolution (a verified unlink, or a gone/foreign observation)
# to decide whether the entry may DROP. Three-way (mirrors bash's
# _lock_leaked_lock_resolved, riding Lock-ReadTok's status):
#   * 'ok' with a DIFFERENT token, or 'gone' -> the leaked token sits at
#     NEITHER path and can never reappear: resolved ($true, caller drops);
#   * 'ok' with OUR token -> installed by a rival's rename: NOT resolved
#     (pending; the owner's next acquire can adopt it);
#   * 'unreadable' (present but no token after the read) -> INCONCLUSIVE:
#     the read proves nothing about whose token is installed, so the entry
#     MUST stay pending (dropping here could orphan an installed own-token
#     lock with nothing left watching for it).
function script:Lock-LeakedLockResolved([string]$Token) {
    Set-StrictMode -Off
    $lk = script:Lock-ReadTok -Path $script:LockPath -MaxTries 1
    if ($lk.Status -eq 'ok' -and $lk.Token) { return ($lk.Token -ne $Token) }
    return ($lk.Status -eq 'gone')
}
# Arc-end best-effort resolution pass (run at release, at the 97 exit, and in
# the acquire cleanup's no-hold path): for each pending entry, one
# token-checked look at the CLAIM file - the blocking handle may have closed
# by now. A verified unlink, or a gone/foreign observation, resolves the
# entry - each followed by one lock-path line-1 read before the drop
# (gone-from-.next may mean installed-at-lock; an entry whose token sits at
# the LOCK path stays pending: the owner's next acquire can adopt it; a lock
# present but unreadable at that read is INCONCLUSIVE and also keeps the
# entry - see Lock-LeakedLockResolved). Any failure leaves the entry pending
# - no waiting, no retry loops.
function script:Lock-LeakedResolvePass {
    Set-StrictMode -Off
    if (@($script:LockLeaked).Count -eq 0) { return }
    foreach ($t in @($script:LockLeaked)) {
        $cr = script:Lock-ReadTok -Path $script:LockClaimPath -MaxTries 1
        if ($cr.Status -eq 'ok' -and $cr.Token -eq $t) {
            # Still ours at the claim path: try the unlink (token-checked,
            # single best-effort attempt).
            $gone = $false
            try { [System.IO.File]::Delete($script:LockClaimPath); $gone = $true } catch { $gone = $false }
            if ($gone -and $null -eq (script:Lock-GetItemAt $script:LockClaimPath)) {
                if (script:Lock-LeakedLockResolved $t) {
                    script:Lock-LeakedDrop $t
                    script:Lock-Log "leaked-token memory: resolved tok=$t (claim unlinked at arc end)"
                }
            }
        } elseif (($cr.Status -eq 'ok' -and $cr.Token) -or ($cr.Status -eq 'gone' -and $null -eq (script:Lock-GetItemAt $script:LockClaimPath))) {
            # Foreign-tokened, or verifiably gone: the leak is resolved UNLESS
            # the token was installed at the lock path meanwhile, or the lock
            # read is inconclusive (present but unreadable).
            if (script:Lock-LeakedLockResolved $t) {
                script:Lock-LeakedDrop $t
                script:Lock-Log "leaked-token memory: resolved tok=$t (claim gone/foreign at arc end)"
            }
        }
        # present-but-empty/unreadable claim, blocked unlink, token-at-lock,
        # or an inconclusive lock read: leave the entry pending (residual-5
        # class once the process exits).
    }
}

# Classify the claim file against OUR attempt token: returns @{ State; Tok }
# with State one of ours | gone | foreign | unreadable. "foreign" includes a
# present-but-EMPTY claim: our claim's content write was verified through the
# creating handle, so an empty file is not ours - it is a rival's mid-create
# window or external truncation; either way it is left alone (it ages out).
# "unreadable" means present, non-empty, but the full read ladder came back
# blank (a sharing violation): we can NOT verify the claim is not ours, so
# callers must treat it as a possible leak.
function script:Lock-ClaimState([string]$Token) {
    Set-StrictMode -Off
    $r = script:Lock-ReadTok -Path $script:LockClaimPath -MaxTries 8
    if ($r.Status -eq 'ok' -and $r.Token) {
        if ($r.Token -eq $Token) { return @{ State = 'ours'; Tok = $r.Token } }
        return @{ State = 'foreign'; Tok = $r.Token }
    }
    $item = script:Lock-GetItemAt $script:LockClaimPath
    if ($null -eq $item) { return @{ State = 'gone'; Tok = '' } }
    $len = $null
    try { $len = (New-Object System.IO.FileInfo $script:LockClaimPath).Length } catch { $len = $null }
    if ($null -ne $len -and $len -eq 0) { return @{ State = 'foreign'; Tok = '' } }
    return @{ State = 'unreadable'; Tok = '' }
}

# TOKEN-CHECKED CLAIM DELETION (see the rule in git-commit-lock.sh's header):
# read first, unlink only if line 1 is OUR token; never blind-unlink the
# claim path. Returns one of: deleted | gone | foreign | leaked-unreadable |
# leaked-blocked. The two leaked-* outcomes append the token to the
# leaked-token memory. A delete that finds the file already gone (File.Delete
# is silent on missing) or vanishing mid-try reports 'deleted' - the claim
# left the path either way, and the discovery read every caller runs next
# decides whether it left INTO the lock path.
function script:Lock-ClaimDelete([string]$Token, [int]$Retries = 0) {
    Set-StrictMode -Off
    $cs = script:Lock-ClaimState $Token
    switch ($cs.State) {
        'gone'    { return 'gone' }
        'foreign' { return 'foreign' }
        'unreadable' {
            script:Lock-LeakedAdd $Token 'deletion-read-unreadable'
            return 'leaked-unreadable'
        }
    }
    # Ours: unlink, with the caller's bounded retry budget on a blocked unlink
    # (a no-delete-share handle can refuse the delete while the file stays).
    $try = 0
    while ($true) {
        $deleted = $false
        try { [System.IO.File]::Delete($script:LockClaimPath); $deleted = $true } catch { $deleted = $false }
        if ($deleted) { return 'deleted' }
        if ($null -eq (script:Lock-GetItemAt $script:LockClaimPath)) { return 'deleted' }   # vanished mid-try
        if ($try -ge $Retries) { break }
        $try = $try + 1
        [System.Threading.Thread]::Sleep(50)
    }
    script:Lock-LeakedAdd $Token 'deletion-unlink-blocked-while-present'
    return 'leaked-blocked'
}

# Re-judge the LOCK's staleness fresh (the step-2 / step-3.3 re-verify):
# type, mtime + floor, age, content shape. Returns @{ State; Line2 } with
# State one of:
#   stale     confirmed stale (Line2 populated for ghost attribution)
#   gone      path absent
#   fresh     not confirmable as stale (young mtime, sub-floor/unsettled,
#             unreadable mtime or content - never steal what we can't prove)
#   wrongtype not a regular file, or content not lock-shaped
# "Empty" is judged by STAT without opening (the ps1-on-POSIX FIFO rule, same
# as the poll-loop content guard).
function script:Lock-VerifyStale {
    Set-StrictMode -Off
    $res = @{ State = ''; Line2 = '' }
    $item = script:Lock-GetItemAt $script:LockPath
    if ($null -eq $item) { $res.State = 'gone'; return $res }
    if (-not (script:Lock-IsPlainFile $item)) { $res.State = 'wrongtype'; return $res }
    $mt = script:Lock-PathMtime
    if ($null -eq $mt) {
        if ($null -ne (script:Lock-GetItemAt $script:LockPath)) { $res.State = 'fresh' } else { $res.State = 'gone' }
        return $res
    }
    if ($mt -le $script:LockMtimeFloor) { $res.State = 'fresh'; return $res }   # sub-floor: unsettled
    $age = (script:Lock-Now) - $mt
    if ($age -lt $script:LockStale) { $res.State = 'fresh'; return $res }
    # Content shape (stat first - never read-open a size-0 path; one open for
    # line 1 + line 2, the ghost attribution for the log).
    $len = $null
    try { $len = (New-Object System.IO.FileInfo $script:LockPath).Length } catch { $len = $null }
    if ($null -eq $len) {
        if ($null -ne (script:Lock-GetItemAt $script:LockPath)) { $res.State = 'fresh' } else { $res.State = 'gone' }
        return $res
    }
    if ($len -eq 0) { $res.State = 'stale'; return $res }                       # the empty crash-orphan lane
    $line1 = $null; $line2 = $null
    try {
        $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $line1 = $sr.ReadLine()
            $line2 = $sr.ReadLine()
        } finally { $fs.Dispose() }
    } catch [System.IO.FileNotFoundException] {
        $res.State = 'gone'; return $res
    } catch [System.IO.DirectoryNotFoundException] {
        $res.State = 'gone'; return $res
    } catch {
        $res.State = 'fresh'; return $res                                       # unreadable content: not provable
    }
    if ($null -ne $line1) { $line1 = $line1.TrimEnd() }
    if ($null -ne $line2) { $line2 = $line2.TrimEnd() }
    if ($line1) {
        if ($line1.StartsWith('tok.')) { $res.State = 'stale' } else { $res.State = 'wrongtype' }
    } else {
        $res.State = 'wrongtype'                                                # non-empty but blank line 1
    }
    $res.Line2 = $line2
    return $res
}

# Atomic rename-over of the claim onto the lock path. Engine split (probed,
# see PORT-SPECIFIC NOTES): pwsh 7 / .NET Core has the 3-arg overwrite
# overload [IO.File]::Move($src,$dst,$true) - one atomic replace, no
# path-absent window; Windows PowerShell 5.1 / .NET Framework does not (and
# File.Replace was REJECTED - see the bash header's plan trail), so the 5.1
# lane is unlink-the-ghost + fail-if-exists Move, whose transient absent
# window is safe UNDER THE CLAIM: a rival's create landing in it merely wins
# the lock (our Move fails-if-exists - a fairness loss, never a clobber).
# .NET's Move refuses a DIRECTORY destination on both engines with both
# files intact (probed P5/Q3 - native `mv -T` semantics; no extra guard).
# Returns one of:
#   ok        renamed; our lock is installed
#   src-gone  the claim vanished (canonical discovery case)
#   dest-gone (5.1 only) the lock vanished before the ghost unlink - the
#             CLAIM-ABORT (gone) lane; the Move is NOT attempted
#   lost      (5.1 only) a rival's create won the unlink->Move window
#   wrong-type a non-file appeared at the lock path
#   blocked   rename/unlink refused with the lock file still present
$script:LockMove3 = $null   # $null = unprobed; $true/$false after the probe
function script:Lock-RenameOver {
    Set-StrictMode -Off
    if ($null -eq $script:LockMove3) {
        $m = $null
        try { $m = [System.IO.File].GetMethod('Move', [type[]]@([string],[string],[bool])) } catch { $m = $null }
        $script:LockMove3 = [bool]$m
    }
    if ($script:LockMove3) {
        try {
            [System.IO.File]::Move($script:LockClaimPath, $script:LockPath, $true)
            return 'ok'
        } catch { }
        if ($null -eq (script:Lock-GetItemAt $script:LockClaimPath)) { return 'src-gone' }
        $item = script:Lock-GetItemAt $script:LockPath
        if ($null -ne $item -and -not (script:Lock-IsPlainFile $item)) { return 'wrong-type' }
        return 'blocked'
    }
    # 5.1 ladder: unlink the ghost, then fail-if-exists Move the claim in.
    if ($null -eq (script:Lock-GetItemAt $script:LockPath)) { return 'dest-gone' }
    $deleted = $false
    try { [System.IO.File]::Delete($script:LockPath); $deleted = $true } catch { $deleted = $false }
    if (-not $deleted) {
        if ($null -ne (script:Lock-GetItemAt $script:LockPath)) {
            $item = script:Lock-GetItemAt $script:LockPath
            if ($null -ne $item -and -not (script:Lock-IsPlainFile $item)) { return 'wrong-type' }
            return 'blocked'
        }
        # The ghost vanished while the delete failed: already gone - proceed
        # to the Move exactly as if our unlink had won.
    }
    try {
        [System.IO.File]::Move($script:LockClaimPath, $script:LockPath)
        return 'ok'
    } catch { }
    if ($null -eq (script:Lock-GetItemAt $script:LockClaimPath)) { return 'src-gone' }
    $item = script:Lock-GetItemAt $script:LockPath
    if ($null -ne $item) {
        if (script:Lock-IsPlainFile $item) { return 'lost' }
        return 'wrong-type'
    }
    return 'blocked'
}

# The ordered install sequence (protocol steps 2-3.4), entered with OUR claim
# freshly created (token $Token; $script:LockClaimToken set by the caller).
# Returns $true iff a hold was taken (rename-over read-back, or a
# discovery-HOLD); $false means the attempt resolved without a hold and the
# caller falls through to the timeout check + poll sleep. Every exit that
# does not end in a successful rename runs its token-checked claim handling
# and then the FINAL DISCOVERY READ as its last act (the ownership-discovery
# rule - position-blind, unconditional; mirrors bash's _lock_steal_install).
function script:Lock-StealInstall([string]$Token) {
    Set-StrictMode -Off
    # Step 2: re-verify the lock still stale under the claim.
    $lv = script:Lock-VerifyStale
    if ($lv.State -ne 'stale') {
        $reason = 'fresh'
        if ($lv.State -eq 'gone') { $reason = 'gone' }          # never rename onto the absent path
        elseif ($lv.State -eq 'wrongtype') { $reason = 'wrong-type' }
        [void](script:Lock-ClaimDelete $Token 0)
        script:Lock-Log "CLAIM-ABORT ($reason) tok=$Token (lock re-verify after claim: $($lv.State))"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    # Step 3.1: claim recheck - it must still carry OUR token and be YOUNGER
    # than CLAIM_STALE (the stale-claim TOCTOU guard).
    $cs = script:Lock-ClaimState $Token
    if ($cs.State -eq 'gone') {
        script:Lock-Log "claim recheck: claim gone (tok=$Token) - a rival's rename may have installed it; discovery read"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    if ($cs.State -eq 'foreign') {
        $ft = $cs.Tok; if (-not $ft) { $ft = '<empty>' }
        script:Lock-Log "claim recheck: foreign token '$ft' at the claim (ours tok=$Token) - leaving it; discovery read"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    if ($cs.State -eq 'unreadable') {
        # We cannot verify the claim is ours OR not ours: leave it (it ages
        # out) and remember the token - the one-shot discovery read below is
        # NOT conclusive for this exit, so the leaked-token memory watches.
        script:Lock-LeakedAdd $Token 'recheck-unreadable'
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    # Ours: overage check (same mtime + floor rules as everywhere; a
    # sub-floor or unreadable claim mtime means "unsettled, just created").
    $cm = script:Lock-StatMtime $script:LockClaimPath
    if ($null -ne $cm -and $cm -gt $script:LockMtimeFloor) {
        $cage = (script:Lock-Now) - $cm
        if ($cage -ge $script:LockClaimStale) {
            [void](script:Lock-ClaimDelete $Token 0)
            script:Lock-Log "CLAIM-ABORT (contested) tok=$Token claim-age=${cage}s >= $($script:LockClaimStale)s"
            $script:LockClaimToken = ''
            if (script:Lock-Discover $Token) { return $true }
            return $false
        }
    }
    # Step 3.2: NON-creating touch - the installed lock's staleness clock is
    # the claim's mtime (rename preserves it, probe P2), so the touch makes
    # the new holder's lease start ~now. SetLastWriteTimeUtc on a missing
    # file throws FileNotFoundException (probe Q1) - the exception IS the
    # gone signal here (PowerShell wraps it; walk the inner chain).
    $touchGone = $false
    try {
        [System.IO.File]::SetLastWriteTimeUtc($script:LockClaimPath, [datetime]::UtcNow)
    } catch {
        $e = $_.Exception
        while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) {
            $touchGone = $true
        } elseif ($null -eq (script:Lock-GetItemAt $script:LockClaimPath)) {
            $touchGone = $true
        }
        # Other failures with the claim still present: proceed (the lease
        # shortfall is the only cost; the recheck already bounded the age).
    }
    if ($touchGone) {
        script:Lock-Log "claim gone at touch (tok=$Token); discovery read"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    # Step 3.3: re-verify the lock still stale, immediately before the rename.
    $lv = script:Lock-VerifyStale
    if ($lv.State -ne 'stale') {
        $reason = 'fresh'
        if ($lv.State -eq 'gone') { $reason = 'gone' }
        elseif ($lv.State -eq 'wrongtype') { $reason = 'wrong-type' }
        [void](script:Lock-ClaimDelete $Token 0)
        script:Lock-Log "CLAIM-ABORT ($reason) tok=$Token (lock re-verify before rename: $($lv.State))"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    $ghost = $lv.Line2; if (-not $ghost) { $ghost = '?' }
    # Step 3.4: rename-over - ghost destroyed + our live lock installed in
    # one atomic op (pwsh 7; the 5.1 ladder's absent window is claim-guarded)
    # - then the normal acquire read-back verification. Attribution caveat:
    # $ghost names the last VERIFIED occupant (the step-3.3 re-read);
    # residual 1's verify->rename gap means the object actually replaced
    # could in principle differ.
    $mv = script:Lock-RenameOver
    if ($mv -eq 'ok') {
        script:Lock-Log "STOLE-BY-CLAIM $script:LockPath ghost=$ghost by $script:LockMe tok=$Token"
        $script:LockStealFailLast = 0
        $rb = script:Lock-ReadTok -Path $script:LockPath -MaxTries 8
        if ($rb.Status -eq 'ok' -and $rb.Token -eq $Token) {
            script:Lock-TakeHold $Token
            return $true
        }
        $script:LockClaimToken = ''
        $found = $rb.Token; if (-not $found) { $found = '<empty-or-gone>' }
        script:Lock-Log "WARNING: acquire verification FAILED - steal rename completed but read-back found '$found' (ours=$Token); not acquired, re-entering wait"
        [Console]::Error.WriteLine('git-commit-lock: WARNING - acquire verification failed after a steal: the lock file did not read back our token; treating the lock as NOT acquired and waiting')
        return $false
    }
    if ($mv -eq 'src-gone') {
        # Source (claim) gone at rename: the canonical discovery case.
        script:Lock-Log "steal rename: claim (source) gone at rename (tok=$Token); discovery read"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    if ($mv -eq 'dest-gone') {
        # 5.1 ladder sub-lane (a): the lock vanished before the ghost unlink
        # (the live-slow holder released first). Routes as step 4(a) does:
        # never rename onto the absent path - that lane belongs to the
        # normal create race.
        [void](script:Lock-ClaimDelete $Token 0)
        script:Lock-Log "CLAIM-ABORT (gone) tok=$Token (lock gone at the 5.1 ghost unlink)"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    if ($mv -eq 'lost') {
        # 5.1 ladder: a rival's create won the unlink->Move absent window -
        # a fairness loss (the claimant did the recovery work and lost the
        # lock), never a clobber. By design; re-race via the normal poll.
        [void](script:Lock-ClaimDelete $Token 0)
        script:Lock-Log "steal lost the 5.1 unlink->Move window (tok=$Token): a rival's create took the lock; claim deleted, re-polling"
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    if ($mv -eq 'wrong-type') {
        # Destination wrong-type (e.g. a directory appeared at the lock
        # path): .NET's Move refuses it with both files intact (probe P5/Q3);
        # the next poll's wrong-type guard classifies the object. Shares the
        # squatted-steal damper.
        [void](script:Lock-ClaimDelete $Token 0)
        if ($script:LockStealLogOk) {
            script:Lock-Log "CLAIM-ABORT (rename-refused) tok=$Token - rename refused, non-file at the lock path; re-polling - repeats logged at most once per $($script:LockStale)s"
            $script:LockStealFailLast = script:Lock-Now
        }
        $script:LockClaimToken = ''
        if (script:Lock-Discover $Token) { return $true }
        return $false
    }
    # Blocked: rename refused with the lock file still present (a
    # no-delete-share handle on the ghost - probe D1/P6 - an unwritable
    # parent dir, or - this port only - ANY rival handle transiently open on
    # the destination, because .NET's rename lacks POSIX semantics; see
    # PORT-SPECIFIC NOTES). Delete our claim IMMEDIATELY (a failed steal must
    # NOT cost a CLAIM_STALE ageout penalty), log damped, re-poll honouring
    # MAX_WAIT (the caller's fall-through reaches the timeout check).
    [void](script:Lock-ClaimDelete $Token 0)
    if ($script:LockStealLogOk) {
        script:Lock-Log "steal FAILED: rename refused with the lock file still present (no-delete-share handle, or unwritable parent dir); claim deleted, re-polling - repeats logged at most once per $($script:LockStale)s"
        $script:LockStealFailLast = script:Lock-Now
    }
    $script:LockClaimToken = ''
    if (script:Lock-Discover $Token) { return $true }
    return $false
}

# A claim already exists (our O_EXCL claim create failed): a rival mid-steal,
# or a crashed claimant's leftover. Clear it ONLY when aged past CLAIM_STALE
# (same mtime + floor rules as the lock) AND claim-shaped (empty by STAT, or
# a "tok."-prefixed line 1) - the never-steal content guard applies to the
# claim path exactly as to the lock path, with per-path warn-once state. A
# successful clear logs CLAIM-STALE-CLEARED; the next poll re-races the claim
# create. A young claim means a live steal is in progress: just wait.
# ps1-on-POSIX residual: a FIFO/device/socket at the claim path stats as size
# 0 and takes this empty-claim clear lane (see PORT-SPECIFIC NOTES).
function script:Lock-ClaimStaleCheck {
    Set-StrictMode -Off
    $cm = script:Lock-StatMtime $script:LockClaimPath
    if ($null -eq $cm) { return }                            # vanished/unreadable mtime: re-poll
    if ($cm -le $script:LockMtimeFloor) { return }           # sub-floor: unsettled, never clear
    $cage = (script:Lock-Now) - $cm
    if ($cage -lt $script:LockClaimStale) { return }
    $len = $null
    try { $len = (New-Object System.IO.FileInfo $script:LockClaimPath).Length } catch { $len = $null }
    if ($null -eq $len) { return }                           # vanished mid-check: re-poll
    $l1 = ''
    if ($len -gt 0) {
        $line = $null
        try {
            $fs = [System.IO.File]::Open($script:LockClaimPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $sr = New-Object System.IO.StreamReader($fs)
                $line = $sr.ReadLine()
            } finally { $fs.Dispose() }
        } catch { return }                                   # unreadable: skip this attempt, re-poll
        if ($null -ne $line) { $line = $line.TrimEnd() }
        if ($line) {
            if (-not $line.StartsWith('tok.')) {
                script:Lock-WarnNonLockClaim 'its content is not claim-shaped'
                return
            }
            $l1 = $line
        } else {
            # Non-empty by stat but blank line 1: not claim-shaped (a torn
            # write of ours always starts with 't').
            script:Lock-WarnNonLockClaim 'its content is not claim-shaped'
            return
        }
    }
    $deleted = $false
    try { [System.IO.File]::Delete($script:LockClaimPath); $deleted = $true } catch { $deleted = $false }
    if ($deleted) {
        $disp = $l1; if (-not $disp) { $disp = '<empty>' }
        script:Lock-Log "CLAIM-STALE-CLEARED $script:LockClaimPath age=${cage}s tok=$disp"
        # If the cleared token was one of OUR leaked entries, this unlink is
        # a verified resolution - gated on one lock-path read (a rival's
        # rename can slip into our read->unlink gap and install it; an
        # INCONCLUSIVE read - lock present but unreadable - also keeps the
        # entry, see Lock-LeakedLockResolved).
        if ($l1 -and (script:Lock-LeakedMember $l1)) {
            if (script:Lock-LeakedLockResolved $l1) {
                script:Lock-LeakedDrop $l1
                script:Lock-Log "leaked-token memory: resolved tok=$l1 (stale claim cleared)"
            }
        }
    }
}

# Trap-equivalent claim cleanup (the bash EXIT/INT/TERM handlers' claim-window
# mode; here it runs from Lock-Acquire's finally block, which PowerShell DOES
# execute on Ctrl+C/pipeline-stop and on a terminating error - the nearest
# equivalent of a trappable exit; a hard kill is the untrappable lane,
# residual 5). Token-checked deletion with ONE bounded retry (an exiting
# cleanup cannot wait out a blockage), then the final discovery read; a
# discovery-HOLD here is released inline per NORMAL release semantics (the
# caller's try/finally never sees the hold, so nobody else would release
# it) - mirroring bash, where the trap routes a discovery-HOLD through full
# lock_release: boundary re-read immediately before the unlink, bounded
# delete retries, and an honest LEFTOVER warning when the delete stays
# blocked - never a false RELEASED. NO lock-release semantics (98) ever run
# on a mere claim. .NET-only primitives where possible: cmdlet invocation
# inside a stopping pipeline's finally can throw PipelineStoppedException.
function script:Lock-ClaimTrapCleanup {
    Set-StrictMode -Off
    if (-not $script:LockClaimToken) { return }
    $tok = $script:LockClaimToken
    $script:LockClaimToken = ''
    $cd = script:Lock-ClaimDelete $tok 1
    if ($cd -eq 'leaked-blocked') {
        script:Lock-Log "trap: claim tok=$tok undeletable after the bounded retry; exiting leaving it (ages out <= $($script:LockClaimStale)s - residual-5 class)"
    }
    # Final discovery read - inline, WITHOUT Lock-TakeHold (no backstop
    # registration mid-unwind): our token at the lock means a rival installed
    # our claim; release it right here, per the normal release path's rules.
    $rb = script:Lock-ReadTok -Path $script:LockPath -MaxTries 8
    if ($rb.Status -eq 'ok' -and $rb.Token -eq $tok) {
        script:Lock-Log "DISCOVERY-HOLD: our claim (tok=$tok) was installed at the lock path by a rival's rename - taking the hold"
        # Boundary re-read immediately before the unlink (full ladder, the
        # same width as Lock-Release's - same verdicts from the same
        # evidence).
        $re = script:Lock-ReadTok -Path $script:LockPath -MaxTries 8
        if ($re.Status -eq 'ok' -and $re.Token -eq $tok) {
            # Still ours: unlink with the ours-path bounded retry; on
            # persistent failure warn LEFTOVER honestly instead of logging a
            # release that did not happen.
            $deleted = $false
            for ($i = 0; $i -lt 5; $i++) {
                try { [System.IO.File]::Delete($script:LockPath); $deleted = $true; break }
                catch { [System.Threading.Thread]::Sleep(20) }
            }
            if (-not $deleted -and $null -ne (script:Lock-GetItemAt $script:LockPath)) {
                script:Lock-Log "WARNING: trap-time release FAILED - could not delete the discovery-HOLD lock after 5 attempts; LEFTOVER (tok=$tok). Waiters are blocked until the $($script:LockStale)s stale window elapses AND the blocking handle closes."
                [Console]::Error.WriteLine("git-commit-lock: WARNING - could not remove the lock file ($script:LockPath) during acquire unwind; it is left behind and will block waiters until the $($script:LockStale)s stale window expires and whatever holds it open lets go")
            } else {
                # Deleted - or vanished while the delete kept failing, which
                # is equally released (File.Delete's silent-on-missing lane).
                script:Lock-Log "RELEASED ($script:LockMe tok=$tok) (trap-time discovery-HOLD released during acquire unwind)"
            }
        } elseif ($re.Status -eq 'unreadable') {
            # Present but unreadable/empty at the boundary: ownership
            # unverifiable - never delete what might be a successor's nascent
            # lock; leave it (the staleness backstop recovers a true orphan).
            # Stderr too, like the normal release's unverifiable lane.
            script:Lock-Log "WARNING: trap-time discovery-HOLD lock present but EMPTY/unreadable at the boundary re-read; ownership unverifiable - leaving it in place. (tok=$tok)"
            [Console]::Error.WriteLine("git-commit-lock: WARNING - the lock file read empty/unreadable during acquire unwind (still present). Ownership unverifiable; lock file left in place.")
        } else {
            # Gone, or a foreign token: displaced between the discovery read
            # and the boundary re-read - a successor owns the path now; do
            # not touch it. (No 98 verdict surfaces here: the unwind has no
            # caller to return one to; the displacement is the successor's
            # detected lane.) Stderr too, like the normal release's
            # gone/foreign lane - though as a note, not a "commit was NOT
            # serialised" warning: no command ran under this discovery-HOLD.
            script:Lock-Log "trap-time discovery-HOLD displaced before its release (tok=$tok); leaving the path to its successor"
            [Console]::Error.WriteLine("git-commit-lock: note - our briefly-installed lock (claim adopted at exit) was displaced before its trap-time release; path left to its successor.")
        }
    }
}

# Best-effort release-at-process-exit backstop for dot-source callers who forgot
# try/finally. Token-checked, so it can never free a successor's lock. KNOWN
# LIMITS (measured 2026-06-10): PowerShell.Exiting fires under -Command and in
# interactive sessions, but NOT under -File (either engine) and not on a hard
# kill or [Environment]::Exit - so this is a backstop, not the contract; pair
# Lock-Acquire/Lock-Release in try/finally regardless.
function script:Lock-RegisterExitBackstop {
    Set-StrictMode -Off
    try {
        # Bake the values INTO the action's text. Neither -MessageData (arrives
        # EMPTY inside a PowerShell.Exiting action) nor GetNewClosure (captured
        # variables come back empty when the closure was built inside a
        # function) survives into the exiting action - both measured on pwsh
        # 7.5 AND 5.1, 2026-06-10. A scriptblock with literal values does.
        # The read uses the same delete-sharing FileStream as everywhere else.
        $bsPath = $script:LockPath.Replace("'", "''")
        $bsTok = $script:LockToken.Replace("'", "''")
        $bsLog = $script:LockLog.Replace("'", "''")
        $action = [scriptblock]::Create(
            "try { `$fs = [System.IO.File]::Open('$bsPath', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)); " +
            "try { `$sr = New-Object System.IO.StreamReader(`$fs); `$cur = `$sr.ReadLine() } finally { `$fs.Dispose() }; " +
            "if (`$null -ne `$cur) { `$cur = `$cur.TrimEnd() }; " +
            "if (`$cur -eq '$bsTok') { [System.IO.File]::Delete('$bsPath'); " +
            "`$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); " +
            "[System.IO.File]::AppendAllText('$bsLog', `$ts + ' [pid=' + `$PID + '] RELEASED (engine-event backstop at process exit; tok=$bsTok)' + [char]10) } } catch { }")
        $script:LockExitJob = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $action
    } catch { $script:LockExitJob = $null }
}

function script:Lock-UnregisterExitBackstop {
    Set-StrictMode -Off
    try {
        if ($script:LockExitJob) {
            $jobId = $script:LockExitJob.Id
            Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue |
                Where-Object { $_.Action -and $_.Action.Id -eq $jobId } |
                Unregister-Event -ErrorAction SilentlyContinue
            Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    $script:LockExitJob = $null
}

function Lock-Acquire {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    # API misuse, not a timeout: the lock is NOT reentrant. Without this guard
    # a re-acquire would self-deadlock for the stale window and then steal its
    # own lock (mirrors git-commit-lock.sh).
    if ($script:LockHeld) {
        [Console]::Error.WriteLine('git-commit-lock: Lock-Acquire called while already holding the lock (not reentrant)')
        script:Lock-Log 'ERROR: reentrant Lock-Acquire refused'
        $script:LockAcquireFail = 'reentrant'
        return $false
    }
    $script:LockAcquireFail = ''
    # Ensure the parent directory exists (an explicit AGENT_LOCK_PATH may point
    # somewhere not yet created - mirrors git-commit-lock.sh's `mkdir -p`).
    $parent = Split-Path -Parent $script:LockPath
    if ($parent) { try { [void][System.IO.Directory]::CreateDirectory($parent) } catch { } }
    $script:LockClaimPath = "$script:LockPath.next"
    $start = script:Lock-Now
    $waitingLogged = $false
    # Reset the squatted-steal log damper for this acquire (script-scoped:
    # Lock-StealInstall shares it - see the variable's comment up top).
    $script:LockStealFailLast = 0
    $script:LockStealLogOk = $true
    # Two-consecutive-poll confirmation state for the wrong-type guards below
    # (parity with git-commit-lock.sh's round-3 hardening): the concrete
    # classification observed on the PREVIOUS blocked poll, reset to '' when
    # a poll sees the path absent or a plain regular file. PER PATH: the lock
    # path and the claim path each keep their own state (a shared variable
    # would cross-confirm the two-poll requirement between paths).
    $nonlockPrev = ''
    $claimNonlockPrev = ''
    # $resolved marks a NORMAL return (hold taken, timeout, or reentrant); the
    # finally block below is the bash traps' claim-window equivalent and must
    # act only on an ABNORMAL unwind (Ctrl+C/pipeline stop, a terminating
    # error) - PowerShell executes finally on those, which is as close to a
    # trappable exit as this engine gets (a hard kill is residual 5).
    $resolved = $false
    try {

    while ($true) {
        # PRE-CREATE TYPE GUARD (load-bearing on Windows, not just bash
        # symmetry - see PORT-SPECIFIC NOTES: CreateNew on a DANGLING symlink
        # tunnels through the link and creates the TARGET here, so the create
        # must not be attempted unless the path is absent or carries a plain
        # non-reparse regular file, where CreateNew fails safely). The
        # check-then-open gap is acceptable: a non-lock object at the path is
        # static misconfiguration, not a racing peer.
        $creatable = $false
        $probe = script:Lock-GetPathItem
        if ($null -eq $probe -or (script:Lock-IsPlainFile $probe)) { $creatable = $true }

        # Fresh token per CREATE attempt (per-attempt tokens - see the bash
        # header): a verification-failure-abandoned lock can then never alias
        # a later attempt's read-back or a discovery read.
        $tokc = ''
        if ($creatable) { $tokc = script:Lock-NewToken }
        if ($creatable -and (script:Lock-TryCreateFile -Path $script:LockPath -Token $tokc)) {
            # The file now carries our token and its mtime (the staleness
            # clock) is stamped by the creating write.
            #
            # VERIFY via a path read-back before claiming the hold (see
            # ACQUIRE VERIFICATION in git-commit-lock.sh): only our own token
            # proves we hold the path. NEVER repair a failed read-back by
            # writing to the path - after a long suspension the path may
            # legitimately belong to a successor. The wave-1 restore-grace
            # re-read loop is gone with the graves (SUPERSEDED 2026-06-11):
            # under the claim protocol a displaced fresh lock is never moved
            # aside, so there is nothing to wait for.
            $rb = script:Lock-ReadCurToken -MaxTries 8
            if ($rb.Status -eq 'ok' -and $rb.Token -eq $tokc) {
                script:Lock-TakeHold $tokc
                $resolved = $true
                return $true
            }
            $found = $rb.Token; if (-not $found) { $found = '<empty-or-gone>' }
            script:Lock-Log "WARNING: acquire verification FAILED - create won but read-back found '$found' (ours=$tokc); not acquired, re-entering wait"
            [Console]::Error.WriteLine('git-commit-lock: WARNING - acquire verification failed: the lock file did not read back our token; treating the lock as NOT acquired and waiting')
            # fall through to the blocked branch of this same iteration
        }

        # Blocked (create lost, was skipped by the type guard, or won-but-
        # failed verification). One WAITING line on the first blocked poll
        # only: lets a log reader see this acquirer actually contended, and
        # lets tests hold-until-WAITING instead of sleeping. (No token on the
        # line: tokens are per-attempt now; the CLAIM lines carry them.)
        if (-not $waitingLogged) {
            $waitingLogged = $true
            script:Lock-Log "WAITING for lock ($script:LockMe)"
        }

        # LEAKED-TOKEN MEMORY per-poll check (see the rule in the bash
        # header; the list is almost always empty, so this costs nothing in
        # the common case): while entries are pending, every poll that
        # observes a lock also reads its line 1 - a LISTED token there means
        # a rival's rename installed OUR leaked claim as the lock: adopt it
        # as the hold (the entry drops; the leak is resolved).
        if (@($script:LockLeaked).Count -gt 0) {
            $lt = script:Lock-ReadTok -Path $script:LockPath -MaxTries 1
            if ($lt.Status -eq 'ok' -and $lt.Token -and (script:Lock-LeakedMember $lt.Token)) {
                script:Lock-LeakedDrop $lt.Token
                script:Lock-Log "DISCOVERY-HOLD (leaked-token memory): leaked claim tok=$($lt.Token) found installed at the lock path - adopting the hold"
                script:Lock-TakeHold $lt.Token
                $resolved = $true
                return $true
            }
        }

        # PER-POLL TYPE GUARD (cheap; every blocked poll, NOT age-gated): an
        # actively-written non-lock path (the canonical AGENT_LOCK_PATH=$HOME
        # typo: writes keep refreshing its mtime) never ages past the stale
        # window, so an age-gated guard would never diagnose it. Warn only on
        # exists-but-wrong-type - a path that vanished since the failed create
        # is normal contention (re-race the create), not a config problem.
        # The existence probe sees the link itself (Lock-GetPathItem): a
        # DANGLING symlink is refused by the pre-create guard forever but
        # reads as absent to a target-following probe, which would misclassify
        # it as contention every poll and starve the waiter to 97 undiagnosed.
        $item = script:Lock-GetPathItem
        if ($null -ne $item) {
            if (-not (script:Lock-IsPlainFile $item)) {
                # WRONG-TYPE CONFIRMATION (parity with git-commit-lock.sh's
                # round-3 hardening, 2026-06-11, CI run 27325971668): warn
                # only when the SAME concrete type is observed on two
                # consecutive blocked polls. This side has no observed
                # misfire - the classification is one Get-Item snapshot, and
                # a delete-pending ghost makes Get-Item throw (-> $null ->
                # normal contention) - but the impls stay in lock-step and
                # the cost is a few lines. A real misconfig object classifies
                # identically forever, so its once-per-process warning just
                # arrives one poll later; the never-steal safety is
                # unaffected either way (the guard never steals non-locks
                # regardless of warning state). ReparsePoint is tested FIRST
                # so a directory symlink/junction is named as the link it is
                # (same order as bash's -L-first). Lock-IsPlainFile can only
                # reject a reparse point or a container, so the
                # classification here is exhaustive; the empty fall-through
                # mirrors bash's no-concrete-type lane defensively.
                $nonlockCur = ''
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $nonlockCur = 'a symlink'
                } elseif ($item.PSIsContainer) {
                    $nonlockCur = 'a directory'
                }
                if ($nonlockCur -and $nonlockCur -eq $nonlockPrev) {
                    script:Lock-WarnNonLock "it is $nonlockCur"
                }
                $nonlockPrev = $nonlockCur
            } else {
                $nonlockPrev = ''   # regular file: any prior wrong-type observation is moot
                # A regular file: a live lock, a stale one, or a crash orphan.
                # Steal if the FILE's mtime is older than the stale window -
                # but only on a PLAUSIBLE mtime (>= 2000-01-01): a sub-floor
                # reading is an unsettled FILETIME-zero transient of a
                # just-created lock (probes C/C1b), not a stale one; stealing
                # on it would yank a live, brand-new lock. Treat as recent.
                $mt = script:Lock-PathMtime
                if ($null -ne $mt -and $mt -gt $script:LockMtimeFloor) {
                    $age = (script:Lock-Now) - $mt
                    if ($age -ge $script:LockStale) {
                        # CONTENT GUARD (age-gated, runs only on a stale
                        # candidate): steal only lock-shaped content - an
                        # EMPTY file (the crash-between-create-and-write
                        # orphan) or line 1 starting "tok." (a real token,
                        # possibly torn mid-token). Anything else is a user
                        # file at a typo'd path or a torn write shorter than
                        # the prefix: never steal it. "Empty" is determined by
                        # STAT, without opening (a FIFO read-open would block
                        # on Unix - see PORT-SPECIFIC NOTES); the owner (line
                        # 2) is read in the same open as line 1, BEFORE the
                        # final mtime re-read below - an open inserted after
                        # the re-read would widen exactly the window it
                        # shrinks.
                        $stealOk = $false; $holder = '?'
                        $len = $null
                        try { $len = (New-Object System.IO.FileInfo $script:LockPath).Length } catch { $len = $null }
                        if ($null -ne $len) {
                            if ($len -eq 0) {
                                $stealOk = $true   # genuinely empty: the crash-orphan lane
                            } else {
                                $line1 = $null; $line2 = $null; $readFailed = $false
                                try {
                                    $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::Open,
                                        [System.IO.FileAccess]::Read,
                                        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                                    try {
                                        $sr = New-Object System.IO.StreamReader($fs)
                                        $line1 = $sr.ReadLine()
                                        $line2 = $sr.ReadLine()
                                    } finally { $fs.Dispose() }
                                } catch [System.IO.FileNotFoundException] {
                                    $len = $null   # vanished mid-check: normal contention; re-poll
                                } catch [System.IO.DirectoryNotFoundException] {
                                    $len = $null
                                } catch {
                                    $readFailed = $true
                                }
                                if ($null -ne $len) {
                                    if ($readFailed) {
                                        # Persistent read failure with a non-empty file
                                        # still present: neither "empty" nor the
                                        # never-steal lane - skip this steal attempt and
                                        # re-poll. Self-correcting: a handle that blocks
                                        # our read usually blocks the steal rename too
                                        # (probe D1), so refusing costs nothing.
                                        script:Lock-Log "steal skipped: stale lock content unreadable (age=${age}s); re-polling"
                                    } else {
                                        if ($null -ne $line1) { $line1 = $line1.TrimEnd() }
                                        if ($null -ne $line2) { $line2 = $line2.TrimEnd() }
                                        if ($line1 -and $line1.StartsWith('tok.')) {
                                            $stealOk = $true
                                            if ($line2) { $holder = $line2 }
                                        } elseif ($line1) {
                                            script:Lock-WarnNonLock 'its content is not lock-shaped'
                                        } else {
                                            # Line 1 blank. Re-stat: vanished -> contention;
                                            # NOW empty -> the crash-orphan lane; non-empty
                                            # with a blank first line -> not lock-shaped (a
                                            # torn write of ours always starts with 't').
                                            $len2 = $null
                                            try { $len2 = (New-Object System.IO.FileInfo $script:LockPath).Length } catch { $len2 = $null }
                                            if ($null -ne $len2) {
                                                if ($len2 -eq 0) { $stealOk = $true }
                                                else { script:Lock-WarnNonLock 'its content is not lock-shaped' }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if ($stealOk) {
                            # Damp the attempt logging while steals keep
                            # failing on a squatted file (see the script-
                            # scoped damper up top): first failure, then at
                            # most once per stale window.
                            $nowS = script:Lock-Now
                            $script:LockStealLogOk = ($script:LockStealFailLast -eq 0 -or ($nowS - $script:LockStealFailLast) -ge $script:LockStale)
                            # CLAIM-PATH PRE-CREATE TYPE GUARD (per-path
                            # two-poll confirmation + warn-once state,
                            # independent from the lock path's - mirrors
                            # bash). On Windows this guard is load-bearing
                            # exactly like the lock path's (CreateNew tunnels
                            # through a dangling symlink); the ps1-on-POSIX
                            # FIFO/device residual applies here too (they
                            # pass as "plain" - see PORT-SPECIFIC NOTES).
                            $claimCreatable = $false
                            $citem = script:Lock-GetItemAt $script:LockClaimPath
                            if ($null -eq $citem) {
                                $claimCreatable = $true
                                $claimNonlockPrev = ''
                            } elseif (script:Lock-IsPlainFile $citem) {
                                $claimCreatable = $true
                                $claimNonlockPrev = ''
                            } else {
                                $claimNonlockCur = ''
                                if (($citem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                                    $claimNonlockCur = 'a symlink'
                                } elseif ($citem.PSIsContainer) {
                                    $claimNonlockCur = 'a directory'
                                }
                                if ($claimNonlockCur -and $claimNonlockCur -eq $claimNonlockPrev) {
                                    script:Lock-WarnNonLockClaim "it is $claimNonlockCur"
                                }
                                $claimNonlockPrev = $claimNonlockCur
                                # No claim create possible: steals are blocked
                                # until the object is removed; fall through to
                                # the timeout check + poll sleep.
                            }
                            if ($claimCreatable) {
                                # Fresh token per CLAIM attempt (per-attempt
                                # tokens - see the bash header).
                                # $script:LockClaimToken arms the acquire
                                # cleanup's claim-window mode BEFORE the
                                # create: the cleanup is token-checked, so an
                                # unwind landing pre-create is a harmless
                                # no-op.
                                $toka = script:Lock-NewToken
                                $script:LockClaimToken = $toka
                                if (script:Lock-TryCreateFile -Path $script:LockClaimPath -Token $toka) {
                                    if ($script:LockStealLogOk) { script:Lock-Log "STALE (age=${age}s holder=$holder) -> stealing (claim-serialized)" }
                                    script:Lock-Log "CLAIM $script:LockClaimPath tok=$toka by $script:LockMe"
                                    if (script:Lock-StealInstall $toka) {
                                        $resolved = $true
                                        return $true
                                    }
                                    # Attempt resolved without a hold: fall
                                    # through to the timeout check + poll
                                    # sleep (never busy-spin - a blocked
                                    # rename means nothing changes until the
                                    # squatter lets go).
                                } else {
                                    # Claim create lost (or failed): a rival
                                    # is stealing, or a crashed claimant's
                                    # leftover squats the claim path. Clear
                                    # the latter only when aged + claim-
                                    # shaped; otherwise just wait - the
                                    # rival's steal is in flight.
                                    $script:LockClaimToken = ''
                                    script:Lock-ClaimStaleCheck
                                }
                            }
                        }
                    }
                }
            }
        } else {
            # path absent: normal contention - the next iteration re-races
            # the create. Also resets the wrong-type confirmation state.
            $nonlockPrev = ''
        }

        # A live holder has it (or a never-steal object squats it) - wait,
        # unless we have waited too long.
        if (((script:Lock-Now) - $start) -ge $script:LockMaxWait) {
            script:Lock-Log "TIMEOUT after $($script:LockMaxWait)s waiting for lock"
            [Console]::Error.WriteLine("git-commit-lock: timed out after $($script:LockMaxWait)s waiting for commit lock")
            $script:LockAcquireFail = 'timeout'
            # The arc ends here without a hold: run the best-effort
            # resolution pass over any pending leaked entries (the blocking
            # handle may have closed by now).
            script:Lock-LeakedResolvePass
            $resolved = $true
            return $false
        }
        # -Milliseconds, not -Seconds: Windows PowerShell 5.1's -Seconds is an
        # Int32, so a fractional poll (e.g. the tests' 0.05) would truncate to a
        # busy-spin there.
        Start-Sleep -Milliseconds ([int][Math]::Max(1, $script:LockPoll * 1000))
    }

    } finally {
        # Trap-equivalent claim-window cleanup (see Lock-ClaimTrapCleanup):
        # PowerShell runs this finally on Ctrl+C/pipeline-stop and on a
        # terminating error escaping the loop - the abnormal unwinds where a
        # claim attempt may still be in flight and the caller's own
        # try/finally will never see a hold. Normal returns set $resolved and
        # cleared the claim token, so this is a no-op for them.
        if (-not $resolved) {
            script:Lock-ClaimTrapCleanup
            script:Lock-LeakedResolvePass
        }
    }
}

# Release. Returns $true if we held the lock cleanly throughout. Returns $false
# otherwise, with $script:LockReleaseStatus saying why:
#   'stolen'      our lease was stolen before release - the lock file is GONE,
#                 or carries a non-empty FOREIGN token (both definitive:
#                 acquire's read-back proved our token was at the path). The
#                 work we just did was NOT exclusive and should be treated as
#                 failed (run -> exit 98). Special case, same verdict: a
#                 foreign token that is in OUR leaked-token memory is our own
#                 leaked claim installed over the hold by a rival's rename -
#                 it is cleaned up here (boundary re-read + bounded retry +
#                 RELEASE-CLEANED-LEAKED-CLAIM log) before the 98 classifies;
#   'unreadable'  the file still reads EMPTY after the retry ladder while
#                 present (or persistently would not open). NOT definitive
#                 theft evidence: it cannot be our own failed write (acquire's
#                 read-back positively verified our token at the path), but it
#                 can be a successor mid-create after a boundary steal (probe
#                 F's window) or external truncation. We cannot verify
#                 ownership either way: do NOT delete (it may be a successor's
#                 nascent live lock), do NOT report success - leave the file
#                 (the staleness backstop recovers a true orphan). Same
#                 verdict as git-commit-lock.sh's rc-2 lane for the same
#                 on-disk state (run -> exit 1 unless the command already
#                 failed with its own code);
#   'leftover'    the token verified (the work WAS exclusive) but the file
#                 could not be deleted even after retries, so the lock is left
#                 in place blocking waiters. Recovery needs BOTH the stale
#                 window elapsing AND the blocking handle closing - the same
#                 handle blocks a stealer's rename (probe D1), so until then
#                 waiters re-poll and may reach 97. A cleanup failure, not a
#                 serialisation failure: `run` keeps the command's exit code
#                 and warns on stderr.
function Lock-Release {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    if (-not $script:LockHeld) { return $true }
    $script:LockHeld = $false
    $script:LockReleaseStatus = 'ok'
    script:Lock-UnregisterExitBackstop

    # Did we keep the lock the whole time? Compare the file's current token to
    # ours - and on a match, re-read once more IMMEDIATELY before the delete to
    # shrink the steal-between-check-and-delete window. The boundary re-read is
    # classified by the SAME rules as the first read (empty-at-boundary is the
    # unverifiable lane, never a delete: in the file era an empty read is
    # precisely the create->write window of a successor after a boundary
    # steal). The window cannot be closed with these primitives - see KNOWN
    # RESIDUAL RACES in git-commit-lock.sh; the residual case is detected by
    # the displaced party, never silent.
    $read = script:Lock-ReadCurToken -MaxTries 8
    if ($read.Status -eq 'ok' -and $read.Token -eq $script:LockToken) {
        # Full-width re-read, same ladder as the first (and as bash's boundary
        # re-read): same verdicts from the same evidence on both reads.
        $read = script:Lock-ReadCurToken -MaxTries 8
    }
    if (-not ($read.Status -eq 'ok' -and $read.Token -eq $script:LockToken)) {
        # LEAKED-CLAIM CLEANUP (see the leaked-token memory rule in the bash
        # header): a token that is not our hold token but IS in our leaked
        # set is - by per-attempt token uniqueness - OUR leaked claim,
        # installed over our held lock by a rival's rename. Our actual hold
        # WAS displaced (the verdict stays 'stolen'/98), but the installed
        # orphan is ours to clean: re-read immediately before the unlink (the
        # ours-path boundary mitigation - an instantly-stale installed leak
        # can already have been stolen by a successor whose live lock a naive
        # unlink would rob), then unlink with the ours-path bounded retry +
        # LEFTOVER behaviour.
        if ($read.Status -eq 'ok' -and $read.Token -and (script:Lock-LeakedMember $read.Token)) {
            $cur = $read.Token
            $lre = script:Lock-ReadCurToken -MaxTries 8
            if ($lre.Status -eq 'ok' -and $lre.Token -eq $cur) {
                $lcleaned = $false
                for ($i = 0; $i -lt 5; $i++) {
                    try { [System.IO.File]::Delete($script:LockPath); $lcleaned = $true; break }
                    catch { Start-Sleep -Milliseconds 20 }
                }
                if ($lcleaned) {
                    script:Lock-Log "RELEASE-CLEANED-LEAKED-CLAIM $script:LockPath tok=$cur"
                } else {
                    script:Lock-Log "WARNING: release could not delete our installed leaked claim after 5 attempts; LEFTOVER (tok=$cur). It ages out within $($script:LockStale)s once the blocking handle closes."
                    [Console]::Error.WriteLine("git-commit-lock: WARNING - could not remove our leaked claim installed at $script:LockPath; it is left behind and will block waiters until the $($script:LockStale)s stale window expires and whatever holds it open lets go")
                }
            }
            # Re-read no longer the leaked token: a successor stole/replaced
            # it - its rename destroyed our leaked claim, resolving the leak;
            # do NOT touch the successor's live lock. Either way the entry is
            # resolved. (Unconditional drop - deliberately NOT the
            # resolve-pass's inconclusive-keep (Lock-LeakedLockResolved): the
            # boundary re-read ran the FULL 8-try ladder immediately after
            # this same arc read the leaked token OK, so an unreadable/empty
            # re-read here means the leak file was destroyed and a successor
            # is mid-create at the path - not a transient read flake - and
            # the leaked token cannot reappear.)
            script:Lock-LeakedDrop $cur
            script:Lock-LeakedResolvePass
            script:Lock-Log "WARNING: lock LOST before release - our held lock was displaced by our own leaked claim (rival rename). This commit was NOT exclusive - redo it. (ours=$script:LockToken installed-leak=$cur)"
            [Console]::Error.WriteLine("git-commit-lock: WARNING - lock was stolen mid-hold (displaced by a leaked claim of ours, since cleaned). Your commit was NOT serialised; verify with 'git log' and redo under the lock.")
            $script:LockReleaseStatus = 'stolen'
            return $false
        }
        script:Lock-LeakedResolvePass
        if ($read.Status -eq 'unreadable') {
            $script:LockReleaseStatus = 'unreadable'
            script:Lock-Log "WARNING: lock file present but EMPTY/unreadable at release (after retries); ownership unverifiable. Leaving it in place. (ours=$script:LockToken)"
            [Console]::Error.WriteLine("git-commit-lock: WARNING - the lock file read empty/unreadable at release (still present). Ownership unverifiable; lock file left in place. Verify with 'git log'.")
            return $false
        }
        # Gone, or a foreign token: our lease expired and the lock was stolen
        # (and possibly re-acquired by someone else). Do NOT touch the path -
        # it may be a successor's LIVE lock. Loudly report the non-exclusive
        # hold.
        $now = $read.Token; if (-not $now) { $now = '<gone>' }
        script:Lock-Log "WARNING: lock LOST before release (held longer than $($script:LockStale)s stale window; stolen). This commit was NOT exclusive - redo it. (ours=$script:LockToken now=$now)"
        [Console]::Error.WriteLine("git-commit-lock: WARNING - lock was stolen mid-hold (held > $($script:LockStale)s). Your commit was NOT serialised; verify with 'git log' and redo under the lock.")
        $script:LockReleaseStatus = 'stolen'
        return $false
    }

    # Still ours - free it: one unlink. File.Delete is silent on a missing
    # file, which is the "vanished mid-race = already released" branch. On
    # Windows the delete can fail while a foreign no-delete-share handle (AV
    # scanner, naive reader) is open on the file; retry briefly. The retry is
    # grounded on probe D1, not on hope: the handle class that blocks our
    # delete also blocks any steal's rename, so the path cannot be
    # stolen-and-recreated while the delete keeps failing (the read-only-
    # attribute exception and the between-retries gap are documented in the
    # headers; both end in the same detected-98 class).
    $deleted = $false
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::Delete($script:LockPath); $deleted = $true; break }
        catch { Start-Sleep -Milliseconds 20 }
    }
    if (-not $deleted) {
        if (Test-Path -LiteralPath $script:LockPath) {
            # Persistent failure: the lock is NOT released (LEFTOVER). Do not
            # claim success - waiters stay blocked until the stale window
            # elapses AND the blocking handle closes (the same handle blocks
            # their steal rename, so until then they re-poll, possibly to 97).
            $script:LockReleaseStatus = 'leftover'
            script:Lock-LeakedResolvePass
            script:Lock-Log "WARNING: release FAILED - could not delete the lock file after 5 attempts; LEFTOVER (tok=$script:LockToken). Waiters are blocked until the $($script:LockStale)s stale window elapses AND the blocking handle closes."
            [Console]::Error.WriteLine("git-commit-lock: WARNING - could not remove the lock file ($script:LockPath); it is left behind and will block waiters until the $($script:LockStale)s stale window expires and whatever holds it open lets go")
            return $false
        }
        # else: the file vanished while the delete kept failing - already
        # gone, equally released (the same branch File.Delete's silent-on-
        # missing behaviour covers).
    }
    # Arc end: one best-effort resolution pass over any pending leaked entries
    # (almost always a no-op - the list is empty in the common case).
    script:Lock-LeakedResolvePass
    script:Lock-Log "RELEASED ($script:LockMe tok=$script:LockToken)"
    return $true
}

# Run a command string under the lock; always release; carry the result out via
# $script:LockRunRc (the CLI exits with it):
#   96 if the command string is empty or does not parse (the lock is NEVER
#      acquired and nothing runs);
#   97 if lock acquisition timed out (the command NEVER ran);
#   otherwise the command's own exit code - the command is materialised as a
#      child SCRIPT FILE and invoked with `&`, so an `exit N` inside it
#      terminates only that child and lands in $LASTEXITCODE like any native
#      command, instead of unwinding this script past the release logic;
#   1  if the command threw a terminating error (mapped in a try/catch so an
#      in-session caller can never read a stale $LASTEXITCODE as success), or
#      if its FINAL statement failed without setting a native exit code (a
#      cmdlet's non-terminating error - exit-0-on-failure was the verified F2
#      bug, 2026-06-11);
#
#   VERDICT TABLE (in order; decided after the child script returns):
#     a. the invocation threw a terminating error          -> 1 (stderr note)
#     b. $LASTEXITCODE was SET by the command and nonzero  -> that code
#        ("set" is detected against a $null sentinel assigned just before the
#        invocation, so a stale pre-run value can never be misread)
#     c. the command's FINAL statement failed              -> 1 (stderr note)
#        (the staged child script gets a postamble line appended that records
#        the script-final $? into a global - the caller-side $? after
#        `& file.ps1` reads True even when the script's last cmdlet failed,
#        probed on BOTH engines 2026-06-11, so it cannot carry this verdict;
#        `exit N` skips the postamble, which is fine: lane b already decided)
#     d. otherwise (incl. $LASTEXITCODE set to 0)          -> 0
#   So `git ok-thing; Failing-Cmdlet` exits 1 (the string as a whole failed)
#   while `Failing-Cmdlet; git ok-thing` exits 0 - the documented
#   final-statement limitation (see the header's KNOWN LIMITATION).
#   This lane never maps into the reserved 96-98 codes;
#   then overridden by the release outcome: stolen -> 98; unverifiable
#      ('unreadable') -> 1 if the command had succeeded (a failing command's
#      own code is kept); leftover -> the command's code is kept (cleanup
#      failure, not a serialisation failure; the warning is on stderr).
# The command runs with $ErrorActionPreference = 'Continue' (a sane default),
# not this script's internal 'Stop'. Its stdout/stderr flow to the host.
function Invoke-WithLock {
    param([string]$CommandString)
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    $script:LockRunRc = 0

    if ([string]::IsNullOrWhiteSpace($CommandString)) {
        [Console]::Error.WriteLine('git-commit-lock: empty command')
        $script:LockRunRc = 96
        return
    }
    # Parse BEFORE acquiring: a syntax error must never take (and then have to
    # release) the lock.
    try { $null = [scriptblock]::Create($CommandString) }
    catch {
        [Console]::Error.WriteLine("git-commit-lock: cannot parse command: $($_.Exception.Message)")
        $script:LockRunRc = 96
        return
    }
    # POSTAMBLE (verdict lane c): append a line that records the child
    # script's FINAL $? into a global the runner reads back - the only place
    # that state survives (the caller-side $? after `& file.ps1` is True even
    # when the script's last cmdlet failed; probed on both engines,
    # 2026-06-11). The interposed lone `;` is the trailing-backtick guard: a
    # command string ending in a line-continuation backtick splices our next
    # line into ITS last statement, and the `;` makes that splice terminate
    # the statement harmlessly instead of feeding the postamble to it as an
    # argument; an empty statement executes nothing, so $? is untouched
    # (probed). If the combined text somehow no longer parses (no known case
    # - the original already parsed), degrade to the bare command: lane c
    # then never fires, which is the pre-F2 behaviour, not a new failure.
    $staged = $CommandString + "`n;`n" + '$global:__gclRunOk = $?'
    try { $null = [scriptblock]::Create($staged) } catch { $staged = $CommandString }
    $tmpCmd = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "git-commit-lock.cmd.$PID.$(Get-Random).ps1")
    try {
        # UTF-8 WITH BOM: Windows PowerShell 5.1 reads BOM-less files as ANSI,
        # which would corrupt any non-ASCII in the caller's command string.
        [System.IO.File]::WriteAllText($tmpCmd, $staged, (New-Object System.Text.UTF8Encoding $true))
    } catch {
        [Console]::Error.WriteLine("git-commit-lock: cannot stage command file: $($_.Exception.Message)")
        $script:LockRunRc = 96
        return
    }

    try {
        if (-not (Lock-Acquire)) {
            # timeout -> 97 (the reserved code); reentrant misuse (dot-source
            # callers only) -> 1, matching git-commit-lock.sh's lock_acquire.
            if ($script:LockAcquireFail -eq 'reentrant') { $script:LockRunRc = 1 } else { $script:LockRunRc = 97 }
            return
        }
        try {
            try {
                # Sentinels for the verdict table (see the function comment):
                # $null marks "$LASTEXITCODE never set by the command" (a
                # stale pre-run value must not be misread as the command's),
                # $true marks "postamble never ran" (an `exit N` skips it;
                # lane b decides those).
                $global:LASTEXITCODE = $null
                $global:__gclRunOk = $true
                $ErrorActionPreference = 'Continue'
                & $tmpCmd
                $cmdRc = $LASTEXITCODE
                $cmdOk = $global:__gclRunOk
                if ($null -ne $cmdRc -and $cmdRc -ne 0) {
                    # lane b: a native exit code - the primary contract signal.
                    $script:LockRunRc = $cmdRc
                } elseif (-not $cmdOk) {
                    # lane c: the final statement failed but no native exit
                    # code says so (a failing cmdlet). The cmdlet's own error
                    # text is already on stderr above this note.
                    [Console]::Error.WriteLine('git-commit-lock: command failed without a native exit code (its final statement reported failure); exit 1')
                    $script:LockRunRc = 1
                } else {
                    # lane d: success ($LASTEXITCODE unset, or set to 0 with
                    # a succeeding final statement).
                    $script:LockRunRc = 0
                }
            } catch {
                # lane a: a terminating error must map to a nonzero rc here -
                # never fall through with $LockRunRc still 0 / a stale
                # $LASTEXITCODE.
                [Console]::Error.WriteLine("git-commit-lock: command failed: $($_.Exception.Message)")
                $script:LockRunRc = 1
            } finally {
                $ErrorActionPreference = 'Stop'
                # Drop the postamble's global so repeated in-session use (a
                # dot-source caller) never reads a previous run's verdict.
                Remove-Variable -Name __gclRunOk -Scope Global -ErrorAction SilentlyContinue
            }
        } finally {
            if (-not (Lock-Release)) {
                if ($script:LockReleaseStatus -eq 'unreadable') {
                    if ($script:LockRunRc -eq 0) { $script:LockRunRc = 1 }
                } elseif ($script:LockReleaseStatus -eq 'leftover') {
                    # Cleanup-only failure: the work WAS exclusive (token
                    # verified), warnings already on stderr - keep the
                    # command's exit code (matches git-commit-lock.sh).
                } else {
                    $script:LockRunRc = 98
                }
            }
        }
    } finally {
        try { [System.IO.File]::Delete($tmpCmd) } catch { }
    }
}

# --- CLI (only when executed directly, not when dot-sourced) ------------------
if ($MyInvocation.InvocationName -ne '.') {
    $script:LockUsage = @(
        'usage: git-commit-lock.ps1 run "<powershell command>"   (ONE quoted command string)',
        '   or: . git-commit-lock.ps1; Lock-Acquire; <git...>; Lock-Release',
        'exit codes: command''s own; 96 usage error; 97 lock wait timed out (command never ran);',
        '            98 lock stolen mid-hold (command ran but was NOT serialised - redo)'
    )
    # Explicit help as the FIRST argument is an answered question: usage on
    # STDOUT, exit 0. Genuine usage errors (no args, unknown subcommand) keep
    # stderr + 96. Two binder quirks (probed, pwsh 7.5 + 5.1): a token
    # starting '-' never binds to the positional $Action - the engine routes
    # it to $Rest (ValueFromRemainingArguments) - so the check looks at BOTH;
    # and a bare -? usually never reaches the script at all (both engines
    # intercept it as the common help parameter: auto-syntax to stdout, exit
    # 0), but a quoted/positional delivery (e.g. & path '-?') does arrive and
    # gets the same stdout/0 convention here.
    $gclHelpArg = $Action
    if (-not $gclHelpArg) {
        $gclRestArr = @(@($Rest) | Where-Object { $null -ne $_ })
        if ($gclRestArr.Count -gt 0) { $gclHelpArg = [string]$gclRestArr[0] }
    }
    if ($gclHelpArg -eq '--help' -or $gclHelpArg -eq '-h' -or $gclHelpArg -eq '-?') {
        foreach ($l in $script:LockUsage) { Write-Output $l }
        exit 0
    }
    switch ($Action) {
        'run' {
            # $Rest is $null (not an empty array) when no args follow: @($null)
            # has Count 1, so filter out nulls instead of just wrapping.
            $parts = @(@($Rest) | Where-Object { $null -ne $_ })
            if ($parts.Count -gt 0 -and $parts[0] -eq '--') {
                # NB: [1..0] would be a REVERSE range, not "empty" - guard Count 1.
                if ($parts.Count -eq 1) { $parts = @() } else { $parts = @($parts[1..($parts.Count - 1)]) }
            }
            if ($parts.Count -eq 0 -or ($parts.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$parts[0]))) {
                foreach ($l in $script:LockUsage) { [Console]::Error.WriteLine($l) }
                exit 96
            }
            if ($parts.Count -gt 1) {
                # Do NOT silently re-join: " " -join would destroy the caller's
                # quoting (e.g. run Write-Output 'two words' -> "two" "words").
                [Console]::Error.WriteLine("git-commit-lock: run takes ONE quoted command string; got $($parts.Count) arguments - quote the whole command")
                foreach ($l in $script:LockUsage) { [Console]::Error.WriteLine($l) }
                exit 96
            }
            if (-not $script:LockInRepo -and -not $env:AGENT_LOCK_PATH) {
                [Console]::Error.WriteLine('git-commit-lock: not inside a git repository and AGENT_LOCK_PATH is not set; refusing to guess a lock location (a CWD-scoped lock would not serialise anything). cd into the repo or set AGENT_LOCK_PATH.')
                exit 96
            }
            Invoke-WithLock -CommandString ([string]$parts[0])
            exit $script:LockRunRc
        }
        default {
            foreach ($l in $script:LockUsage) { [Console]::Error.WriteLine($l) }
            exit 96
        }
    }
}
