# git-commit-lock.ps1 - the git-commit-lock mutex (PowerShell port).
# Reachable at runtime as ~/.local/bin/git-commit-lock.ps1
# (symlinked there by this repo's install.sh).
#
# Works on PowerShell 7+ (pwsh); Windows PowerShell 5.1 is known to work
# (the file is plain ASCII, so the BOM-less encoding parses identically on
# both engines - keep it ASCII).
#
# PowerShell port of git-commit-lock.sh, for agents whose native shell is PowerShell
# (notably Codex on Windows). It is WIRE-COMPATIBLE with git-commit-lock.sh: same lock
# directory, same dir-mtime staleness / rename-steal / token-release protocol, so
# a .ps1 holder and a .sh holder in the SAME working tree (e.g. Codex and Claude)
# correctly serialise against EACH OTHER. git-commit-lock.sh remains the authoritative
# design; docs/git-commit-lock.md is the "why". Keep the two in lock-step.
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
# USAGE (Codex's normal path - run ONE quoted command string under the lock):
#   & ~/.local/bin/git-commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
#
# EXIT CODES of `run` (identical contract to git-commit-lock.sh):
#   the command's own exit code - including a code set via `exit N` INSIDE the
#       command (the command runs as a child script, so its `exit` is contained
#       and propagates cleanly; it does not abort the lock release);
#   96  usage / configuration error: bad arguments, more than one command
#       argument, an empty or unparseable command, or `run` outside a git repo
#       with AGENT_LOCK_DIR unset. The lock was NEVER acquired and the command
#       NEVER ran.
#   97  timed out waiting for the lock (AGENT_LOCK_MAX_WAIT). The command
#       NEVER ran.
#   98  the lock was STOLEN mid-hold (held past the stale window while a
#       contender waited). The command DID run but was NOT serialised - verify
#       with `git log` and redo it under the lock.
#   1   the command itself threw a terminating error; or (with its own distinct
#       warning) the release-time token read kept failing - or found the token
#       file MISSING - while the lock dir still existed: the work may or may
#       not have been exclusive (neither impl can prove its own acquire-time
#       token write landed, so a missing token is NOT proof of theft), the
#       lock dir is left in place for the stale window to reclaim, and success
#       is NOT reported. A failing command keeps its own exit code. Same
#       verdicts as git-commit-lock.sh for the same on-disk states.
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
#     Invoke-WithLock), the script:-scoped helpers (Lock-* / Get-LockGitDir),
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
#   * Lock-Release returns $true on a clean release; $false otherwise, with
#     $script:LockReleaseStatus set to 'stolen' (token mismatch / dir gone:
#     your work was NOT exclusive - redo), 'unreadable' (token unreadable or
#     MISSING while the lock dir still exists: exclusivity unproven, dir left
#     for the stale window; do not report success), or 'leftover' (token
#     verified - the work WAS exclusive - but the dir could be neither deleted
#     nor renamed aside; waiters stay blocked until the stale window reclaims
#     it; `run` keeps the command's exit code and warns on stderr, mirroring
#     git-commit-lock.sh).
#
# Hold the lock ONLY for the stage+commit (sub-second). Decide what to stage,
# build any patch, resolve hook failures OUTSIDE the lock. See README.md
# ("Suggested agent instructions").
#
# CONFIG (env, mainly for tests) - identical names/semantics to git-commit-lock.sh:
#   AGENT_LOCK_DIR, AGENT_LOCK_STALE_SECS (default 300), AGENT_LOCK_POLL_SECS
#   (default 2), AGENT_LOCK_MAX_WAIT (default 420), AGENT_LOCK_LOG.
#   Invalid numeric values are reported on stderr and replaced by the default
#   (never a load-time throw). STALE_SECS and MAX_WAIT must be positive
#   integers, POLL_SECS may be fractional - same rules as git-commit-lock.sh.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
    Justification = 'Deliberate throughout: lock-path I/O must never abort the holder. Every swallow is conservative (retry, skip, or fall through to a guarded slow path) and the dir-mtime stale window is the recovery backstop. See docs/git-commit-lock.md.')]
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
# compute the SAME lock-dir string and contend on the same NTFS directory.
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
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $Default }
    $val = 0.0
    $ok = [double]::TryParse($Raw, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)
    # Integer knobs (STALE_SECS / MAX_WAIT) take plain digit strings only,
    # exactly like git-commit-lock.sh's validator: a fractional stale window
    # would otherwise be silently rounded here but rejected there - same
    # input, different steal threshold across the two impls.
    if ($IntegerOnly -and $Raw -notmatch '^[0-9]+$') { $ok = $false }
    if (-not $ok -or $val -le 0) {
        $want = 'positive number'; if ($IntegerOnly) { $want = 'positive integer' }
        [Console]::Error.WriteLine("git-commit-lock: ignoring invalid $Name='$Raw' (want a $want); using default $Default")
        return $Default
    }
    return $val
}

