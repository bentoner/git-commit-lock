# git-commit-lock.ps1 - the git-commit-lock mutex (PowerShell port).
# Reachable at runtime as ~/.local/bin/git-commit-lock.ps1
# (symlinked there by this repo's install.sh).
#
# Works on PowerShell 7+ (pwsh); Windows PowerShell 5.1 is known to work
# (the file is plain ASCII, so the BOM-less encoding parses identically on
# both engines - keep it ASCII).
#
# PowerShell port of git-commit-lock.sh, for agents whose native shell is PowerShell
# (notably Codex on Windows). It is WIRE-COMPATIBLE with git-commit-lock.sh: the lock
# is the same regular FILE created with an atomic create-or-fail open, whose CONTENT
# is the ownership token (line 1, "tok."-prefixed; line 2 the informational
# "pid=<pid> host=<host>" owner), with the same file-mtime staleness /
# rename-aside-steal / token-compare-release protocol - so a .ps1 holder and a
# .sh holder in the SAME working tree (e.g. Codex and Claude) correctly serialise
# against EACH OTHER. git-commit-lock.sh remains the authoritative design (its header
# carries the full protocol: lock file format, staleness, acquire verification,
# fail-open lease ceiling, known residual races); docs/git-commit-lock.md is the
# "why". Keep the two in lock-step.
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
#     steal lane: renamed aside AND grave-deleted, so damage is capped at
#     the one misconfigured inode (in practice /dev permissions make real
#     device nodes unrenamable anyway). Same accepted class as the
#     empty-user-file residual.
#   * Release is File.Delete with a brief retry (~5x20ms) and NO rename-aside
#     fallback: probe D1 shows the handle class that blocks our unlink blocks
#     a rename identically for files (both need DELETE access on the source),
#     so the fallback could never fire usefully. One non-handle exception: the
#     Windows READ-ONLY attribute fails File.Delete but not File.Move (and
#     bash `rm -f` clears it). Nothing in the protocol ever sets read-only;
#     if something external does, the leftover warning fires and the stale
#     steal (a rename) recovers the path.
#   * Future option, this side only (recorded per the plan; NOT implemented):
#     handle-based ops (open with delete sharing, fstat the mtime / read the
#     token / delete via FILE_DISPOSITION on that one handle) could close the
#     residual check-then-act windows outright here. bash has no handle
#     persistence, so the protocol-level claim stays "shrunk, detected, not
#     closed" - see KNOWN RESIDUAL RACES in git-commit-lock.sh.
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
#       NEVER ran.
#   97  timed out waiting for the lock (AGENT_LOCK_MAX_WAIT). The command
#       NEVER ran.
#   98  the lock was STOLEN mid-hold (held past the stale window while a
#       contender waited): at release the lock file is GONE, or carries a
#       non-empty FOREIGN token - both definitive, because acquire's read-back
#       verified our token at the path. The command DID run but was NOT
#       serialised - verify with `git log` and redo it under the lock.
#   1   the command itself threw a terminating error; or (with its own distinct
#       warning) the lock file still reads EMPTY after the release-time retry
#       ladder while the file is present: ownership is unverifiable (that is
#       the create->write window of a successor after a boundary steal, or
#       external truncation - not proof of theft), the file is left in place,
#       and success is NOT reported. A failing command keeps its own exit
#       code. Same verdicts as git-commit-lock.sh for the same on-disk states.
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
# Hold the lock ONLY for the stage+commit (sub-second). Decide what to stage,
# build any patch, resolve hook failures OUTSIDE the lock. See README.md
# ("Suggested agent instructions").
#
# CONFIG (env, mainly for tests) - identical names/semantics to git-commit-lock.sh:
#   AGENT_LOCK_PATH (lock file path; default <gitdir>/commit.lock),
#   AGENT_LOCK_STALE_SECS (default 300), AGENT_LOCK_POLL_SECS (default 2),
#   AGENT_LOCK_MAX_WAIT (default 420), AGENT_LOCK_LOG.
#   Invalid numeric values are reported on stderr and replaced by the default
#   (never a load-time throw). STALE_SECS and MAX_WAIT must be positive
#   integers, POLL_SECS may be fractional - same rules as git-commit-lock.sh.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
    Justification = 'Deliberate throughout: lock-path I/O must never abort the holder. Every swallow is conservative (retry, skip, or fall through to a guarded slow path) and the file-mtime stale window is the recovery backstop. See docs/git-commit-lock.md.')]
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
$script:LockStale   = [int](script:Get-LockNum -Name 'AGENT_LOCK_STALE_SECS' -Raw $env:AGENT_LOCK_STALE_SECS -Default 300 -IntegerOnly)
$script:LockPoll    = [double](script:Get-LockNum -Name 'AGENT_LOCK_POLL_SECS' -Raw $env:AGENT_LOCK_POLL_SECS -Default 2)
$script:LockMaxWait = [int](script:Get-LockNum -Name 'AGENT_LOCK_MAX_WAIT' -Raw $env:AGENT_LOCK_MAX_WAIT -Default 420 -IntegerOnly)

