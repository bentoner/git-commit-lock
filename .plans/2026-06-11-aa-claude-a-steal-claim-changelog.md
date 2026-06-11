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

## Phase 4 — docs + README

`docs/git-commit-lock.md`:
- "How the lock works" intro: "each built around a single filesystem
  operation" reworded (the steal is now claim create + rename-over; the
  three primitives still cover everything).
- "The protocol in detail": steal bullet rewritten for claim+rename-over
  (claim file, recheck -> touch -> re-verify -> rename-over, prevention vs
  the old detect+repair); new "A claim is itself leased" paragraph (60s
  ageout, free-for-all clearing, MAX_WAIT > STALE + CLAIM_STALE relation +
  left-default warning gate); never-steal guards gain the per-path clause;
  ps1-on-POSIX exception updated (rename-over consumes the inode; claim-path
  clear lane); new "Aborted steals self-resolve" paragraph (token-checked
  deletion, unconditional discovery read, per-attempt tokens, leaked-token
  memory incl. best-effort release cleanup + 98, trap-time cleanup, the
  arc-scoped structural no-unowned-orphan claim, pointer to the headers for
  the lane inventory); version-skew deployment note; mtime-floor caveat
  extended to claims. Fixed an ambiguity my own edit created ("bound that
  claim" -> "bound that guarantee" — claim is now a protocol object).
- Port section: wire-format bullet now names the shared claim file; new
  "rename-over differs by engine" bullet (pwsh 7 3-arg Move, the 5.1
  unlink+fail-if-exists-Move ladder with the claim-guarded absent window =
  fairness loss never a clobber, the File.Replace rejection, the Q4
  classic-rename deferral residual). No hard-link notes remained in the doc
  (they were header-only).
- Knobs table: + `AGENT_LOCK_CLAIM_STALE_SECS` (60); the MAX_WAIT note now
  states the STALE + CLAIM_STALE relation and the left-default warning gate;
  the AGENT_LOCK_PATH row notes the claim lives at `<lock>.next`.
- Golden rule: the crash-recovery-under-contention paragraph rewritten —
  recovery is claim-serialized, the recovering waiter keeps the lock, the
  narrow residuals surface as the documented 98 redo; the untrappable-death
  residual stated accurately (orphaned claim normally ages out at the claim
  window; worst case via a suspended rival's rename is an unowned lock =
  bounded <= STALE stall, same class as a crashed holder's stall, no false
  success).
- Tests section: unit-suite description updated to the new coverage
  (claim-serialized T2b assertions incl. no-grave-ever, claim contention,
  claim ageout, per-path guard state, contested abort, the discovery-
  position matrix, the leaked-claim lanes, TERM-mid-claim + foreign-claim
  survival, the per-attempt-token regression, steal-hold trap parity, the
  delayed-claim fresh lease, sub-floor claim mtime, blocked-steal immediate
  claim cleanup, the non-creating-touch static check; the grave-sweep item
  removed); interop description gains claim-serialized mixed recovery, the
  cross-impl claim race + staleness tests, the no-File.Replace static
  check, and the 5.1 steal-ladder leg in the smoke lane.
- Security section checked: "small set of lock-protocol files at its own
  names beside the lock" still true of the claim — unchanged.

`README.md`: the "How it works" recovery sentences replaced with the
claim-serialization clause (one clause, no protocol dump). Grep confirmed
no other grave/restore references in the README.

Cross-checks: all internal anchors resolve against the (unchanged)
headings; no new line exceeds ~78 cols (remaining long lines are
pre-existing code/table/URL lines); the docs' numbers verified against the
code defaults (60/300/420; exit 96/97/98).

## Phase 5 — round-1 implementation review fix wave (2026-06-12)

Round-1 implementation review (fresh Claude + Codex): 3 blocking + 5
non-blocking findings, all dispositions approved. What changed:

### Blocking 1 — arc-end resolution pass dropped entries on an
INCONCLUSIVE lock read

The entry-drop in the arc-end pass was gated on `lock-line-1 != token`,
which conflated "different token / definitively absent" (conclusive:
drop is sound) with "present but unreadable/empty" (inconclusive: the
leaked token may be installed UNDER the unreadable lock — dropping
orphans it unwatched). Fix: a three-way lock read in both impls —
- bash: new `_lock_leaked_lock_resolved` (empty read + explicit
  existence check separates gone from unreadable, following the file's
  empty-read conventions); used by `_lock_leaked_resolve_pass` (both
  branches) AND by the same-gate site in `_lock_claim_stale_check`
  (same defect class, same fix).
- ps1: new `Lock-LeakedLockResolved` riding `Lock-ReadTok`'s existing
  ok/gone/unreadable status; used by `Lock-LeakedResolvePass` (both
  branches) and `Lock-ClaimStaleCheck`.
- Headers updated: the leaked-token-memory rule now states the
  conclusiveness requirement for the entry-drop lock read.
- Tests: unit **Test 36** (inconclusive-keep via an EMPTY lock — the
  same classification a sharing-violation read takes — then a later
  acquire ADOPTS the kept entry and releases rc 0; plus
  drop-on-different-token and drop-on-definitively-absent legs; kills
  the pre-fix implementation at the survive-membership check (exit 71)
  the moment the entry is dropped — the adoption leg never runs against
  it, and additionally guards the fixed behaviour end-to-end). Interop
  **Test 16e part 1** is the ps1
  mirror (keep + drop), driven by a dot-sourcing pwsh driver — the ps1
  side's unit-equivalent steering mechanism, first used here.
- Empirically demonstrated pre-commit (probe + suite): inconclusive
  read keeps the entry, the later poll adopts it, release rc 0.

### Blocking 2 — ps1 trap-time discovery-HOLD released with one blind
delete + unconditional RELEASED

`Lock-ClaimTrapCleanup`'s discovery-HOLD branch did a 1-try boundary
read, a single unguarded `File.Delete`, and then logged `RELEASED`
unconditionally — a blocked delete produced a false RELEASED and no
LEFTOVER warning (bash routes the same lane through full
`lock_release`). Fix: the inline release now mirrors the normal release
path with .NET-only primitives (the unwind constraint stands): full-
ladder boundary re-read; ours -> bounded 5x20ms delete retries, honest
`RELEASED` only when the path is actually free, else the LEFTOVER
warning (log + stderr); boundary `unreadable` -> ownership-unverifiable
warning, file left; gone/foreign -> displaced note, path left to the
successor (no 98 verdict — the unwind has no caller to return one to).
Tests: interop **Test 16e part 2** (happy path: honest RELEASED) and
**part 3** (Windows-only: a no-delete-share handle on the lock ->
LEFTOVER warning asserted present, RELEASED asserted ABSENT;
skip-with-note on POSIX where handles never block unlink). There was no
pre-existing ps1 leg pinning this lane (unit T33/T34 are bash-only).

### Blocking 3 — docs overclaimed "the recovering waiter keeps the lock"

README "How it works" and the docs golden-rule recovery paragraph now
carry the 5.1 fairness-loss caveat the port section already described
(unlink-then-move window; a rival create can win the recovered path;
the claimant backs off cleanly — never a clobber). README clause kept
lighter than the doc's, per the disposition.

### Non-blocking

4. **T29 timing headroom**: `MAX_WAIT` 3 -> 6 (POLL stays 0.2). The
   >=2-CLAIM-lines discriminator had zero margin under load (flaked in
   review runs). Discriminator verified intact: a leftover-claim
   implementation still logs exactly ONE claim line (the leftover
   blocks every later attempt regardless of window length) and fails
   the `-ge 2` assertion.
5. **T33a double-TERM flake**: single TERM now (the second TERM could
   re-enter the handler mid-deletion and abandon cleanup — on-disk
   outcome documented-best-effort, but it flaked the no-leftover
   discriminator). Chose single-TERM over accept-either-outcome to keep
   the discriminator sharp. Applied to **T34** too (same hazard on its
   released-on-TERM discriminator: a re-entrant handler can abandon
   lock_release's unlink). T33b/T33c keep their double TERM — their
   assertions (foreign claim survives / claim left behind) are
   insensitive to re-entry.
6. **ps1 touch-gone leg**: interop **Test 16f** (Windows,
   skip-with-note elsewhere) steers claim-gone-at-touch for a ps1
   claimant via the dot-source driver (the overage probe between the
   step-3.1 recheck and the step-3.2 touch deletes the claim): asserts
   the FileNotFound gone signal fires ("claim gone at touch" logged),
   the rename's src-gone fallback did NOT have to catch it, no
   resurrection, ghost untouched, no hold. Note: the lane's log line is
   "claim gone at touch ...; discovery read" (per the spec/bash
   parity), not a CLAIM-ABORT enum line — the finding's "CLAIM-ABORT
   logged" wording was loose; asserted the real line.
7. **ENOSPC mid-create residual**: one header line in BOTH impls next
   to the mid-create-signal micro-exception (bash trap-time rule
   paragraph; ps1 trap-equivalent bullet): a create failing after line
   1 reached disk leaves an own-token claim the process doesn't know it
   wrote — same bounded residual-5 class.

### Verification (this wave; counts read back from the logs)

- Unit FULL (`GCL_TEST_FULL=1`): **213 passed, 0 failed**, exit 0
  (`.agent-testing/unit-full-fixwave1.log`; 210 before + Test 36's 3).
- Interop REDUCED: **141 passed, 0 failed**, exit 0
  (`.agent-testing/interop-reduced-fixwave1.log`; 130 before + 16e's 7
  incl. the Windows blocked-release leg + 16f's 4 — all RAN, none
  skipped, on this Windows box).
- `shellcheck -S info` clean on git-commit-lock.sh + both suites;
  `Invoke-ScriptAnalyzer -Severity Warning,Error` clean on the ps1;
  ps1 parse-checked on pwsh 7 AND 5.1; ASCII-only re-verified.
- Integration suite NOT run: nothing it exercises changed (the fixes
  are anomaly-lane semantics, tests, headers and docs; the protocol's
  happy paths are untouched).

## Fix wave 2 (2026-06-12) — recovery-test backdate-harness race + cosmetics

### Item 1 — the multi-waiter recovery tests' backdate raced the protocol

A loaded-box run (preserved `cl-interop-42280df2`) failed T16/T16b-class
assertions with the protocol behaving exactly as designed. Race walk:
the harness plants a FRESH ghost, waits for every waiter's WAITING line,
then backdates. Under load (a) the sync can stall past STALE, so the
ghost ages stale NATURALLY and a fast waiter steals it BEFORE the touch
(observed: pwsh waiter judged the fresh ghost at age=3s == STALE
boundary), and (b) the backdate's touch then lands on the WINNER'S
freshly installed lock, ageing it to 10000s — a rival legitimately
re-steals it and the displaced winner exits 98 ("zero 98s / exactly one
STOLE-BY-CLAIM" fail, no protocol fault).

Harness shape chosen (same for unit T2b and interop T16 — and T16b,
which shares the pattern and the race; the WAITING-sync shape was KEPT
because launching against a pre-aged ghost loses the contention: the
first arrival steals before slow-cold-start waiters even poll, so they
contend on a LIVE lock instead of the stale one):

- **`sync_waiting_fresh`** — the WAITING sync now keeps the ghost FRESH
  (`touch -c` to now each 0.2s poll) so it cannot age stale mid-sync;
  freshening is race-safe (a live winner lock is already fresh; `-c`
  never resurrects a released path).
- **`backdate_ghost`** — token-guarded backdate: pre-read must be the
  ghost (else no touch — premise already gone); ghost post-read is
  conclusive-valid; non-ghost post-read is arbitrated by MTIME (a
  winner's installed lock is fresh => the touch hit the ghost — valid;
  ancient => the touch hit the winner's live lock — invalid; vanished
  => non-conclusive).
- **Outcome-based acceptance with bounded retries (x3/round)**: a
  non-conclusive backdate accepts a CLEAN outcome (harness damage always
  manifests as 98s / "lock LOST" / steals != 1 / leftovers) and discards
  + retries a dirty one as unattributable. Two intermediate designs were
  measured insufficient before this: strict post-check discarded VALID
  rounds constantly (waiters poll at 0.05s; the post-read costs
  subprocess spawns — interop T16b failed 3/3 attempts under load with
  the steal at age=9999s, i.e. the touch HAD hit the ghost), and mtime
  arbitration alone still failed when the whole steal+release cycle
  completed before the post-read (path vanished, nothing to arbitrate).
- Interop T16/T16b STALE 3 -> 8 (margin against natural ageing; nothing
  in the tests depends on the smaller window).
- A real protocol displacement bug cannot hide behind the retry: it
  dirties every attempt, exhausts the 3 tries, and fails loudly
  ("no clean round under a conclusive backdate"), logs preserved.

Stability evidence (REDUCED, this Windows box, counts read back):
- Unit suite x7 (1 foreground, 1 final foreground, 5 under concurrent
  load incl. a 2-unit+2-interop round): T2b green in 7/7; full suite
  213/0 in both foreground runs.
- Interop suite x8: run 1 went 141/0 with the guard FIRING live on
  T16 try 1 (discard + clean retry); after the final outcome-based
  design, 6/6 consecutive 141/0 (5 under concurrent load).
- Known artifact, documented at unit 12d: a suite launched as a
  BACKGROUND job from a non-job-control shell inherits SIGINT-ignored,
  which bash reports as `trap -- '' SIGINT` and 12d's leftover-trap
  regex flags (false failure; foreground runs green). Comment added at
  12d.

### Items 2–5 (confirmation-review cosmetics)

2. `lock_release` displaced-by-own-leak lane (both impls): kept the
   unconditional `_lock_leaked_drop`/`Lock-LeakedDrop` and added the
   justifying comment (divergence from the resolve-pass's
   inconclusive-keep is sound here: the boundary re-read ran the FULL
   8-try ladder immediately after the same arc read the leaked token
   OK, so empty-but-present means the leak file was destroyed, not a
   read flake). Chosen over routing through
   `_lock_leaked_lock_resolved` to avoid a redundant extra lock read
   and a subtle LEFTOVER-lane behaviour change.
3. The Phase-5 Test-36 kill-mechanism sentence corrected in place (the
   pre-fix impl dies at the survive-membership check, exit 71 — not via
   the adoption-leg timeout).
4. ps1 `Lock-ClaimTrapCleanup` unverifiable/displaced lanes now write
   stderr too (parity with bash + the ps1 normal release); the
   displaced lane's stderr is a note, not a "commit was NOT serialised"
   warning — no command ran under a discovery-HOLD. (The Blocking-2
   paragraph above predates this; its "log only" description of those
   two lanes is superseded.)
5. README: re-wrapped the over-long merged line at "exit 98. The lock
   is advisory…" to the file's ~78-col style.

### Verification (this wave)

- Unit REDUCED foreground: **213 passed, 0 failed**, exit 0 (x2).
- Interop REDUCED: **141 passed, 0 failed**, exit 0 (x6 on the final
  design, 5 under load).
- `shellcheck -S info` clean on both suites + git-commit-lock.sh;
  `Invoke-ScriptAnalyzer -Severity Warning,Error` clean on the ps1.
- Preserved failure dirs (`cl-interop-42280df2` and this wave's two)
  deleted after extraction.

## Close-out (2026-06-12, final wave)

All phases complete: 1 (bash probes), 2 (bash implementation + unit
tests), 3 (ps1 port + interop/integration adaptations), 4 (docs/README),
plus the round-1 implementation-review fix wave (Phase 5), fix wave 2
(backdate-harness race), and the CI/harness wave. Plan Status set to
IMPLEMENTED (v7 as converged).

Review history: plan review ran 7 rounds to convergence (round-7 Codex
confirmation clean; round-6 Claude confirmation clean given the v7
folds); implementation review ran 2 rounds (round 1: 3 blocking + 5
non-blocking, all fixed in Phase 5; round 2: confirmation-review
cosmetics, folded into fix wave 2) plus the harness fix wave for the
recovery-test backdate race.

Final wave also adopted shfmt (style `-i 2 -ci -bn`, declared in
`.editorconfig`; mechanical-formatting commit `8c959bc`, listed in
`.git-blame-ignore-revs`; `shfmt -d` gate added to the CI lint job,
binary sha256-pinned at v3.13.1). All suites re-run green AFTER the
formatting:

- Unit REDUCED: **213 passed, 0 failed**, exit 0
  (`.agent-testing/unit-shfmt-run1.log`).
- Interop REDUCED: **141 passed, 0 failed**, exit 0
  (`.agent-testing/interop-shfmt-run1.log`).
- Integration REDUCED: **12 passed, 0 failed**, exit 0
  (`.agent-testing/integration-shfmt-run1.log`).
- Integration FULL (`GCL_TEST_FULL=1`): **13 passed, 0 failed**, exit 0
  (`.agent-testing/integration-full-run1.log`) — the last suite not yet
  FULL-run since the harness fix; FULL adds one leg over REDUCED's 12.
- `bash -n` + `shellcheck -S info` clean on all five shell files
  post-format.

Earlier FULL runs on this implementation: unit FULL 213/0 (fix wave 1);
interop FULL 130/0 at Phase 3 (pre-fix-wave — the later 141 count adds
the fix-wave tests, which all RUN in REDUCED mode on this box; for the
interop suite the FULL knob widens fan-out only, it adds no tests:
Phase 3 measured REDUCED and FULL at the same 130). CI runs all three
suites FULL on the 3-OS matrix.