$script:LockGitDir = script:Get-LockGitDir
$script:LockInRepo = [bool]$script:LockGitDir
if ($script:LockInRepo) { $script:LockBase = $script:LockGitDir } else { $script:LockBase = (Get-Location).Path }
# Not in a repo: the CLI `run` path hard-fails (exit 96) unless AGENT_LOCK_DIR
# is set; dot-sourcing keeps the CWD fallback (so sourcing never explodes) but
# says so out loud.
if (-not $script:LockInRepo -and -not $env:AGENT_LOCK_DIR -and $MyInvocation.InvocationName -eq '.') {
    [Console]::Error.WriteLine("git-commit-lock: WARNING - not inside a git repository; defaulting the lock to $script:LockBase/commit.lock (CWD). Set AGENT_LOCK_DIR to control this.")
}

if ($env:AGENT_LOCK_DIR) { $script:LockDir = $env:AGENT_LOCK_DIR } else { $script:LockDir = "$script:LockBase/commit.lock" }
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
# dir can transiently report the Windows FILETIME zero (1601-01-01 -> a NEGATIVE
# unix epoch) in the window between creation and its first metadata write, which
# would compute as a ~400-year "age" and trigger a spurious steal of a live,
# just-acquired lock. Any mtime below this floor is an unsettled/garbage reading,
# not a genuinely stale lock, so we refuse to steal on it and wait instead.
$script:LockMtimeFloor = 946684800

$script:LockHeld = $false
# Unique per acquisition: identifies OUR hold so release can tell whether the lock
# it is about to free is still the one we took. pid alone isn't enough (pids get
# reused across the stale window), so mix in Get-Random + the acquire time. The
# ".ps" marker just helps when reading a mixed log. Format need NOT match the .sh
# token - steal detection only needs inequality, and each side reads its own.
$script:LockToken = ''
$script:LockMe = "pid=$PID host=$env:COMPUTERNAME"
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
        [System.IO.File]::AppendAllText($script:LockLog, "$ts [pid=$PID] $msg`n")
    } catch { }
}

# mtime (epoch secs) of the lock dir itself - the staleness clock, same value the
# .sh side reads via `stat -c %Y`. $null if the dir vanished mid-check. If the
# read keeps failing while the dir EXISTS, staleness detection is broken on
# this system - crashed holders can then never be stolen - so say so loudly,
# once per process (parity with git-commit-lock.sh's warning). The retry loop
# is anti-false-alarm: under contention the dir routinely vanishes
# (release/steal) between probes, which must not be misdiagnosed as a broken
# clock - only persistent failure on a present dir counts.
$script:LockMtimeWarned = $false
function script:Lock-DirMtime {
    Set-StrictMode -Off
    $m = $null; $present = $false
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $item = Get-Item -LiteralPath $script:LockDir -Force -ErrorAction Stop
            $m = ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
            break
        } catch {
            $m = $null
            if (Test-Path -LiteralPath $script:LockDir) { $present = $true } else { $present = $false; break }
        }
    }
    if ($null -eq $m -and $present -and -not $script:LockMtimeWarned) {
        $script:LockMtimeWarned = $true
        [Console]::Error.WriteLine("git-commit-lock: WARNING - cannot read the lock dir's mtime on this system. Staleness detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges waiters until AGENT_LOCK_MAX_WAIT.")
        script:Lock-Log 'WARNING: lock-dir mtime unreadable (probes failed with the dir present); staleness detection disabled'
    }
    return $m
}

