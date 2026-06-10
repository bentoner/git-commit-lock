# commit-lock.ps1 — the commit-lock mutex (PowerShell port).
# Reachable at runtime as ~/.local/bin/commit-lock.ps1
# (symlinked there by this repo's install.sh).
#
# PowerShell port of commit-lock.sh, for agents whose native shell is PowerShell
# (notably Codex on Windows). It is WIRE-COMPATIBLE with commit-lock.sh: same lock
# directory, same dir-mtime staleness / rename-steal / token-release protocol, so
# a .ps1 holder and a .sh holder in the SAME working tree (e.g. Codex and Claude)
# correctly serialise against EACH OTHER. commit-lock.sh remains the authoritative
# design; docs/commit-lock.md is the "why". Keep the two in lock-step.
#
# WHY A SEPARATE PS PORT (instead of Codex calling commit-lock.sh):
#   On Windows the bare name `bash` on the plain PATH resolves to
#   C:\Windows\system32\bash.exe = the WSL launcher, whose Linux git cannot reach
#   the Windows SSH signer (the private key isn't in WSL, and SSH-agent
#   forwarding into WSL typically only fires in *interactive* shells, not an
#   agent's `bash -c`).
#   So a bash-wrapped commit under Codex runs WSL git and fails to sign
#   ("No private key found ... fatal: failed to write commit object"). Codex's
#   native shell is PowerShell, where `git` = Git-for-Windows and signs fine, so
#   running the lock + commit in PowerShell avoids bash/WSL entirely. Claude keeps
#   using commit-lock.sh (it ships its own MINGW64 Git-Bash, immune to this).
#
# USAGE (Codex's normal path — run a command string under the lock):
#   & ~/.local/bin/commit-lock.ps1 run "git add -- path/a path/b; if (`$LASTEXITCODE -eq 0) { git commit -m 'msg' }"
#   Exit code is the command's; or 2 if the lock was lost mid-hold (NOT exclusive
#   — verify with `git log` and redo). Use the `if (`$LASTEXITCODE -eq 0)` guard
#   instead of `&&` (works on Windows PowerShell 5.1 too) and avoid `exit` inside
#   the command (the lock still releases, but the exit code stops propagating).
#
# Or dot-source for the primitives (mirrors `source commit-lock.sh`):
#   . ~/.local/bin/commit-lock.ps1
#   if (-not (Lock-Acquire)) { exit 1 }
#   try { git add -- path; git commit -m 'msg' } finally { Lock-Release | Out-Null }
#
# Hold the lock ONLY for the stage+commit (sub-second). Decide what to stage,
# build any patch, resolve hook failures OUTSIDE the lock. See README.md
# ("Suggested agent instructions").
#
# CONFIG (env, mainly for tests) — identical names/semantics to commit-lock.sh:
#   AGENT_LOCK_DIR, AGENT_LOCK_STALE_SECS (default 300), AGENT_LOCK_POLL_SECS
#   (default 2), AGENT_LOCK_MAX_WAIT (default 420), AGENT_LOCK_LOG.

