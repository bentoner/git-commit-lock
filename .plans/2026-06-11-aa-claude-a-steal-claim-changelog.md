# Changelog: steal-claim protocol implementation (Phases 1–2)

Plan: `.plans/2026-06-11-aa-claude-a-steal-claim-protocol-plan.md` (CONVERGED v7).
This file records probe results, implementation notes, and any deviations.

## Phase 1 — probes (2026-06-11, this box: Windows 11, Git Bash/MSYS, NTFS)

Probe script: `.agent-testing/steal-claim-probes/probe.sh` (not committed).

1. **MSYS `mv` rename-over atomicity (NTFS)**: tight reader loop across 400
   rename-overs (200 rounds x 2 flips ghost<->ours): **absent-reads=0,
   torn-reads=0**. The lock path never read absent and content flipped
   atomically. PASS — no-absent-window confirmed.
2. **Post-rename mtime**: claim backdated, then `touch -c`'d fresh, then
   `mv`'d over a backdated destination: installed lock mtime == the claim's
   just-touched mtime exactly (claim mtime=1781183430, installed lock
   mtime=1781183430, now-delta=1s). Rename preserves the SOURCE's mtime; the
   destination's old mtime does not survive. PASS — the lease rule rides on
   this. Re-confirmed identically for `mv -T` (see probe 5).
3. **`touch -c` semantics** (re-confirm of round 3): on a MISSING file,
   exit code **0** and the file is **NOT created** — the exit code carries no
   gone signal; only an explicit `[ -e ]` check detects gone. On an existing
   file: mtime visibly refreshed (1577797200 -> 1781183431), content
   untouched. PASS.
4. **Rename onto a directory** — bare `mv` does NOT fail: GNU/POSIX mv
   rewrites a directory destination to `dir/basename` and **moves the claim
   INTO the directory** (dir intact, claim relocated inside it as litter).
   The plan's assumption "rename onto a directory fails" is FALSE for bare
   `mv`.
5. **`mv -T` (GNU --no-target-directory)**: refuses BOTH a non-empty dir
   ("cannot overwrite directory ... with non-directory", rc=1, dir + claim
   intact) and an EMPTY dir (same refusal). `mv -T` over a plain file
   rename-overs normally and preserves the source mtime. PASS — `mv -T` is
   the correct rename-over primitive where available.

**Abort criteria check**: rename-over IS reliably atomic-no-absent-window on
NTFS from bash, and the installed lock's mtime IS the claim's fresh mtime —
no abort; proceeding with the rename-over design.

**Probe-driven implementation decision (recorded, not a protocol change)**:
`-T` is GNU-only; the CI matrix includes macos-15 (BSD mv has no `-T`, and
BSD mv onto a dir also moves-into). The implementation probes `-T` support
once per process (lazily, at the first rename-over need, via a temp-dir
micro-rename) and:
- `-T` supported (Linux/MSYS/Cygwin): rename-over is `mv -T --`; a directory
  destination fails cleanly into the rename-refused lane.
- `-T` unsupported (macOS/BSD): rename-over is `[ ! -d ]`-guarded bare
  `mv --`. Residual (accepted, documented in the header): a directory
  appearing at the lock path inside the check->mv microsecond gap would have
  the claim moved INTO it; the acquire read-back fails (path is a dir), the
  claimant re-polls, and the wrong-type guard classifies the dir on the next
  polls — no false success; the claim file becomes litter inside the
  misconfigured directory. Reaching this requires external interference
  creating a directory at the lock path inside a ms window.

(ps1 probes — pwsh 7 overwrite-Move, 5.1 File.Move, SetLastWriteTimeUtc —
are Phase 3's job; skipped here per the phase split.)

## Phase 2 — bash implementation + unit tests

(running notes below)

- Verification note: the interop and integration suites are EXPECTED to
  break against the new bash side until Phase 3 ports the ps1 half (ps1
  still speaks graves); per the phase plan they were NOT run in this phase.