# Read the token currently recorded in the lock dir (whoever holds it now),
# distinguishing three outcomes so Lock-Release can be honest about what it saw:
#   Status='ok'         Token = the recorded token
#   Status='gone'       the lock dir itself no longer exists (stolen + freed)
#   Status='unreadable' the dir exists but the token could not be read after
#                       escalating retries - either the file would not open (a
#                       persistent Windows sharing violation) or it is MISSING
#                       while the dir is present. Neither is proof of theft (a
#                       real steal renames the dir away, and our own
#                       acquire-time token write is swallowed after retries,
#                       so we cannot prove it ever landed) - and not proof of
#                       ownership either. Mirrors git-commit-lock.sh, where
#                       `cat` cannot distinguish ENOENT from a sharing
#                       violation: BOTH impls route this state to the
#                       conservative unverifiable lane, never to "stolen".
# Retries with escalating backoff (20ms..320ms): under heavy contention a read
# can transiently hit a sharing violation, and crying "stolen" on that would be
# false. A REAL steal renames the dir away, so a successful read then returns a
# DIFFERENT token (still a mismatch) - retrying never hides a genuine theft.
function script:Lock-ReadCurToken {
    param([int]$MaxTries = 8)
    Set-StrictMode -Off
    $delay = 20
    for ($i = 0; $i -lt $MaxTries; $i++) {
        try {
            return @{ Status = 'ok'; Token = ([System.IO.File]::ReadAllText("$script:LockDir/token")).Trim() }
        } catch [System.IO.DirectoryNotFoundException] {
            return @{ Status = 'gone'; Token = '' }
        } catch {
            # FileNotFoundException (dir present, token file absent) lands
            # here too: retry like any other failed read, then fall through to
            # 'unreadable' - NOT a definitive verdict (see the contract above).
            if (-not (Test-Path -LiteralPath $script:LockDir)) { return @{ Status = 'gone'; Token = '' } }
            Start-Sleep -Milliseconds $delay
            if ($delay -lt 320) { $delay = $delay * 2 }
        }
    }
    if (Test-Path -LiteralPath $script:LockDir) { return @{ Status = 'unreadable'; Token = '' } }
    return @{ Status = 'gone'; Token = '' }
}

# Atomic create-or-fail for a DIRECTORY. PowerShell's `New-Item -ItemType
# Directory` checks existence then creates (a TOCTOU window two racers can both
# pass), and [IO.Directory]::CreateDirectory SILENTLY succeeds on an existing dir
# - neither is a mutex gate. So we create a uniquely-named temp dir and ATOMICALLY
# rename it into place: [IO.Directory]::Move throws if the destination exists, and
# the NTFS rename lets exactly one racer win (the .sh side's `mkdir` is the same
# atomic gate, contending on the same path). Returns $true iff we created it.
function script:Lock-TryCreateDir {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    $parent = Split-Path -Parent $script:LockDir
    if ($parent) { try { [void][System.IO.Directory]::CreateDirectory($parent) } catch { } }
    $tmp = "$($script:LockDir).new.$PID.$(Get-Random)"
    try { [void][System.IO.Directory]::CreateDirectory($tmp) } catch { return $false }
    try {
        [System.IO.Directory]::Move($tmp, $script:LockDir)   # throws if dest exists
        # Stamp the staleness clock NOW, the instant the dir becomes visible, so a
        # waiter can't catch an unsettled FILETIME-zero (1601) mtime and steal our
        # brand-new lock. The floor guard in Lock-Acquire is the real backstop;
        # this just shrinks the window.
        try { [System.IO.Directory]::SetLastWriteTimeUtc($script:LockDir, [DateTime]::UtcNow) } catch { }
        return $true
    } catch {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
        return $false
    }
}

