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

### Implementation (`git-commit-lock.sh`, commit `873b078`)

Where each plan rule landed:
- Claim object + wire format + pre-create type guard: claim path
  `${AGENT_LOCK_PATH}.next` set at acquire start (`_LOCK_CLAIM_PATH`);
  claim created via the same noclobber write-through redirect; claim-path
  pre-create type guard inline in the steal lane with per-path two-poll
  state (`claim_nonlock_prev`) and per-path warn-once
  (`_lock_warn_nonlock_claim` / `_LOCK_NONLOCK_WARNED_CLAIM`).
- Per-attempt tokens: `_lock_new_token` (pid + RANDOM + epoch + in-process
  sequence — the sequence guarantees uniqueness within a second; sets
  `_LOCK_NEWTOK`, not printed, to avoid a subshell losing the counter).
  Fresh token before every create attempt AND every claim attempt;
  `_lock_take_hold` adopts the winning attempt token as `_LOCK_TOKEN`.
- Steal install sequence: `_lock_steal_install` (steps 2 -> 3.1 recheck ->
  3.2 non-creating touch + explicit `[ -e ]` check -> 3.3 re-verify -> 3.4
  rename-over + read-back). Re-verify helper `_lock_verify_stale`
  (states stale/gone/fresh/wrongtype; unreadable mtime or content => fresh,
  never steal what can't be proven).
- Token-checked deletion: `_lock_claim_delete` (outcomes deleted / gone /
  foreign / leaked-unreadable / leaked-blocked; ENOENT-after-passing-read is
  folded into `deleted` — rm -f masks it, and the unconditional discovery
  read that follows on every exit decides whether the claim left INTO the
  lock path; present-but-EMPTY classifies as foreign — our claim's write
  was verified by the creating redirect, so empty cannot be ours).
- Ownership discovery: `_lock_discover` (full read ladder — a verdict hangs
  on it) called as the FINAL act of every post-claim-create exit in
  `_lock_steal_install`, including the blocked-rename and rename-refused
  lanes, after the deletion attempt in each case.
- Leaked-token memory: `_LOCK_LEAKED` space-separated token string (tokens
  are whitespace/glob-free; portable vs bash-3.2 empty-array set -u traps);
  exactly three feeders (`recheck-unreadable`, `deletion-read-unreadable`,
  `deletion-unlink-blocked-while-present`); per-poll listed-token check in
  the acquire loop (adoption drops the entry, takes the hold); rides into
  the hold; release branch: leaked token at the lock => boundary re-read ->
  unlink with ours-path bounded retry + LEFTOVER warning ->
  `RELEASE-CLEANED-LEAKED-CLAIM`, verdict 98; arc-end best-effort
  resolution pass (`_lock_leaked_resolve_pass`) at release (all verdict
  paths), at the 97 exit, and in the trap handlers' no-hold path; the
  stale-claim clearing lane also resolves an own-leaked entry on a verified
  unlink (gated on one lock read).
- Trap-time cleanup: handlers installed at acquire START (saved-trap
  mechanics unchanged), restored on every no-hold return (97/timeout) and
  by release as before; `_lock_claim_trap_cleanup` does the token-checked
  deletion with ONE bounded retry + final discovery; discovery-HOLD in the
  trap releases per normal trap semantics; no 98 semantics on a mere claim.
- Claim staleness: `_lock_claim_stale_check` (mtime floor honoured; shape =
  empty or tok.-prefixed; `CLAIM-STALE-CLEARED` log) run when the claim
  O_EXCL create loses. Knob `AGENT_LOCK_CLAIM_STALE_SECS` (default 60,
  validated int). The `MAX_WAIT <= STALE + CLAIM_STALE` warning REPLACES
  the `STALE >= MAX_WAIT` warning, same left-default gate.
- Rename-over: `_lock_rename_over` — `mv -T` fast path behind a lazy
  once-per-process probe; `[ -d ]`-guarded bare-mv fallback for no-`-T`
  platforms (macOS CI leg), per the Phase-1 probe decision. Failure lanes:
  source-gone -> discovery; dest wrong-type -> `CLAIM-ABORT (rename-refused)`
  (damped); blocked -> immediate claim deletion + damped `steal FAILED`.
- Logging: `CLAIM ... tok=... by ...`, `CLAIM-ABORT (fresh|gone|wrong-type|
  rename-refused|contested)`, `STOLE-BY-CLAIM <lock> ghost=<line2> by <me>
  tok=<tok>`, `CLAIM-STALE-CLEARED <path> age=<s> tok=...`,
  `RELEASE-CLEANED-LEAKED-CLAIM <lock> tok=...`, `LEAKED-CLAIM (<lane>)`,
  `DISCOVERY-HOLD` (direct and leaked-memory variants). The damper
  (`_LOCK_STEAL_FAIL_LAST`/`_LOCK_STEAL_LOG_OK`, globals — shared with the
  install helper) covers the STALE line, the blocked lane, and the
  rename-refused lane, once per stale window as before.
- Removals: graves + naming + age-gated sweep (`_lock_sweep_litter`),
  grave-token comparison, `STEAL-DISPLACED-LIVE`, hard-link restore, the
  RESTORE-GRACE outer loop (the `_lock_cur_token` inner ladder and the
  `d40616f` schedule are KEPT), the per-acquire `_LOCK_TOKEN` assignment,
  the `STALE >= MAX_WAIT` warning. Header rewritten: protocol, claim file
  section, residuals 1-6, accepted residuals (grave bullets replaced by
  claim-deletion asymmetry + no-`mv -T` fallback), probe records A/C/D1/F
  kept + R1-R4 added + hard-link probes marked superseded.

### Implementation decisions within plan latitude (recorded, no protocol change)

- Discovery read uses the FULL read ladder (a verdict hangs on it; consistent
  with the file's only-ladder-where-verdicts-hang convention). The per-poll
  leaked-memory read is a 1-attempt short read (continuous discovery — the
  next poll retries).
- `_lock_claim_delete`'s ENOENT/vanished-mid-unlink outcomes report
  `deleted`: with `rm -f` the two are indistinguishable, and the plan's
  ENOENT lane routes to the same discovery read either way.
- The arc-end resolution pass also gates the verified-unlink drop on one
  lock-path read (the plan requires that read for gone/foreign observations;
  applying it to our own unlink too is strictly more conservative — a
  rival's rename can land in the read->unlink gap).
- The trap handlers also run the resolution pass + trap-restore on a no-hold
  EXIT/signal from inside the wait loop (the plan names release + 97; a
  trapped exit mid-wait ends the arc the same way).
- The `STALE ... -> stealing` log line moved to after the claim create wins
  (it would otherwise spam every poll while a rival's claim is in flight);
  it keeps its wire shape (`STALE (age=Ns holder=...)`) and the
  once-per-stale-window damper.
- `WAITING` line no longer carries a token (tokens are per-attempt; the
  CLAIM lines carry them, per the plan's logging design).

### Unit tests (`git-commit-lock.test.sh`)

- Plan tests landed as suite tests: 1->T20, 2->T2b (adapted; with a
  background .dead.* sampler as the no-grave-ever mutation check), 3+4->T21,
  5+13->T22 (incl. per-path warn-once independence both orders, claim-path
  symlink/FIFO legs with the suite's capability guards), 6->T23, 7->T8+T13
  extensions, 8->T24, 9->T25 (all 7 positions, deterministic steering),
  10->T26, 11->T27 (claim-token != acquired-token discriminator), 12->T28,
  14->T29 (CLAIM-line-count >= 2 as the no-ageout-penalty discriminator),
  16->T30 (static), 21->T31 (a main + b steering variant with
  order-of-lines proof + c crashed-leaver forensics + d Windows-only real
  blocked-unlink feeder & release-path arc-end pass), 22->T32, 23->T33
  (a main + b foreign-claim leg + c Windows-only blocked-unlink variant),
  24->T34, 25->T35 (a + boundary variant b). Suite T15 (grave sweep)
  deleted with a tombstone note.
- Steering mechanism: sourced shells `clone_fn`-wrap library internals
  (`_lock_verify_stale`, `_lock_claim_state`, `_lock_read_tok`,
  `_lock_cur_token`, `_lock_new_token`) or shadow `mv`/`rm`/`touch` with
  shell functions; "the rival's rename" is a real `mv` of the victim's
  claim over the lock at the exact protocol position. Gotcha fixed during
  bring-up: shadows invoked inside command substitutions run in subshells,
  so their fire-once state lives in flag FILES (`*.steer1` etc.), not
  variables (first run failed T31b/T32 exactly this way).
- Plan test 15 (no-`File.Replace` in the ps1) is Phase 3's (it pins the ps1
  5.1 lane being built there).
- Untested (noted): the 97-exit arc-end resolution pass specifically (the
  release-path pass is covered by T31d; the 97 variant shares the same
  function); the deletion-read-unreadable feeder lane (same machinery as
  recheck-unreadable, which is covered).

### Verification

- REDUCED unit suite: **210 passed, 0 failed** (read back from
  `.agent-testing/unit-reduced-run2.log`).
- FULL unit suite (`GCL_TEST_FULL=1`): **210 passed, 0 failed** (read back
  from `.agent-testing/unit-full-run1.log`).
- `shellcheck -S info git-commit-lock.sh git-commit-lock.test.sh`: clean.
- The interop and integration suites are EXPECTED to break against the new
  bash side until Phase 3 ports the ps1 half (ps1 still speaks graves); per
  the phase plan they were NOT run in this phase.

## Phase 3 — ps1 port + interop tests

### ps1 probes (2026-06-12, this box: Win11, pwsh 7.5.5 + Windows PowerShell
5.1.26100, NTFS; scripts `.agent-testing/steal-claim-probes/probe-ps1.ps1` +
`probe-ps1b.ps1`, not committed)

- **P1 (pwsh 7) overwrite-Move atomicity**: 3-arg
  `[IO.File]::Move($src,$dst,$true)` overload present; 400 rename-overs under
  a tight reader loop: **0 absent reads, 0 torn reads** when the Move
  succeeds. BUT **129/400 attempts threw** (UnauthorizedAccessException) while
  the reader held the destination open — see P6/Q4.
- **Q4 (pwsh 7) open-handle interference — NEW finding**: a single 3-arg Move
  with the destination held open by a reader granting FULL sharing
  (ReadWrite|Delete) **fails** (UnauthorizedAccessException): .NET's rename
  uses classic Windows semantics, not FILE_RENAME_POSIX_SEMANTICS (Cygwin/MSYS
  `mv` uses POSIX semantics, which is why bash probe R1 saw zero failures).
  The failure leaves BOTH files intact, so it routes into the existing
  blocked-rename lane (claim deleted, damped log, re-poll) — a transient
  deferral, not an atomicity break. Recorded as a port-specific accepted
  residual in the ps1 header; NOT a plan abort criterion (the rename is
  atomic when it succeeds, and the installed mtime is the claim's).
- **P2 mtime preservation**: installed lock mtime == the claim's
  just-touched mtime EXACTLY (tick-identical) on both lanes: pwsh 7 3-arg
  Move and the 5.1 unlink+2-arg-Move ladder. The lease rule rides on this.
- **P3 (both engines) fail-if-exists Move**: 2-arg Move onto an existing
  dest throws IOException with src AND dest intact; **exactly 1 of 6
  concurrent Moves onto one dest wins** (atomic fail-if-exists); File.Delete
  on a missing file is silent (no gone signal from the unlink — the ladder's
  gone-detection is the pre-delete existence check).
- **P4/Q1 (both engines) non-creating touch**: `SetLastWriteTimeUtc` on an
  existing claim refreshes mtime, content untouched; on a MISSING claim it
  throws **FileNotFoundException** (the inner exception — PowerShell wraps it
  in MethodInvocationException; the implementation catches by walking to the
  inner type) and does NOT create the file. The gone-detection fires.
- **P5/Q3 rename onto a DIRECTORY (both engines, both Move forms)**: throws
  (3-arg: UnauthorizedAccessException; 2-arg: IOException), directory AND
  claim intact, claim NOT moved into the directory — .NET Move has native
  `mv -T` semantics; **no extra dir guard is needed** (unlike bash's bare-mv
  fallback).
- **P6 blocked destination (no-delete-share Read handle)**: 3-arg Move AND
  File.Delete both throw with everything intact — the blocked-steal lane
  works as on the bash side (probe D1 class).
- **Q5 (both engines) 5.1-ladder robustness**: File.Delete of a file whose
  open handle GRANTS delete sharing succeeds and frees the NAME immediately
  (POSIX delete semantics on this Win11), and the freed name is immediately
  re-creatable by the 2-arg Move — the ladder is not blocked by friendly
  readers.
- **Q2 Move failure classification**: src-missing -> FileNotFoundException
  (both forms, both engines); dest-exists -> IOException (2-arg). Used by the
  ladder's lane classification.
- **File.Replace**: confirmed unnecessary — not used anywhere (plan test 15
  static check added to the interop suite).

**Abort criteria check**: rename-over IS atomic-no-absent-window when it
succeeds and the installed mtime IS the claim's fresh mtime on both engines'
lanes — no abort; proceeding with the rename-over design.

### Implementation (`git-commit-lock.ps1`)

Where each plan rule landed (ps1:line anchors at commit time):
- Claim object + wire format: `$script:LockClaimPath` set at acquire start
  (ps1:1300 area); claim created via the parameterized
  `Lock-TryCreateFile -Path -Token` (ps1:650) — the same
  write-through-creation-handle as the lock. Claim-path PRE-CREATE type
  guard inline in the steal lane with per-path two-poll state
  (`$claimNonlockPrev`) and per-path warn-once (`Lock-WarnNonLockClaim`,
  ps1:495).
- Per-attempt tokens: `Lock-NewToken` (ps1:678; pid + Get-Random + epoch +
  in-process `$script:LockSeq`); fresh token before every create attempt AND
  every claim attempt; `Lock-TakeHold` (ps1:699) adopts the winning attempt
  token as the hold token AND registers the Exiting backstop — the shared
  claim-the-hold helper for all three acquisition paths.
- Steal install sequence: `Lock-StealInstall` (ps1:971; steps 2 -> 3.1
  recheck -> 3.2 non-creating `SetLastWriteTimeUtc` touch with the
  FileNotFoundException gone signal (inner-exception walk) -> 3.3 re-verify
  -> 3.4 rename-over + read-back). Re-verify helper `Lock-VerifyStale`
  (ps1:850; stale/gone/fresh/wrongtype; empty judged by STAT per the
  ps1-on-POSIX FIFO rule; unreadable mtime/content => fresh).
- Token-checked deletion: `Lock-ClaimDelete` (ps1:813; deleted / gone /
  foreign / leaked-unreadable / leaked-blocked; File.Delete silent-on-missing
  folds the ENOENT lane into `deleted`, same reasoning as bash's rm -f;
  present-but-EMPTY classifies foreign).
- Ownership discovery: `Lock-Discover` (ps1:714; full ladder) as the final
  act of every post-claim-create exit in `Lock-StealInstall`.
- Leaked-token memory: `$script:LockLeaked` array + Lock-LeakedAdd/Member/
  Drop (ps1:726-749); per-poll listed-token check in the acquire loop
  (1-attempt short read); release branch with boundary re-read + bounded
  retry + `RELEASE-CLEANED-LEAKED-CLAIM` + verdict 'stolen'/98; arc-end
  best-effort `Lock-LeakedResolvePass` (ps1:751) at release (all verdict
  paths), the 97 exit, and the acquire cleanup's no-hold path; the
  stale-claim clearing lane resolves an own-leaked entry gated on one lock
  read (`Lock-ClaimStaleCheck`, ps1:1150).
- Trap equivalent: try/finally inside `Lock-Acquire` keyed on
  `$script:LockClaimToken` + a `$resolved` normal-return flag;
  `Lock-ClaimTrapCleanup` (ps1:1215) does the token-checked deletion with
  ONE bounded retry + final discovery; a discovery-HOLD there is released
  INLINE (token-checked lock delete + RELEASED log) because the caller's
  try/finally never sees a hold taken mid-unwind; no 98 on a mere claim.
  Cleanup paths use .NET-only primitives ([Threading.Thread]::Sleep in
  Lock-ReadTok/Lock-ClaimDelete) — cmdlets can throw
  PipelineStoppedException inside a stopping pipeline's finally.
- Claim staleness: `Lock-ClaimStaleCheck` (mtime floor honoured; shape =
  empty-by-stat or tok.-prefixed; `CLAIM-STALE-CLEARED` log) when the claim
  O_EXCL create loses. Knob `AGENT_LOCK_CLAIM_STALE_SECS` (default 60,
  validated int). The `MAX_WAIT <= STALE + CLAIM_STALE` warning REPLACES the
  `STALE >= MAX_WAIT` warning, same left-default gate.
- Rename-over: `Lock-RenameOver` (ps1:920) — once-per-process 3-arg-overload
  probe (`$script:LockMove3`); pwsh 7 = atomic overwrite Move; 5.1 = the
  unlink + fail-if-exists Move ladder with the plan's sub-lanes
  ('dest-gone' -> CLAIM-ABORT (gone) without the Move; 'blocked' -> damped
  blocked-steal lane; 'lost' -> rival won the absent window, claim deleted,
  re-poll). NO dir guard needed: .NET Move refuses a directory destination
  natively (probe P5/Q3). Verdicts: ok / src-gone / dest-gone / lost /
  wrong-type / blocked.
- Logging: byte-compatible line SHAPES with bash (CLAIM/CLAIM-ABORT(reason)/
  STOLE-BY-CLAIM/CLAIM-STALE-CLEARED/RELEASE-CLEANED-LEAKED-CLAIM/
  LEAKED-CLAIM/DISCOVERY-HOLD/STALE-> stealing (claim-serialized)/steal
  FAILED), with ASCII '-' where bash free-text uses an em-dash (the ps1 is
  ASCII-only; the greppable prefixes and key=value fields are identical).
  WAITING line drops the token (per-attempt tokens; CLAIM lines carry them).
  One ps1-only line: "steal lost the 5.1 unlink->Move window" (no bash
  counterpart lane).
- Removals: grave steal + grave-token compare + `STEAL-DISPLACED-LIVE` +
  hard-link restore + RESTORE-GRACE read-back loop + `Lock-SweepLitter` +
  the per-acquire token assignment + the `STALE >= MAX_WAIT` warning.
  Header rewritten: claim wire format, rename-over lanes, the
  non-POSIX-rename deferral residual (Q4), claim-path POSIX residual, trap
  equivalent, probe records P1-P6/Q1-Q5; hard-link probe notes superseded.

### Implementation decisions within plan latitude (ps1; recorded)

- The trap-time discovery-HOLD is released INLINE in `Lock-ClaimTrapCleanup`
  rather than via Lock-TakeHold + Lock-Release: the unwind path must not
  call cmdlets (Register-EngineEvent, Start-Sleep) and the caller's
  try/finally can never release a hold taken mid-unwind. Same observable
  semantics (claim resolved, lock released, no 98).
- `Lock-ClaimState` reads the claim with the full ladder via the same
  open-based Lock-ReadTok as bash's _lock_read_tok (consistent with the
  only-ladder-where-verdicts-hang convention); the empty-by-stat refinement
  applies to the staleness/verify lanes exactly where bash's [ -s ] does.
- The 5.1 'lost' lane (rival's create won the unlink->Move window) routes
  claim-delete -> log -> discovery -> re-poll: the plan names "token-checked
  claim deletion, re-poll"; the discovery read is the global
  unconditional-final-act rule applied to this exit too.
- The pwsh 7 blocked lane absorbs the Q4 deferral residual (any rival read
  handle on the dest fails .NET's classic rename): documented in the header
  as an accepted port-specific residual, NOT worked around with a 5.1-style
  ladder on pwsh 7 — that would reintroduce the absent window the plan says
  the pwsh 7 lane does not have.

### Interop suite (`git-commit-lock.interop.test.sh`)

- Suite Test 16 ADAPTED (plan test 19): claim-serialized mixed-impl recovery
  — every waiter rc 0 (zero spurious 98s, was "0 or a loud 98"), exactly one
  STOLE-BY-CLAIM with cross-impl ghost attribution, CLAIM tok= line shape,
  old "STOLE stale lock" shape and STEAL-DISPLACED machinery asserted ABSENT,
  background .dead.* grave sampler (mutation discriminator), no leftover
  lock/claim.
- NEW Test 16b (plan test 17): bash claimant vs ps1 claimant racing one
  ghost — both rc 0, exactly one STOLE-BY-CLAIM, balanced 2/2
  ACQUIRED/RELEASED, zero LOST, zero CLAIM-STALE-CLEARED (young claims
  respected), clean final state.
- NEW Test 16c (plan test 18): cross-impl claim staleness — bash clears an
  aged tok.ps.* claim and completes the steal; ps1 clears an aged bash-token
  claim likewise; PLUS young-claim respect in both directions (97, claim
  intact, no clear/steal).
- NEW Test 16d (plan test 15): static check — no `File.Replace` in the ps1.
- Suite Test 17 (5.1 lane) EXTENDED (plan test 20): a 5.1 waiter recovers an
  ancient ghost — rc 0, STOLE-BY-CLAIM, CLAIM tok=tok.ps.*, no leftovers;
  5.1 has no 3-arg Move overload, so this exercises the unlink+Move ladder
  by construction. Skip note extended for the POSIX legs.
- Tight-knob steal tests (T4, T5, T8a/b, T13d, T14, T14b) now set
  `AGENT_LOCK_CLAIM_STALE_SECS=60` alongside the existing knobs.
- Wire-reality sweep: all `grep STOLE` assertions still match
  (STOLE-BY-CLAIM contains STOLE); T4's `holder=` STALE-line field and
  T5/T10/T17's tok.ps.* token greps unchanged by the port.

### Integration suite (`git-commit-lock.integration.test.sh`)

- Final no-leftover sweep (3h) also asserts no `*.next` and no `*.next.*`
  leftovers beside the lock (the plan's Coordination note).

### Phase 3 verification (counts read back from the logs)

- Interop REDUCED: **130 passed, 0 failed**, exit 0
  (`.agent-testing/interop-reduced-run1.log`).
- Interop FULL (`GCL_TEST_FULL=1`): **130 passed, 0 failed**, exit 0
  (`.agent-testing/interop-full-run1.log`). The 5.1 lane RAN (engine
  5.1.26100.8115, not skipped) and the new unlink+Move steal-ladder leg
  passed.
- Integration REDUCED: **12 passed, 0 failed**, exit 0
  (`.agent-testing/integration-reduced-run1.log`) — including the new
  no-`*.next` sweep.
- Unit REDUCED (re-run to prove no interference; Phase 2 files untouched):
  **210 passed, 0 failed**, exit 0 (`.agent-testing/unit-phase3-run1.log`).
- `shellcheck -S info` clean on `git-commit-lock.interop.test.sh` +
  `git-commit-lock.integration.test.sh`; `Invoke-ScriptAnalyzer -Severity
  Warning,Error` clean on `git-commit-lock.ps1`. ps1 parse-checked on BOTH
  engines; ASCII-only verified.
- Deviations from the plan: NONE at the protocol level. One probe-driven
  port-specific accepted residual recorded (Q4: .NET's classic non-POSIX
  rename defers the pwsh-7 rename-over while any rival handle is open on the
  destination — routed through the existing damped blocked-steal lane;
  header-documented). The 5.1 'lost' lane gained a log line with no bash
  counterpart (the lane itself is plan-specified).