# A waiter gives up at MAX_WAIT, so STALE >= MAX_WAIT means waiters time out
# before a crashed holder's lock could ever be stolen. Warn only in the
# documented footgun case - STALE raised while MAX_WAIT was left at default;
# a caller who set BOTH knobs chose the relationship deliberately.
if (-not $env:AGENT_LOCK_MAX_WAIT -and $script:LockStale -ge $script:LockMaxWait) {
    [Console]::Error.WriteLine("git-commit-lock: warning - AGENT_LOCK_STALE_SECS ($($script:LockStale)) >= AGENT_LOCK_MAX_WAIT ($($script:LockMaxWait), default): waiters will time out before a stale lock can be stolen; raise AGENT_LOCK_MAX_WAIT too")
}

# Floor for a PLAUSIBLE lock mtime (epoch secs; 2000-01-01). A freshly created
# file can transiently report the Windows FILETIME zero (1601-01-01 -> a NEGATIVE
# unix epoch) to an observer (probes C/C1b - files, not just the old dirs), which
# would compute as a ~400-year "age" and trigger a spurious steal of a live,
# just-acquired lock. Any mtime below this floor is an unsettled/garbage reading,
# not a genuinely stale lock, so we refuse to steal on it and wait instead.
$script:LockMtimeFloor = 946684800

$script:LockHeld = $false
# Unique per acquisition: identifies OUR hold so release can tell whether the lock
# it is about to free is still the one we took. pid alone isn't enough (pids get
# reused across the stale window), so mix in Get-Random + the acquire time. The
# "tok." prefix is WIRE FORMAT (the steal's content guard keys on it - see LOCK
# FILE FORMAT in git-commit-lock.sh); the ".ps" marker just helps when reading a
# mixed log.
$script:LockToken = ''
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