# Opportunistic, age-gated sweep of litter beside the lock: failed-delete graves
# (<lock>.dead.* from steals, <lock>.rel.* from releases - both impls) and
# orphaned acquire temps (<lock>.new.*, ours). Only entries older than the stale
# window are touched, so a LIVE acquirer's .new temp mid-rename is never swept.
# Pure best-effort: every step is guarded, failure changes nothing.
function script:Lock-SweepLitter {
    Set-StrictMode -Off
    try {
        $parent = Split-Path -Parent $script:LockDir
        $leaf = Split-Path -Leaf $script:LockDir
        if (-not $parent -or -not $leaf) { return }
        if (-not (Test-Path -LiteralPath $parent)) { return }
        $now = script:Lock-Now
        foreach ($pat in @("$leaf.new.*", "$leaf.dead.*", "$leaf.rel.*")) {
            foreach ($d in @(Get-ChildItem -LiteralPath $parent -Filter $pat -Force -ErrorAction SilentlyContinue)) {
                try {
                    $mt = ([DateTimeOffset]$d.LastWriteTimeUtc).ToUnixTimeSeconds()
                    if ($mt -gt $script:LockMtimeFloor -and ($now - $mt) -ge $script:LockStale) {
                        [System.IO.Directory]::Delete($d.FullName, $true)
                        script:Lock-Log "SWEPT stale litter $($d.Name)"
                    }
                } catch { }
            }
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
        $bsDir = $script:LockDir.Replace("'", "''")
        $bsTok = $script:LockToken.Replace("'", "''")
        $bsLog = $script:LockLog.Replace("'", "''")
        $action = [scriptblock]::Create(
            "try { `$cur = ([System.IO.File]::ReadAllText('$bsDir/token')).Trim(); " +
            "if (`$cur -eq '$bsTok') { [System.IO.Directory]::Delete('$bsDir', `$true); " +
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
    $start = script:Lock-Now
    $script:LockToken = "tok.ps.$PID.$(Get-Random).$(script:Lock-Now)"
    script:Lock-SweepLitter

    while ($true) {
        if (script:Lock-TryCreateDir) {
            # Won the lock. Write our token (used by Lock-Release to confirm we
            # still own it) plus owner/epoch for logging. BOM-free UTF8 so the .sh
            # side reads them cleanly. All guarded: a failed write must not abort.
            # Token write is load-bearing: Lock-Release compares it to detect a
            # steal, so a silently-dropped write here would later look like a theft
            # (a false "stolen mid-hold"). Retry briefly - we just created the dir
            # and hold it exclusively, so a transient sharing hiccup clears fast.
            for ($i = 0; $i -lt 5; $i++) {
                try { [System.IO.File]::WriteAllText("$script:LockDir/token", "$script:LockToken`n"); break }
                catch { Start-Sleep -Milliseconds 20 }
            }
            try { [System.IO.File]::WriteAllText("$script:LockDir/epoch", "$(script:Lock-Now)`n") } catch { }
            try { [System.IO.File]::WriteAllText("$script:LockDir/owner", "$script:LockMe`n") } catch { }
            $script:LockHeld = $true
            script:Lock-RegisterExitBackstop
            script:Lock-Log "ACQUIRED ($script:LockMe tok=$script:LockToken)"
            return $true
        }

        # Lock exists. Steal it if the DIR's mtime is older than the stale window -
        # but ONLY if the mtime is a plausible reading. A sub-floor value is an
        # unsettled FILETIME-zero (1601) read of a just-created lock, NOT a stale
        # one; stealing on it would yank a live, brand-new lock (the cross-impl
        # race the interop self-test caught 2026-06-03). Treat it as recent: wait.
        $mt = script:Lock-DirMtime
        if ($null -ne $mt -and $mt -gt $script:LockMtimeFloor) {
            $age = (script:Lock-Now) - $mt
            if ($age -ge $script:LockStale) {
                $holder = '?'
                try { $holder = ([System.IO.File]::ReadAllText("$script:LockDir/owner")).Trim() } catch { }
                script:Lock-Log "STALE (age=${age}s holder=$holder) -> stealing"
                # Re-read the mtime IMMEDIATELY before the steal: between our
                # staleness reading and the Move, the stale dir may have been
                # freed and re-created by a NEW live holder (or a rival stealer
                # may have done steal+re-acquire). Abort the steal unless the
                # reading is unchanged. This SHRINKS the check-then-act window
                # to the Move itself rather than closing it; the residual race
                # is detected, not silent - a wrongly-moved victim's release
                # cries stolen instead of reporting success.
                $mt2 = script:Lock-DirMtime
                if ($null -eq $mt2 -or $mt2 -ne $mt) {
                    script:Lock-Log "STEAL-ABORT (lock dir mtime changed under us; treating it as live)"
                    continue
                }
                # Atomic steal: rename the stale dir aside. Only one concurrent
                # stealer wins (the rest throw); then everyone re-races create.
                $grave = "$($script:LockDir).dead.$PID.$(script:Lock-Now)"
                try {
                    [System.IO.Directory]::Move($script:LockDir, $grave)
                    try { [System.IO.Directory]::Delete($grave, $true) } catch { }
                    script:Lock-Log "STOLE stale lock (was held by $holder)"
                } catch { }
                continue
            }
        }

        # A live holder has it - wait, unless we have waited too long.
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
#   'stolen'      our lease was stolen before release - the work we just did was
#                 NOT exclusive and should be treated as failed (run -> exit 98);
#   'unreadable'  the lock dir still exists but its token could not be read
#                 even after escalating retries - the file would not open (a
#                 persistent sharing violation) or it is MISSING. Neither is
#                 proof of theft, and not proof of ownership either, so we do
#                 NOT delete the dir (the stale window reclaims it; an
#                 opportunistic sweep cleans any grave litter) and we do NOT
#                 report success (run -> exit 1 unless the command already
#                 failed with its own code);
#   'leftover'    the token verified (the work WAS exclusive) but the dir could
#                 be neither deleted nor renamed aside, so the lock is left in
#                 place blocking waiters until the stale window. A cleanup
#                 failure, not a serialisation failure: `run` keeps the
#                 command's exit code and warns on stderr.
function Lock-Release {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'
    if (-not $script:LockHeld) { return $true }
    $script:LockHeld = $false
    $script:LockReleaseStatus = 'ok'
    script:Lock-UnregisterExitBackstop

    # Did we keep the lock the whole time? Compare the dir's current token to ours.
    $read = script:Lock-ReadCurToken -MaxTries 8
    if ($read.Status -eq 'unreadable') {
        $script:LockReleaseStatus = 'unreadable'
        script:Lock-Log "WARNING: token UNREADABLE or MISSING at release (lock dir still present; exclusivity unproven, dir left for the stale window). NOT claiming success. (ours=$script:LockToken)"
        [Console]::Error.WriteLine("git-commit-lock: WARNING - could not read the lock token at release (missing token file or persistent sharing violation). Exclusivity is unproven; the lock dir was left in place and will be reclaimed after the stale window. Verify with 'git log' before relying on this commit.")
        return $false
    }
    if ($read.Status -eq 'gone' -or $read.Token -ne $script:LockToken) {
        # Our lease expired and the lock was stolen (possibly re-acquired by
        # someone else). Do NOT delete the dir - it may be a successor's LIVE lock.
        $now = $read.Token; if (-not $now) { $now = '<none>' }
        script:Lock-Log "WARNING: lock LOST before release (held longer than $($script:LockStale)s stale window; stolen). This commit was NOT exclusive - redo it. (ours=$script:LockToken now=$now)"
        [Console]::Error.WriteLine("git-commit-lock: WARNING - lock was stolen mid-hold (held > $($script:LockStale)s). Your commit was NOT serialised; verify with 'git log' and redo under the lock.")
        $script:LockReleaseStatus = 'stolen'
        return $false
    }

    # Still ours. Re-read the token IMMEDIATELY before the delete: this shrinks
    # (does NOT close) the check-then-act window in which a boundary steal +
    # re-acquire could slip between our check and the Delete - the residual
    # race is detected, not silent (the successor's release would cry stolen).
    # An 'unreadable' result here does not divert: the robust read above already
    # said the lock is ours, and unreadable is not evidence to the contrary.
    $read2 = script:Lock-ReadCurToken -MaxTries 2
    if ($read2.Status -eq 'gone' -or ($read2.Status -eq 'ok' -and $read2.Token -ne $script:LockToken)) {
        $now = $read2.Token; if (-not $now) { $now = '<none>' }
        script:Lock-Log "WARNING: lock LOST at release boundary (stolen between check and delete). This commit was NOT exclusive - redo it. (ours=$script:LockToken now=$now)"
        [Console]::Error.WriteLine("git-commit-lock: WARNING - lock was stolen mid-hold (held > $($script:LockStale)s). Your commit was NOT serialised; verify with 'git log' and redo under the lock.")
        $script:LockReleaseStatus = 'stolen'
        return $false
    }

    # Free it. Recovery (rename-aside) triggers ONLY on a failed delete: while
    # the dir exists no one else can create it, so it is unambiguously ours and
    # the rename is safe. We must NOT re-check existence after a *successful*
    # delete - by then a successor may have re-created the dir and entered its
    # own critical section, and moving it aside would steal that live lock
    # (two holders -> lost update).
    $deleted = $false
    try { [System.IO.Directory]::Delete($script:LockDir, $true); $deleted = $true } catch { $deleted = $false }
    if (-not $deleted) {
        $grave = "$($script:LockDir).rel.$PID.$(script:Lock-Now)"
        $renamed = $false
        try {
            [System.IO.Directory]::Move($script:LockDir, $grave)
            $renamed = $true
            # Renamed aside: the lock IS released (waiters can re-create the
            # dir). The grave is best-effort litter; the sweep at the next
            # acquire collects stragglers.
            try { [System.IO.Directory]::Delete($grave, $true) } catch { }
        } catch { $renamed = $false }
        if (-not $renamed -and (Test-Path -LiteralPath $script:LockDir)) {
            # Both the delete and the rename failed and the dir is still in
            # place: the lock is NOT released. The work itself WAS exclusive
            # (token verified above), so this is a cleanup failure, not a
            # serialisation failure - but do NOT log RELEASED or claim a clean
            # release: waiters stay blocked until the stale-window mtime
            # backstop reclaims the dir. (Mirrors git-commit-lock.sh.)
            $script:LockReleaseStatus = 'leftover'
            script:Lock-Log "WARNING: release FAILED - delete and rename-aside both failed; lock dir left in place (tok=$script:LockToken). Waiters are blocked until the $($script:LockStale)s stale window reclaims it."
            [Console]::Error.WriteLine("git-commit-lock: WARNING - could not remove the lock dir ($script:LockDir); it is left behind and will block waiters until the $($script:LockStale)s stale window expires")
            return $false
        }
        # else: renamed aside, or the dir vanished between the failed delete
        # and the rename - already gone, equally released.
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
#   then overridden by the release outcome: stolen -> 98; unreadable-token ->
#      1 if the command had succeeded (a failing command's own code is kept).
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
            if (-not $script:LockInRepo -and -not $env:AGENT_LOCK_DIR) {
                [Console]::Error.WriteLine('git-commit-lock: not inside a git repository and AGENT_LOCK_DIR is not set; refusing to guess a lock location (a CWD-scoped lock would not serialise anything). cd into the repo or set AGENT_LOCK_DIR.')
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
