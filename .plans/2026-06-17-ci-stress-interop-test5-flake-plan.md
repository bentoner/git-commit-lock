# Plan: de-flake interop Test 5 (genuine-pwsh-orphan steal) under load

Status: **DONE** — diagnosis + fix D validated by Claude subagent + Codex; implemented;
implementation reviewed clean by fresh Claude reviewer ("IMPLEMENTATION OK") + Codex ("no
correctness issues"); local interop suite 141/0 with a genuine `tok.ps.*` token. Awaiting
CI-under-load confirmation.

## Reviewer notes (top; do not renumber)
_(none yet)_

## Context
CI stress under CPU load (load=4, 4-core Windows runner) reproducibly fails the **interop
suite Test 5** ("bash steals a STALE lock GENUINELY created by pwsh (holder killed
mid-hold)"), `tests/git-commit-lock.interop.test.sh:308-334`:
```
FAIL: expected a tok.ps.* token on line 1 of the orphan lock, got ''
PASS: bash run exited 0 after stealing pwsh's stale lock   (+2 more PASS)
```
Diagnosis (Claude subagent) + independent Codex review — both in
`.agent-testing/failures/interop-test5/{DIAGNOSIS.md,b5.log}` and
`.agent-testing/codex-t5-diag-review.txt`. Agreed mechanism (high confidence,
triple-corroborated by b5.log):

- The holder is `pwsh ... Lock-Acquire; write READY; Start-Sleep 60 &`, with `hpid=$!`.
  bash waits READY then `kill -9 "$hpid"`. **That kill does not terminate the native
  pwsh** (MSYS `$!` names a shim, not `pwsh.exe`; under load it misses). Proof: b5.log
  shows ACQUIRED 13:42:45 → RELEASED 13:43:45 = **exactly 60s = the full Start-Sleep**,
  and the release reason is **`engine-event backstop at process exit`** which fires ONLY
  on graceful exit (`git-commit-lock.ps1:1299-1322`), never on a hard kill.
- That graceful-exit backstop **deletes the lock file** (`git-commit-lock.ps1:1319-1321`)
  before bash reads it, so `head -n 1 "$LOCK"` (:320) returns `''` — a **gone file**, not
  a slow-to-appear token. `backdate "$LOCK" 9999` (:325 = `touch`, no `-c`, :107-115)
  then **re-creates it empty+ancient**, and bash steals THAT empty orphan (`ghost=?`,
  b5.log). So the 3 downstream PASSes are **vacuous** (they steal an empty file, not a
  genuine `tok.ps.*` orphan); the only assertion checking the real premise correctly FAILed.
- **Classification: test bug, product correct.** Every product action in b5.log is right.
- **Why load:** unloaded, the kill lands by timing luck before the sleep ends; under load
  the kill misses and the holder self-releases.

Scope: this kill-a-holder-then-read-its-orphan pattern is unique to Test 5. The other
interop kill (`:787`, `w14b`) is cleanup of a *hung waiter* after a regression `bad` — no
orphan read depends on it — so it is NOT affected.

## Fix (Option D — make the orphan deterministic; remove the unreliable kill)
Both reviewers recommend D over hardening the kill (B/C): it eliminates the flaky
mechanism instead of making it reliable, and is the smaller, more deterministic change.

Have the pwsh holder **acquire, signal READY, then self-exit via
`[Environment]::Exit(0)`** — the product's *documented* hard-exit that bypasses BOTH
`Lock-Release` and the `PowerShell.Exiting` backstop (`git-commit-lock.ps1:221-224`,
`:1299-1301`), so it leaves a genuine token'd orphan every time, with no external kill and
no timing dependence. `Lock-Acquire` writes+flushes+closes the token before returning
(`git-commit-lock.ps1:650-664`) and READY is written only after acquire, so the moment
bash sees READY the `tok.ps.*` token is already durably on disk.

Concretely in `tests/git-commit-lock.interop.test.sh` Test 5:
1. Holder command (`:314-315`): replace
   `. '$PS1WIN'; Lock-Acquire | Out-Null; [IO.File]::WriteAllText('$READY','r'); Start-Sleep 60`
   with
   `. '$PS1WIN'; if (-not (Lock-Acquire)) { [Environment]::Exit(3) }; [IO.File]::WriteAllText('$READY','r'); [Environment]::Exit(0)`
   (`Lock-Acquire` returns `$false` on failure, `git-commit-lock.ps1:1350`; guard it so a
   failed acquire never writes READY → the existing else-branch "never readied" fires.)
2. Success branch (`:317-324`): drop the unreliable `kill -9 "$hpid"; wait "$hpid"; sleep
   0.3` and replace with just `wait "$hpid" 2>/dev/null` (reap the self-exited holder).
   Keep the token read + `case tok.ps.*` assertion + `backdate` + the steal asserts
   unchanged — but now the orphan deterministically carries the genuine pwsh token, so the
   `tok.ps.*` assertion (and the downstream steal) are no longer vacuous.
3. Comment (`:309-311`): rewrite to describe the new mechanism honestly — the holder
   acquires, signals ready, then exits via `[Environment]::Exit(0)`, a CLR hard-exit that
   bypasses release (no `PowerShell.Exiting` event), leaving a genuine no-release token'd
   orphan; deterministically equivalent (same on-disk state) to a holder killed mid-hold,
   without depending on a scheduler-raced external kill.
4. else branch (`:331-333`): keep its `kill -9 "$hpid"` cleanup (harmless; the holder may
   still be starting if it never readied).

### Why D is faithful (not a weakening)
Test 5 verifies **bash stealing a genuine stale pwsh-created lock cross-impl**. What
matters is the on-disk state at steal time: a live lock file whose line 1 is a real
`tok.ps.*` token, with the holder gone and no release performed. D produces exactly that
state deterministically. The literal "killed by external TerminateProcess" flavor is only
test *setup*, not the product behavior under test; D's CLR hard-exit leaves the identical
artifact. The fix makes the long-vacuous downstream PASSes actually meaningful.

## Also
- Correct the `AGENTS.md` Test 5 progress-log note (it currently states the wrong
  mechanism — "token not-yet-visible under load"); replace with the missed-kill /
  graceful-release-deleted-the-file mechanism.

## Out of scope / NOT changed
- Product code (`git-commit-lock.ps1` / `.sh`) — no product defect.
- The bash-worker kills in the unit suite (they kill native bash where `$!` is correct and
  no orphan-read depends on them; they passed under load).
- Other interop tests.

## Testing
1. Static: `bash -n` + `shellcheck -S style` (v0.11.0, the CI gate) on the interop test.
2. Local: run the interop suite once on this box (pwsh present) — Test 5 must pass and the
   token assertion must see a real `tok.ps.*` token. (Unloaded local box can't reproduce
   the original miss, but confirms the rewrite is correct.)
3. Real proof = CI under load: dispatch ci-stress with stress_kind=cpu/both several times;
   the interop leg must stay green where it previously failed deterministically.

## Changelog (implementation)
- Implemented Fix D in `tests/git-commit-lock.interop.test.sh` Test 5: holder command now
  `if (-not (Lock-Acquire)) { [Environment]::Exit(3) }; write READY; [Environment]::Exit(0)`
  (was `Lock-Acquire | Out-Null; write READY; Start-Sleep 60`); success branch drops
  `kill -9 "$hpid"; sleep 0.3`, keeps `wait "$hpid"` to reap; ok-message + comment updated.
  No product code, no other test touched. `Lock-Acquire` returns a strict boolean
  (git-commit-lock.ps1:1350 etc.) so the `-not` guard is valid; the token is flushed+closed
  during acquire (before READY) so it is durably visible before `[Environment]::Exit`.
- Static: `bash -n` + `shellcheck -S style` (v0.11.0) clean.
- Local (Windows, pwsh 7.5.5): interop suite **141 passed / 0 failed**; Test 5 token
  assertion now PASSes with a real `tok.ps.*` token (e.g. `tok.ps.76676.…`) — no longer the
  vacuous empty-orphan steal.
- Review: fresh Claude reviewer "IMPLEMENTATION OK" (verified Lock-Acquire boolean contract,
  no pipeline pollution from dropping Out-Null, token durability, race-free `wait`, quoting);
  Codex `exec review --uncommitted` "no correctness issues." Both in `.agent-testing/`.
- AGENTS.md Test 5 progress note corrected (was the wrong "token not-yet-visible" mechanism).
- Real proof pending: CI interop leg under CPU load where it previously failed 3/3.