param(
    [Parameter(Position = 0)]
    [string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# --- resolve defaults (git-dir aware, CWD-independent within the repo) --------
# Mirrors commit-lock.sh: lock + log live in `git rev-parse --absolute-git-dir`
# (e.g. C:/repo/.git/commit.lock). Windows git prints a forward-slash drive path
# (C:/repo/.git), exactly what MINGW git prints for commit-lock.sh, so both sides
# compute the SAME lock-dir string and contend on the same NTFS directory.
function Get-LockBase {
    $gd = $null
    try {
        $gd = (& git rev-parse --absolute-git-dir 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $gd = $null }
    } catch { $gd = $null }
    if ($gd) { return ([string]$gd).Trim() }
    # Not in a repo: fall back to CWD so dot-sourcing never explodes. In real use
    # you're always in the repo whose index you're protecting.
    return (Get-Location).Path
}

$script:LockBase = Get-LockBase
if ($env:AGENT_LOCK_DIR)        { $script:LockDir = $env:AGENT_LOCK_DIR }        else { $script:LockDir = "$script:LockBase/commit.lock" }
if ($env:AGENT_LOCK_STALE_SECS) { $script:LockStale = [int]$env:AGENT_LOCK_STALE_SECS } else { $script:LockStale = 300 }
if ($env:AGENT_LOCK_POLL_SECS)  { $script:LockPoll = [double]$env:AGENT_LOCK_POLL_SECS }  else { $script:LockPoll = 2 }
if ($env:AGENT_LOCK_MAX_WAIT)   { $script:LockMaxWait = [int]$env:AGENT_LOCK_MAX_WAIT }   else { $script:LockMaxWait = 420 }
if ($env:AGENT_LOCK_LOG)        { $script:LockLog = $env:AGENT_LOCK_LOG }        else { $script:LockLog = "$script:LockBase/commit-lock.log" }

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
# token — steal detection only needs inequality, and each side reads its own.
$script:LockToken = ''
$script:LockMe = "pid=$PID host=$env:COMPUTERNAME"
$script:LockRunRc = 0

function script:Lock-Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function script:Lock-Log([string]$msg) {
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        [System.IO.File]::AppendAllText($script:LockLog, "$ts [pid=$PID] $msg`n")
    } catch { }
}

# mtime (epoch secs) of the lock dir itself — the staleness clock, same value the
# .sh side reads via `stat -c %Y`. Empty if the dir vanished mid-check.
function script:Lock-DirMtime {
    try {
        $item = Get-Item -LiteralPath $script:LockDir -Force -ErrorAction Stop
        return ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch { return $null }
}

# token currently recorded in the lock dir (whoever holds it now), or ''. Retries
# a few times: under heavy contention the read can transiently hit a Windows
# sharing violation, and returning '' there would make Lock-Release cry "stolen"
# falsely. A REAL steal renames the dir, so a successful read then returns a
# DIFFERENT token (still a mismatch) — retrying never hides a genuine theft.
function script:Lock-CurToken {
    for ($i = 0; $i -lt 5; $i++) {
        try { return ([System.IO.File]::ReadAllText("$script:LockDir/token")).Trim() }
        catch { Start-Sleep -Milliseconds 20 }
    }
    return ''
}

# Atomic create-or-fail for a DIRECTORY. PowerShell's `New-Item -ItemType
# Directory` checks existence then creates (a TOCTOU window two racers can both
# pass), and [IO.Directory]::CreateDirectory SILENTLY succeeds on an existing dir
# — neither is a mutex gate. So we create a uniquely-named temp dir and ATOMICALLY
# rename it into place: [IO.Directory]::Move throws if the destination exists, and
# the NTFS rename lets exactly one racer win (the .sh side's `mkdir` is the same
# atomic gate, contending on the same path). Returns $true iff we created it.
function script:Lock-TryCreateDir {
    $parent = Split-Path -Parent $script:LockDir
    if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }
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

function Lock-Acquire {
    $start = script:Lock-Now
    $script:LockToken = "tok.ps.$PID.$(Get-Random).$(script:Lock-Now)"

    while ($true) {
        if (script:Lock-TryCreateDir) {
            # Won the lock. Write our token (used by Lock-Release to confirm we
            # still own it) plus owner/epoch for logging. BOM-free UTF8 so the .sh
            # side reads them cleanly. All guarded: a failed write must not abort.
            # Token write is load-bearing: Lock-Release compares it to detect a
            # steal, so a silently-dropped write here would later look like a theft
            # (a false "stolen mid-hold"). Retry briefly — we just created the dir
            # and hold it exclusively, so a transient sharing hiccup clears fast.
            for ($i = 0; $i -lt 5; $i++) {
                try { [System.IO.File]::WriteAllText("$script:LockDir/token", "$script:LockToken`n"); break }
                catch { Start-Sleep -Milliseconds 20 }
            }
            try { [System.IO.File]::WriteAllText("$script:LockDir/epoch", "$(script:Lock-Now)`n") } catch { }
            try { [System.IO.File]::WriteAllText("$script:LockDir/owner", "$script:LockMe`n") } catch { }
            $script:LockHeld = $true
            script:Lock-Log "ACQUIRED ($script:LockMe tok=$script:LockToken)"
            return $true
        }

        # Lock exists. Steal it if the DIR's mtime is older than the stale window —
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

        # A live holder has it — wait, unless we have waited too long.
        if (((script:Lock-Now) - $start) -ge $script:LockMaxWait) {
            script:Lock-Log "TIMEOUT after $($script:LockMaxWait)s waiting for lock"
            [Console]::Error.WriteLine("commit-lock: timed out after $($script:LockMaxWait)s waiting for commit lock")
            return $false
        }
        Start-Sleep -Seconds $script:LockPoll
    }
}

# Release. Returns $true if we held the lock cleanly throughout; returns $false
# (and logs a loud WARNING) if our lease had been stolen before release — meaning
# the work we just did was NOT exclusive and should be treated as failed. The
# `run` path maps $false to exit code 2.
function Lock-Release {
    if (-not $script:LockHeld) { return $true }
    $script:LockHeld = $false

    # Did we keep the lock the whole time? Compare the dir's current token to ours.
    $cur = script:Lock-CurToken
    if ($cur -ne $script:LockToken) {
        # Our lease expired and the lock was stolen (possibly re-acquired by
        # someone else). Do NOT delete the dir — it may be a successor's LIVE lock.
        script:Lock-Log "WARNING: lock LOST before release (held longer than $($script:LockStale)s stale window; stolen). This commit was NOT exclusive — redo it. (ours=$script:LockToken now=$cur)"
        [Console]::Error.WriteLine("commit-lock: WARNING - lock was stolen mid-hold (held > $($script:LockStale)s). Your commit was NOT serialised; verify with 'git log' and redo under the lock.")
        return $false
    }

    # Still ours — free it. Recovery (rename-aside) triggers ONLY on a failed
    # delete: while the dir exists no one else can create it, so it is
    # unambiguously ours and the rename is safe. We must NOT re-check existence
    # after a *successful* delete — by then a successor may have re-created the dir
    # and entered its own critical section, and moving it aside would steal that
    # live lock (two holders -> lost update).
    $deleted = $false
    try { [System.IO.Directory]::Delete($script:LockDir, $true); $deleted = $true } catch { $deleted = $false }
    if (-not $deleted) {
        $grave = "$($script:LockDir).rel.$PID.$(script:Lock-Now)"
        try {
            [System.IO.Directory]::Move($script:LockDir, $grave)
            try { [System.IO.Directory]::Delete($grave, $true) } catch { }
        } catch {
            # If even the rename failed, the dir-mtime stale check is the final backstop.
        }
    }
    script:Lock-Log "RELEASED ($script:LockMe tok=$script:LockToken)"
    return $true
}

# Run a command string under the lock; always release; propagate the command's
# exit code via $script:LockRunRc — UNLESS the lock was lost mid-hold, in which
# case 2 (exclusivity failure overrides a "successful" command). The command's
# own stdout/stderr flow to the host (this function is invoked as a statement, not
# captured), so only $script:LockRunRc carries the result out.
function Invoke-WithLock {
    param([string]$CommandString)
    if (-not (Lock-Acquire)) { $script:LockRunRc = 1; return }
    $lost = $false
    try {
        $global:LASTEXITCODE = 0
        & ([scriptblock]::Create($CommandString))
    } finally {
        if (-not (Lock-Release)) { $lost = $true }
    }
    if ($lost) {
        $script:LockRunRc = 2
    } elseif ($null -ne $LASTEXITCODE) {
        $script:LockRunRc = $LASTEXITCODE
    } else {
        $script:LockRunRc = 0
    }
}

# --- CLI (only when executed directly, not when dot-sourced) ------------------
if ($MyInvocation.InvocationName -ne '.') {
    switch ($Action) {
        'run' {
            $parts = @($Rest)
            if ($parts.Count -gt 0 -and $parts[0] -eq '--') { $parts = $parts[1..($parts.Count - 1)] }
            if ($parts.Count -eq 0) {
                [Console]::Error.WriteLine('usage: commit-lock.ps1 run "<powershell command>"')
                exit 2
            }
            Invoke-WithLock -CommandString ($parts -join ' ')
            exit $script:LockRunRc
        }
        default {
            [Console]::Error.WriteLine('usage: commit-lock.ps1 run "<powershell command>"')
            [Console]::Error.WriteLine('   or: . commit-lock.ps1; Lock-Acquire; <git...>; Lock-Release')
            exit 2
        }
    }
}