# Link-aware existence probe: the FileSystemInfo for the path ITSELF (a
# dangling symlink included - it must read as "exists but wrong type" so the
# guard warns instead of classing it as normal contention every poll), or
# $null when the path is absent. Get-Item -Force sees the link, not the
# target; [IO.File]::Exists would report a dangling link as absent.
function script:Lock-GetPathItem {
    Set-StrictMode -Off
    try { return (Get-Item -LiteralPath $script:LockPath -Force -ErrorAction Stop) } catch { return $null }
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
# Retries with escalating backoff (20ms..320ms): under heavy contention a read
# can transiently hit a sharing violation or the empty window, and crying
# "stolen" on that would be false. A REAL steal renames the file away, so a
# successful read then returns a DIFFERENT token (still a mismatch) - retrying
# never hides a genuine theft. The FileStream opens with ReadWrite|Delete
# sharing so this read can never block a rival's steal/release (probe D2).
function script:Lock-ReadCurToken {
    param([int]$MaxTries = 8)
    Set-StrictMode -Off
    $delay = 20
    for ($i = 0; $i -lt $MaxTries; $i++) {
        try {
            $line = $null
            $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::Open,
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
            if (-not (Test-Path -LiteralPath $script:LockPath)) { return @{ Status = 'gone'; Token = '' } }
        }
        Start-Sleep -Milliseconds $delay
        if ($delay -lt 320) { $delay = $delay * 2 }
    }
    if (Test-Path -LiteralPath $script:LockPath) { return @{ Status = 'unreadable'; Token = '' } }
    return @{ Status = 'gone'; Token = '' }
}

# Atomic create-or-fail for the lock FILE, with the token+owner content
# written, flushed and closed THROUGH the creation handle: the write is bound
# to the file object we created and cannot land on a successor's file,
# whatever happens to the path meanwhile. CreateNew + the content write stamp
# the mtime (the staleness clock); no post-create stamp is needed - the floor
# guard is the backstop for unsettled readings. The handle shares
# ReadWrite|Delete so a waiter's probes never collide with the creation.
# Returns $true iff we created the file. ANY exception means "not created":
# IOException = a rival's live lock (normal contention); an existing directory
# throws UnauthorizedAccessException; on Unix a FIFO/device path fails the
# O_CREAT|O_EXCL open with its own exception. All of them must degrade to the
# wait loop - which diagnoses the non-file cases - never throw out of acquire.
# A created-but-write-failed file (e.g. ENOSPC) returns $false too; the empty
# or torn orphan it leaves ages into its corresponding steal lane.
function script:Lock-TryCreateFile {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($script:LockPath, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        # BOM-free UTF-8, LF line ends: the shared wire format (line 1 token,
        # line 2 owner), readable by the .sh side's plain `read`.
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes("$script:LockToken`n$script:LockMe`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
}

# Opportunistic, age-gated sweep of steal graves beside the lock (`.dead.*`,
# left when a steal winner's grave delete failed - mirrored in
# git-commit-lock.sh; the dir era's `.new.*`/`.rel.*` litter cannot exist in
# the file protocol). Only entries older than the stale window (with a
# plausible mtime) are swept, and only via the non-recursive File.Delete: a
# directory or other non-file at a grave name is skipped (and would make
# File.Delete throw anyway). Pure best-effort: any failure just leaves the
# entry for a later sweep.
function script:Lock-SweepLitter {
    Set-StrictMode -Off
    try {
        $parent = Split-Path -Parent $script:LockPath
        $leaf = Split-Path -Leaf $script:LockPath
        if (-not $parent -or -not $leaf) { return }
        if (-not (Test-Path -LiteralPath $parent)) { return }
        $now = script:Lock-Now
        foreach ($g in @(Get-ChildItem -LiteralPath $parent -Filter "$leaf.dead.*" -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($g.PSIsContainer) { continue }   # never recursive: a dir grave stays
                $mt = ([DateTimeOffset]$g.LastWriteTimeUtc).ToUnixTimeSeconds()
                if ($mt -gt $script:LockMtimeFloor -and ($now - $mt) -ge $script:LockStale) {
                    [System.IO.File]::Delete($g.FullName)
                    script:Lock-Log "SWEPT stale litter $($g.Name)"
                }
            } catch { }
        }
    } catch { }
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
    script:Lock-SweepLitter
    $start = script:Lock-Now
    $script:LockToken = "tok.ps.$PID.$(Get-Random).$start"
    $waitingLogged = $false
    # Log damper for a squatted stale lock (a no-delete-share handle, or an
    # unwritable parent dir, makes the steal rename fail every poll with the
    # file still present): epoch of the last logged failed-steal attempt, 0
    # when the last attempt did not fail that way. While the failures persist,
    # the STALE/steal-FAILED pair is logged at most once per stale window, so
    # the log growth stays bounded however long the squat lasts (mirrors
    # git-commit-lock.sh).
    $stealFailLast = 0
    # Two-consecutive-poll confirmation state for the wrong-type guard below
    # (parity with git-commit-lock.sh's round-3 hardening): the concrete
    # classification observed on the PREVIOUS blocked poll, reset to '' when
    # a poll sees the path absent or a plain regular file.
    $nonlockPrev = ''

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

        if ($creatable -and (script:Lock-TryCreateFile)) {
            # The file now carries our token and its mtime (the staleness
            # clock) is stamped by the creating write.
            #
            # VERIFY via a path read-back before claiming the hold (see
            # ACQUIRE VERIFICATION in git-commit-lock.sh): only our own token
            # proves we hold the path. NEVER repair a failed read-back by
            # writing to the path - after a long suspension the path may
            # legitimately belong to a successor.
            $rb = script:Lock-ReadCurToken -MaxTries 8
            if ($rb.Status -eq 'ok' -and $rb.Token -eq $script:LockToken) {
                $script:LockHeld = $true
                script:Lock-RegisterExitBackstop
                script:Lock-Log "ACQUIRED ($script:LockMe tok=$script:LockToken)"
                return $true
            }
            $found = $rb.Token; if (-not $found) { $found = '<empty-or-gone>' }
            script:Lock-Log "WARNING: acquire verification FAILED - create won but read-back found '$found' (ours=$script:LockToken); not acquired, re-entering wait"
            [Console]::Error.WriteLine('git-commit-lock: WARNING - acquire verification failed: the lock file did not read back our token; treating the lock as NOT acquired and waiting')
            # fall through to the blocked branch of this same iteration
        }

        # Blocked (create lost, was skipped by the type guard, or won-but-
        # failed verification). One WAITING line on the first blocked poll
        # only: lets a log reader see this acquirer actually contended, and
        # lets tests hold-until-WAITING instead of sleeping.
        if (-not $waitingLogged) {
            $waitingLogged = $true
            script:Lock-Log "WAITING for lock ($script:LockMe tok=$script:LockToken)"
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
                            # Re-read the mtime IMMEDIATELY before the steal: a
                            # rival may have completed steal+re-acquire since
                            # our read above, in which case the file is now a
                            # brand-new LIVE lock and renaming it aside would
                            # rob it. Any change (fresher, sub-floor, or gone)
                            # aborts this attempt and re-enters the loop. This
                            # SHRINKS the check-then-act window; it cannot
                            # close it with these primitives - see KNOWN
                            # RESIDUAL RACES in git-commit-lock.sh (the
                            # residual is detected at the victim's release).
                            $mt2 = script:Lock-PathMtime
                            if ($null -eq $mt2 -or $mt2 -ne $mt) {
                                $now2 = '<gone>'; if ($null -ne $mt2) { $now2 = $mt2 }
                                script:Lock-Log "steal aborted: lock file mtime changed underneath us (was $mt, now $now2)"
                                continue
                            }
                            # Damp the attempt logging while the steal keeps
                            # failing on a squatted file (see $stealFailLast
                            # above): first failure, then at most once per
                            # stale window.
                            $nowS = script:Lock-Now
                            $logSteal = ($stealFailLast -eq 0 -or ($nowS - $stealFailLast) -ge $script:LockStale)
                            if ($logSteal) { script:Lock-Log "STALE (age=${age}s holder=$holder) -> stealing" }
                            # Atomic steal: rename the stale file aside. Only
                            # one concurrent stealer wins (the rest throw and
                            # re-poll); then everyone re-races the create. The
                            # victim (if still alive) will fail at ITS release:
                            # gone or foreign token => 98.
                            $grave = "$($script:LockPath).dead.$PID.$nowS"
                            $stole = $false
                            try {
                                [System.IO.File]::Move($script:LockPath, $grave)
                                $stole = $true
                            } catch { }
                            if ($stole) {
                                try { [System.IO.File]::Delete($grave) } catch { }
                                script:Lock-Log "STOLE stale lock (was held by $holder)"
                                $stealFailLast = 0
                                continue   # won the steal: immediately re-race the create
                            }
                            if ($null -eq (script:Lock-GetPathItem)) {
                                # Lost the race (a rival's rename won; the file
                                # is gone): re-race the create immediately.
                                $stealFailLast = 0
                                continue
                            }
                            # The rename failed with the file STILL PRESENT: a
                            # no-delete-share handle squatting the file (it
                            # blocks rename exactly like the release unlink -
                            # probe D1) or an unwritable parent dir. Nothing
                            # will change until the squatter lets go, so this
                            # must NOT skip the timeout check + poll sleep
                            # below: an unconditional `continue` here busy-spun
                            # flat-out and could never reach 97 (review
                            # finding, 2026-06-11). Fall through instead.
                            if ($logSteal) {
                                script:Lock-Log "steal FAILED: rename refused with the lock file still present (no-delete-share handle, or unwritable parent dir); re-polling - repeats logged at most once per $($script:LockStale)s"
                                $stealFailLast = $nowS
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
            return $false
        }
        # -Milliseconds, not -Seconds: Windows PowerShell 5.1's -Seconds is an
        # Int32, so a fractional poll (e.g. the tests' 0.05) would truncate to a
        # busy-spin there.
        Start-Sleep -Milliseconds ([int][Math]::Max(1, $script:LockPoll * 1000))
    }
}

# Release. Returns $true if we held the lock cleanly throughout. Returns $false
# otherwise, with $script:LockReleaseStatus saying why:
#   'stolen'      our lease was stolen before release - the lock file is GONE,
#                 or carries a non-empty FOREIGN token (both definitive:
#                 acquire's read-back proved our token was at the path). The
#                 work we just did was NOT exclusive and should be treated as
#                 failed (run -> exit 98);
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
            script:Lock-Log "WARNING: release FAILED - could not delete the lock file after 5 attempts; LEFTOVER (tok=$script:LockToken). Waiters are blocked until the $($script:LockStale)s stale window elapses AND the blocking handle closes."
            [Console]::Error.WriteLine("git-commit-lock: WARNING - could not remove the lock file ($script:LockPath); it is left behind and will block waiters until the $($script:LockStale)s stale window expires and whatever holds it open lets go")
            return $false
        }
        # else: the file vanished while the delete kept failing - already
        # gone, equally released (the same branch File.Delete's silent-on-
        # missing behaviour covers).
    }
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
#      in-session caller can never read a stale $LASTEXITCODE as success);
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
    $tmpCmd = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "git-commit-lock.cmd.$PID.$(Get-Random).ps1")
    try {
        # UTF-8 WITH BOM: Windows PowerShell 5.1 reads BOM-less files as ANSI,
        # which would corrupt any non-ASCII in the caller's command string.
        [System.IO.File]::WriteAllText($tmpCmd, $CommandString, (New-Object System.Text.UTF8Encoding $true))
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
                $global:LASTEXITCODE = 0
                $ErrorActionPreference = 'Continue'
                & $tmpCmd
                if ($null -ne $LASTEXITCODE) { $script:LockRunRc = $LASTEXITCODE } else { $script:LockRunRc = 0 }
            } catch {
                # A terminating error must map to a nonzero rc here - never fall
                # through with $LockRunRc still 0 / a stale $LASTEXITCODE.
                [Console]::Error.WriteLine("git-commit-lock: command failed: $($_.Exception.Message)")
                $script:LockRunRc = 1
            } finally {
                $ErrorActionPreference = 'Stop'
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
