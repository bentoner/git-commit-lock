> **IMPLEMENTED 2026-06-11** on branch `worktree-lockfile-protocol` — all four
> phases; record in `.plans/2026-06-10-main-lockfile-changelog.md`. Local
> verification ran the three suites in REDUCED fan-out (green); Phase 3's
> full-strength 3-OS gate is CI's, on push of this branch (the PR must show
> the macOS interop leg green before merge — it closes TODO 59).

## Review round 4 of the convergence loop, 2026-06-11 — CONVERGED

> **Codex: clean — no findings at any severity.** Claude: concur with GO, no
> design defects; five non-blocking precision items, all folded same day:
> interop tests (a)/(b) gated to Windows (on POSIX unlink/rename never block
> on open handles — ungated they'd redden the ubuntu/macos legs);
> ps1-on-Unix device/socket residual documented beside the FIFO one (bash
> refuses via `-f`; grave-delete caps damage at the misconfigured inode);
> per-poll guard's "exists" pinned to `-e || -L` (dangling symlink must warn,
> not read as contention); the release-retry gap added to the residual-races
> inventory (handle can close between retries; detected ⇒ 98); the
> actively-rewritten-user-file diagnostics gap documented as the accepted
> flip side of age-gating the content guard. **Loop closed: zero findings
> from one reviewer, zero design defects from the other, severity trending
> MAJOR→pins→precision across rounds 2–4 — further rounds would be
> manufacturing findings, not converging.** Ben decides GO/NO-GO; on GO,
> implementation runs as a branch + PR per the new GitHub workflow, after CI
> is green (Sequencing).

## Review round 3 of the convergence loop, 2026-06-11 (fresh Claude + Codex)

> **Status: all findings folded same day.** Claude: concur with GO; one MAJOR
> survived five passes — the ps1 steal guard passes a Unix FIFO (neither
> container nor reparse point) and the content read would block in open(2):
> fixed by pinning ps1's "empty" test to stat (`Length -eq 0`, no open; read
> only when size > 0), residual (FIFO renamed as empty orphan) documented,
> .NET-on-Unix blocking claim flagged for one-line verification on CI's
> ubuntu leg. Plus five pins, all taken: owner-read moved BEFORE the final
> mtime re-read (matching today; the literal order widened the re-read's
> window), acquire's ENOSPC lane cross-references the torn-write lane, EMPTY
> ORPHAN vs NON-LOCK rows disjoint (`tok.`-prefixed partials steal; shorter
> torn writes don't), per-poll guard warns on exists-but-wrong-type only,
> release-retry rationale re-grounded on D1. Codex: clean except one MINOR,
> taken — Phase 2 now names the `PowerShell.Exiting` backstop port.

## Review round 2 of the convergence loop, 2026-06-11 (fresh Claude + Codex)

> **Status: all findings folded same day.** Both verdicts: concur with GO, no
> blocking findings. Claude (6, all seam fixes): steal type guard now runs on
> every blocked poll so an mtime-refreshing non-lock path (e.g. `$HOME`)
> still gets its config warning instead of a silent 97; the release boundary
> re-read is pinned to step-2 classification in both impls (empty-at-boundary
> ⇒ unverifiable, never delete — today's ps1 would have deleted); Logging
> gains the acquire-verification-failure and unreadable-steal-skip lines;
> HELD-crash row corrected (token-bearing ⇒ stale, not EMPTY ORPHAN); Phase 2
> test (a)'s rc-1 disambiguated (sourced return, not `run` exit); "58
> landed" reworded (item added, knob ports with the suites). Codex (2 MINOR
> + 1 NIT): the prefix-guard's converse residual is now documented (a stale
> user file whose line 1 starts `tok.` is still stolen — accepted); ps1
> acquire explicitly keeps parent-directory creation; same "58 landed"
> rewording.

## Review round 1 of the convergence loop, 2026-06-11 (fresh Claude + Codex)

> **Status: all findings folded same day (commit follows 39f71c2).** Claude:
> 10 non-blocking spec amendments — ps1 catch-all open exception (dir throws
> `UnauthorizedAccessException`, verified), unreadable-steal lane pinned
> (skip + re-poll), torn-`tok.`-prefix residual accepted + documented, unit
> T16 / interop T11 semantics flips named explicitly (+ cross-impl gone⇒98
> assertion), dead "our own 10×-failed write" clause deleted (acquire
> verification grounds gone⇒98), TODO 58 folded into phases/table (Phase 3's
> 3×3 is the explicit `GCL_TEST_FULL=1` canary), touch-d claim updated to
> landed reality, sweep keeps its age gate (pinned), ABSENT-row verify step,
> per-impl ladder wording. Codex: 3 findings — its blocker (bash noclobber
> doesn't gate non-regular paths; a FIFO at the lock path would block open(2)
> before any timeout) is fixed by a mandatory bash pre-create type guard;
> ps1-side guard tests added to Phase 2 (item c); TODO 58 as above. Verdicts:
> Claude "concur with GO — no blocking findings"; Codex "with finding 1
> fixed, GO is otherwise honestly stated".

## Review findings 2026-06-11 (Codex lockfile follow-up)

> **Status: verified and folded into the plan body 2026-06-11.** Finding 1
> confirmed real (and worse than stated: the resumed holder's release finds
> its own rewritten token, so the double-hold is *silent*) — the Acquire spec
> now writes through the ps1 creation handle, verifies via a path read-back
> in both impls, and NEVER repairs by overwriting: a failed verification is
> treated as not-acquired and re-enters the wait loop. Finding 2 confirmed
> via probe D1 — the leftover lanes (Release step 3, state table, Phase 2
> test a) now state recovery requires the stale window AND the blocking
> handle closing. Finding 3: no action needed, as it says.

Reviewed against HEAD `cc86065`, with special attention to Codex's earlier
objection that file locks can be worse on POSIX because unlinking an open file
removes the path under the holder.

1. **[MAJOR — fix before implementation] The acquire read-back rewrite can
   corrupt a successor after a stale-window pause.** The proposed Acquire step
   says that after winning O_EXCL/CreateNew, the holder should read line 1 and,
   if it does not match, "rewrite (plain overwrite, we own the file)" (below,
   Acquire bullet 3). That ownership claim is true only until the stale window.
   If the acquirer is suspended after create/open but before verification for
   longer than `AGENT_LOCK_STALE_SECS`, a waiter may legitimately rename the
   stale file aside and create a successor lock at the same path. When the
   original process resumes, a plain overwrite can replace the successor's
   token, then let the original process enter the critical section with a
   corrupted lock. Disposition: do not ever fix a failed read-back by blindly
   overwriting the path. Write the token through the creation handle where the
   runtime supports it; after the retry ladder, a missing/empty/foreign token at
   acquire verification must be treated as an acquisition failure/unverifiable
   lock-layer error and the wrapped command must not run. Cleanup, if any,
   should only remove the same object via a guarded same-handle operation or
   leave the file for stale recovery.
2. **[MINOR] The leftover/recovery wording overstates what the stale window can
   recover while a Windows no-delete-share handle is still open.** The plan
   correctly specifies blocked-release and blocked-steal tests, but the Release
   section and state table still say the stale window "reclaims" a leftover
   file. Probe D1 says the handle that blocks unlink also blocks rename, so a
   waiter can reclaim only after the stale window **and** after the blocking
   handle closes; otherwise it should keep polling until `AGENT_LOCK_MAX_WAIT`.
   Reword those lanes so the recovery condition is precise.
3. **[NOTE] Codex's earlier POSIX unlink/open-file objection is not a blocker
   for this plan.** The objection applies to fd-based locks (`flock`-style
   ownership), where the holder owns an open descriptor and the pathname can be
   removed underneath it. This plan's protocol is path+token ownership: both
   implementations close the creation handle before the critical section, and a
   displaced holder detects gone/foreign token at release and exits 98. POSIX
   unlink/rename of the path is therefore the same displacement case the dir
   protocol already handles, not a file-protocol differentiator.

---

## Review findings 2026-06-10 (post-wave consistency pass)

> **Status: folded into the plan body 2026-06-11** — the STALE≥MAX_WAIT
> advisory is now cited in its landed gated form (note 1); the TODO impact
> table is prefaced with the live-item re-key and Phase 4 edits only live
> items (note 2); the Implementation phases now open with the land-CI-first
> sequencing rule and Phase 2 carries the portable-backdating hand-off
> (note 3).

Fresh-context consistency check against HEAD (e67f788) — specifically the two
commits that landed AFTER this plan's review was folded in (840a4fd
cross-impl reconciliation, e67f788 TODO trim) and against the CI plan. **No
blocking findings; the GO recommendation and protocol are unaffected.**

1. **NOTE — 840a4fd strengthens rather than contradicts this plan.** The bash
   release now has the rc-2 unverifiable lane in the *dir* era ("token
   unreadable, dir present" → 2, verified at git-commit-lock.sh:430), so this
   plan's Release step 2 pinning ("bash rc 2 / ps1 'unreadable'") now mirrors
   landed behaviour in both impls instead of introducing a new bash lane.
   One adjacent fact drifted: the STALE≥MAX_WAIT advisory listed under
   "Unchanged" is now *gated* (fires only when MAX_WAIT was left at default) —
   carry the gated form over; no design impact. Problem statement re-verified
   accurate at HEAD: mkdir+token-after, `Lock-TryCreateDir`/`.new.*`/
   `SetLastWriteTimeUtc`, rename-aside release in both impls, litter sweep,
   floor 946684800, read-retry ladders — all still present as described.
2. **NOTE — the TODO impact table is keyed to item numbers e67f788 deleted.**
   Only 11, 39, 48, 53–56 survive in TODO-main.md; the rest were fixed in the
   wave and removed. The table's *substance* is still right (it names
   behaviours/tests the port must preserve), but Phase 4's "update the
   TODO-main.md items per the table" now mostly points at nonexistent entries.
   Re-key to the live items: 11 (TODO already notes this plan subsumes it),
   39 (claimed by the CI plan "before or with the workflow commit" — likely
   already done before this plan starts; drop it from the mechanical-port
   row), 48 (re-run linters — fine), 53–56 (fold-in row — fine).
3. **NOTE — sequencing vs the CI plan
   (.plans/2026-06-10-main-github-actions-ci-plan.md, implementing 2026-06-11);
   neither plan references the other.** No contradiction — the workflow only
   invokes the three suites + linters, so it needs no edits for this change —
   but the recommended order is **CI first**: this plan's probes are
   Windows-only and its POSIX/macOS claims are reasoned-not-probed, so running
   Phases 1–3 under the 3-OS matrix is exactly the missing verification;
   landing the port before CI would also silently invalidate the CI plan's
   dir-era measurements. One concrete hand-off: Phase 2's re-fabrication of
   interop T4/T5 must use the unit suite's portable `epoch_to_stamp`/`touch -t`
   pattern, not the GNU-only `touch -d "@epoch"` those lines carry today
   (interop 160/184) — by then CI's macOS leg will be live and `touch -d`
   re-breaks it. Add one sequencing sentence to the plan.

---

## Review findings (2026-06-10 fresh-context review)

> **Status: all six findings folded into the plan body (same day), per their
> recommended dispositions** — steal guard now rejects symlinks and
> non-lock-shaped content (1, 2; line 1's `tok.` prefix is now wire format),
> empty-at-release pinned to the unverifiable lane in both impls (3), TODO
> 53–56 added to the impact table + Logging (4), read-only-attribute caveat
> recorded beside the deleted rename-aside (5), NFS claim reworded (6).
> Findings kept below for the record. TODO #57 (docs wording) fixed directly.

Reviewed against the code, all three suites, TODO-main.md, and the probes.
Probes re-run for this review: **B** (cross-runtime create race: 0 bad rounds
of 4, exactly one winner each, content matches), **F** (empty-read window:
442 empty reads against ~722k non-empty — real, retries needed), **D** (full
re-run: D1 share=Read blocks mv/rm/Delete/Move alike; D2 delete-share blocks
nothing; D3 Cygwin fds never block; D4 0/200), **C1b** (40/4449 sub-floor
FILETIME-zero readings via the pwsh observer on pwsh-created *files* — the
floor stays needed). Residual-race walk and TODO spot-checks (11/16/25/30/52)
done; details under the findings.

**Adjudication of the foreign-model counterpoints** (no findings needed):

- *"Lock files have the same stale/release problems as dirs, and are worse on
  POSIX because unlinking an open file removes the path under the holder."*
  Settled: **not a defect of this protocol, and not a file-vs-dir
  differentiator.** The objection is real for *fd-based* locks (flock), where
  ownership = an open descriptor and losing the path silently invalidates it.
  Here ownership is the **path name + token content**; no holder keeps an fd
  open. On POSIX a third party can equally `rm -rf` a held lock *dir* —
  path-removal-under-the-holder is precisely the displacement case the
  state machine already owns, and it is detected identically in both designs:
  the displaced holder's release finds gone/foreign token ⇒ 98. The plan's
  "same stale/release machinery carries over" framing is honest about the
  first half of the objection. POSIX note (probes were Windows-only): on POSIX
  unlink/rename of the lock file always succeed regardless of open handles, so
  the LEFTOVER lane is effectively Windows-only and POSIX behaviour is
  strictly *simpler* than probed; the floor and retries are harmless there.
- *Local-filesystem assumption*: now stated explicitly in
  docs/git-commit-lock.md (the new flock section + closing paragraph); claims
  checked against the code and spot-verified empirically (no `flock(1)` in
  this Git-for-Windows bash, rc=1). One wording nit filed as TODO #57.
- *Residual races "unchanged"* — **confirmed** by walking both windows under
  the file protocol. Acquire-side: mtime re-read → `mv` window identical in
  shape; a rival steal+re-acquire in the gap moves a brand-new live *file*
  instead of dir; victim's release sees gone/foreign ⇒ 98. Release-side: token
  re-read → `rm -f` window identical; an ENOENT there (`-f` masks it) can mean
  "stolen in the gap", but the steal then post-dates the token match and hence
  the completed work — benign, exactly as in the dir design. No new window is
  introduced: the create→write gap (probe F) is covered by fresh mtime (waiters
  wait) and the read retries; the steal renames token-with-file atomically,
  preserving the dir design's token-travels-with-the-lock property.

**Findings** (numbered continuously; none is a blocker):

1. **[MINOR] The steal's regular-file guard does not reject symlinks; `[ -f ]`
   follows them.** TODO #11 explicitly lists "reject symlinks". A symlink at
   the lock path passes the proposed guard with staleness judged on the
   *target's* mtime (`stat` follows links) while `mv`/`rm -f` act on the link
   itself — damage is capped at destroying the user's symlink, but the lane is
   incoherent: acquire's O_EXCL/CreateNew refuses a symlink path (EEXIST even
   when dangling), so symlinks should land in the same never-steal/loud-warning
   lane as directories. Disposition: add `! -L` (bash) / a reparse-point check
   (ps1) to guard step 2.
2. **[MINOR] "#11 residual = validate-the-path niceties only" understates the
   residual.** A typo'd `AGENT_LOCK_DIR` pointing at any existing **regular
   file** older than the stale window is still renamed and **deleted** by the
   steal. Not a regression (today's dir protocol `mv`+`rm -rf`s it too — there
   is no `-d` check before the steal), but the file design enables a cheap
   near-complete fix the dir design couldn't have: steal only when the file is
   **empty OR line 1 matches the token shape** (both impls' tokens start
   `tok.`). Real user files are neither, so a typo'd path becomes
   non-stealable; the empty-orphan lane stays stealable. Cost: a wire-format
   constraint on line 1 (pre-release, free; note it would bind future
   implementations). Disposition: adopt (recommended) or explicitly decline in
   the protocol section; either way reword the #11 entry in the impact table.
3. **[MINOR] Release classification of a successfully-read EMPTY lock file is
   unspecified, and the dir-era ps1 rationale does not port.** Dir era: token
   file *missing* with the dir present was a definitive "not ours" (ps1
   Status='ok', Token='' ⇒ stolen/98), while bash mapped empty+present to the
   rc-2 unverifiable lane. File era: an empty read is the probe-F window (a
   successor mid-create after a boundary steal) **or** the holder's own
   10×-failed write — not definitive theft evidence, but also possibly genuine
   theft. Both verdicts are safe (98 is conservative; 2 is honest), but the two
   impls would diverge on the wire. Disposition: pin it — both impls map
   empty-but-exists (after the retry ladder) to the unverifiable lane (bash 2 /
   ps1 'unreadable'), reserving 98 for a non-empty foreign token or a gone
   file. One sentence in the Release section settles it.
4. **[MINOR] The TODO impact table stops at item 52, but items 53–56 exist**
   (performance pass, committed 37afd82, *before* the plan commit 950ad3e):
   53 lazy gitdir, 54 builtin hot-forks, 55 marker-polling, 56 the WAITING log
   line — all touch exactly the code and tests Phases 1–3 rewrite. Disposition:
   add a table row (likely "fold into the rewrite / mechanical"); if 56 lands
   with this change, its WAITING line belongs in the plan's Logging section.
5. **[NIT] D1's "unlink-blocked ⇒ rename-blocked" is a share-mode fact, with
   one non-handle exception.** The equivalence is sound for handles (both
   delete and rename open the source for DELETE access, so the same
   FILE_SHARE_DELETE check gates both — re-verified today), and POSIX failure
   modes (parent perms, EROFS) block both alike. But the Windows **read-only
   attribute** breaks it: verified today, `File.Delete` fails while
   `File.Move` succeeds (and bash `rm -f` clears the attribute and succeeds).
   Nothing in the protocol ever sets read-only, and the stale steal (a rename)
   recovers the path, so deleting the fallback stands; ps1's grave delete can
   leave litter the bash sweep later clears. Disposition: one caveat line in
   the header comment; no design change.
6. **[NIT] "ancient-NFS caveats are the same class the dir protocol already
   had" overstates equivalence.** `mkdir` is atomic even on old NFS;
   `O_CREAT|O_EXCL` is the primitive with the historical NFSv2 caveat (the
   classic reason mkdir-locks were the NFS-safe idiom) — the file design is
   strictly weaker on ancient NFS. Moot in practice: the docs now exclude
   network filesystems outright. Disposition: reword to "out of scope — the
   docs exclude network filesystems", dropping the same-class claim.

**Verdict: concur with GO.** The protocol as specified is sound on both
Windows and POSIX; every load-bearing empirical claim I re-ran reproduced
(B, C1b, D, F); the deleted machinery (rename-aside release, `.new.*` dance,
metadata-less-orphan special case) is genuinely the hard-to-reason-about part;
the residual races are unchanged as claimed; and the plan is candid about
what does *not* simplify (floor, retries). Findings 1–4 should be folded into
the protocol/plan text before Phase 1 — they are spec amendments, not
redesigns — and none changes the decision. Open questions 1–4:
recommendations all look right to me (rename the knob; rename-aside steal;
drop epoch; drop the ps1 stamp).

---

# Plan: switch the commit lock from a DIRECTORY to an O_EXCL lock FILE

2026-06-10 · branch `main` · pre-release (no back-compat constraint).
Status: **plan for review — no code changed**. Probes live in
`.agent-testing/lockfile-probes/` (gitignored); each is re-runnable as noted.

## Problem statement and decision

Today the lock is a directory created by atomic `mkdir` (`.sh`) or
temp-dir + `[IO.Directory]::Move` (`.ps1`), with a `token` file written inside
*after* acquisition. That two-step shape is the source of several warts: the
acquirer-died-before-metadata orphan (forcing dir-mtime staleness keying), the
partially-failed `rm -rf` release (forcing the rename-aside fallback), the ps1
temp-dir dance with its `.new.*` litter and post-create mtime stamp, and the
litter sweep. The proposal: make the lock a single **regular file created with
O_CREAT|O_EXCL**, whose **content is the token** — creation and ownership
metadata become one atomic-enough step, and release becomes one unlink.

Decision to make: adopt the file protocol now (both impls in lock-step, old
protocol dies), or ship the reviewed dir protocol as-is.

## Recommendation: GO

**Empirical clincher (2026-06-11, after the loop converged): the first CI
matrix run caught a REAL mutual-exclusion failure in the dir protocol on
macOS** — interop T1 violations=1 with steals=0, a pwsh holder's token
replaced by a second pwsh "winner", plus a lost update in T6 (TODO #59 has
the full evidence chain). Mechanism, probe-confirmed: .NET `Directory.Move`
is `rename(2)` on Unix, and POSIX rename atomically replaces an **empty**
destination directory — so every holder's empty-dir window (post-mkdir,
pre-token-write) is hijackable by a concurrent ps1 acquirer. There is no
clean dir-era fix (.NET has no atomic create-dir-or-fail, and the
vulnerability is the destination's emptiness). The file protocol removes the
vulnerable state by construction: O_EXCL/`CreateNew` fails on ANY existing
file, and the token travels with the create. The macOS interop leg stays red
until this plan lands — the dir protocol is unsound for pwsh on POSIX, not
merely less elegant.

The probes (below) confirmed every load-bearing claim of the file design and
dissolved the suspected decisive con (Windows handle behaviour). What the
switch buys:

- **ps1 acquire collapses** from temp-dir + atomic Move + post-create mtime
  stamp + `.new.*` sweep to one `File.Open(CreateNew)` call. The whole
  `Lock-TryCreateDir` / `Lock-SweepLitter`-for-`.new.*` machinery goes away.
- **Release is one unlink.** The partial-`rm -rf` failure mode (the original
  reason release needs a rename-aside fallback) cannot exist for a file — and
  Probe D shows the rename-aside *cannot help* a file anyway (rename and
  unlink are blocked by exactly the same handles), so that fallback is deleted
  rather than ported.
- **The metadata-less-orphan state disappears as a separate case.** A crash
  between create and content write leaves an *empty file with a valid mtime* —
  stealable by the normal staleness rule, no special rationale needed.
- **TODO #30's untestable path becomes deterministically testable**: a pwsh
  holder with a `FileShare.Read` handle makes release's unlink fail on demand
  (Probe D1), so the blocked-release → "leftover" path gets a real test.
- **The destructive surface shrinks.** The tool stops ever running `rm -rf`,
  and the steal gains a "regular files only" guard, so a typo'd
  `AGENT_LOCK_DIR=$HOME` can no longer have a directory tree renamed or
  deleted (defuses most of TODO #11).
- Matches git's own convention (`.git/index.lock` etc. are lock *files*).

The honest NO-GO case: this rewrites the core of a tool that just absorbed a
six-review fix wave and has three green suites; every steal/release/fabrication
site in the impls and suites must be ported and re-stabilised, and ~2 days of
review effort already spent on dir-specific reasoning (partial-rm, rename-aside,
litter sweep) is discarded. Two dir-era defences turn out to be **still needed**
(probes): the mtime floor (FILETIME-zero transients occur for plain file
creation too, not just renamed dirs) and the empty/unreadable-token read retries
— so the simplification is real but smaller than the hypothesis hoped: staleness
keying, floor, steal-rename, token-compare-at-release, exit codes, knobs and log
all carry over. The known residual check-then-act races are unchanged (neither
narrowed nor widened). If the suites were our only safety net I'd still call
this a comfortable GO: pre-release is the cheapest this change will ever be, the
deleted machinery is exactly the code that was hardest to reason about and test,
and the porting work is mechanical under an unchanged behavioural contract
(exit codes, log lines, knob semantics all survive — most tests port by changing
how a fake lock is fabricated).

## Proposed protocol (precise enough to implement from)

**Lock identity.** The lock is the regular file at `AGENT_LOCK_DIR`
(default `<gitdir>/commit.lock`; see open question 1 on renaming the knob).
Whoever created it holds it. While the file exists, no one else can create it
(O_EXCL), so an existing file is unambiguously the current holder's — the same
invariant the dir had.

**File content** (UTF-8, no BOM, LF):

```
<token>\n
<owner>\n        # informational: "pid=<pid> host=<host>"
```

Line 1 is load-bearing (theft detection) and **must start with `tok.`** — the
steal's content guard keys on that prefix, so it is part of the wire format,
not an implementation detail. Line 2 is for the `STALE (holder=...)` log line
only. `epoch` is dropped — the file mtime and the log
timestamps carry that information. Readers take line 1, strip CR/whitespace;
they must tolerate a missing line 2 and an entirely empty file.

**Acquire** (poll loop, unchanged shape):

- **Pre-create type guard (bash: mandatory).** If something exists at the lock
  path that is not a regular file, do NOT attempt the create — fall through to
  the wait/steal loop, whose non-lock guard logs the one-time config warning
  (waiters reach 97). Rationale: noclobber's exists⇒fail protection applies to
  *regular files* only — `>` onto an existing FIFO **blocks in open(2)** before
  any timeout logic runs, and onto a device node simply writes. (A symlink,
  even dangling, is safely refused by O_CREAT|O_EXCL itself; the pre-check
  just routes it to the same warn lane coherently.) The check-then-open gap is
  acceptable: a non-lock object at the path is static misconfiguration, not a
  racing peer.
- bash: `( set -C; printf '%s\n%s\n' "$tok" "$me" > "$LOCK" ) 2>/dev/null` —
  one redirect = open(O_CREAT|O_EXCL)+write+close. Note the `2>/dev/null` goes
  on the *subshell*, because the noclobber failure message is emitted by bash
  itself, not printf (probe A finding). Non-zero rc ⇒ not acquired ⇒ loop (the
  rare created-but-write-failed case, e.g. ENOSPC, leaves an empty — or,
  rarely, torn; see steal guard 3(b) — orphan that ages into its
  corresponding lane).
- ps1: ensure the parent directory exists first (today's `Lock-TryCreateDir`
  creates it before the atomic move; the port must keep that — bash keeps its
  `mkdir -p` below), then `[IO.File]::Open($path, CreateNew, Write,
  FileShare ReadWrite|Delete)`,
  then **write both lines, flush, and close through that creation handle** —
  the write is bound to the file object we created and cannot land on a
  successor's file, whatever happens to the path meanwhile. **Any exception on
  the open ⇒ contended ⇒ `$false`** — not just `IOException`: an existing
  *directory* at the path throws `UnauthorizedAccessException` (verified,
  pwsh 7.5), and a `catch [IO.IOException]` alone would throw out of
  Lock-Acquire in exactly the lane that must degrade to the config warning.
  (.NET's Unix open uses O_CREAT|O_EXCL, so FIFO/device paths fail with an
  exception rather than blocking; the bash-style pre-check is optional
  symmetry, not load-bearing, for ps1.)
- After winning, **verify via a path read-back: read line 1 with each impl's
  existing retry ladder (bash 5×20ms; ps1 8 tries, 20→320ms escalating
  backoff); our token ⇒ HELD. Anything else after the ladder —
  foreign, empty, or gone — means we cannot prove we hold the path: log
  loudly, treat as NOT acquired, and re-enter the wait loop. NEVER repair a
  failed read-back by writing to the path.** A plain overwrite would be safe
  only while the file is provably still ours, and after a long suspension
  (sleep/stop-the-world) it provably isn't: the stale window may have let a
  waiter steal the path and a successor re-create it, so the "repair" would
  clobber the successor's token and produce a silent, *undetected* double-hold
  (the resumed holder's release would then find its own token and return 0).
  Giving the lock up instead is always safe: a foreign token is a successor
  who legitimately owns the path; our own orphan (empty or token-bearing,
  reads failing) ages into the steal lane and is reclaimed. This replaces the
  dir era's load-bearing token-write retry — and quietly fixes the same
  overwrite-after-suspension hazard that retry carried.
- The acquire-verification failure lane has no deterministic test (it needs
  fault injection to make a winning create unreadable); like the read-retry
  ladders it is defence in depth — document it in the header, don't claim
  suite coverage.
- The ps1 post-create `SetLastWriteTimeUtc` stamp is **deleted**: CreateNew +
  the content write stamp mtime; the floor (kept, below) is the backstop.
- `mkdir -p "$(dirname "$LOCK")"` stays (explicit `AGENT_LOCK_DIR` parents).
- The grave sweep shrinks to `rm -f "$LOCK".dead.* ` (file graves only;
  `.new.*` and `.rel.*` no longer exist). It **keeps the existing age-gated
  semantics** (mechanical port; unit T15's age-gate assertion ports
  unchanged). Dropping the gate would also be safe — a `.dead.*` grave is
  trash from the instant it exists, and a displaced ps1 victim's delete-share
  handle means even its in-flight writes land in the grave harmlessly — but
  keeping it minimises churn.

**Staleness** — unchanged: keyed on the lock *file's* own mtime
(`stat -c %Y` chain / `Get-Item ... LastWriteTimeUtc`), threshold
`AGENT_LOCK_STALE_SECS` (300), **mtime floor 946684800 kept** — probes C2/C1b
show freshly created *files* (both bash- and pwsh-created) transiently report
FILETIME zero (−11644473600) to a `Get-Item` observer at ~0.04–0.5% of reads,
so claim (c) of the hypothesis is refuted: sub-floor still means "unsettled,
wait", in both impls.

**Steal** — rename-aside, as today, with one new guard. (Implementation
deviation, recorded in the changelog's wave-2 entry: the landed bash per-poll
guard warns only on a *concretely identified* wrong type — `-d/-L/-p/-S/-b/-c`
— never on exists-but-unclassifiable, because Windows delete-pending ghosts
defeat existence re-probes; the "exists = `-e || -L`" pin below describes the
original spec.) Ordering note: the
cheap **type guard (step 2) is evaluated on every blocked poll**, not only
once the lock looks stale — an actively-written non-lock path (the canonical
`AGENT_LOCK_DIR=$HOME` typo: writes inside keep refreshing the dir's mtime)
never ages past the window, so an age-gated guard would never fire and
waiters would hit 97 with no diagnosis. The per-poll guard warns only on
**exists-but-wrong-type** — a path that vanished between the failed create
and the check is normal contention (re-race the create), not a config
warning, or the once-per-process warning would burn on a healthy system.
"Exists" is pinned as `-e || -L` (ps1: a probe that sees the link itself,
e.g. `Get-Item -Force`, not the target): a **dangling symlink** is refused
by O_CREAT|O_EXCL forever but reads as absent to a bare `-e`, so keying
existence on `-e` alone would classify it as normal contention every poll
and the waiter would die at 97 with no diagnosis. The
content guard (step 3) stays age-gated (don't read content on every poll) —
accepting one diagnostics gap as the flip side: an actively-REWRITTEN
regular user file at a typo'd path also never ages into the content guard,
so it too ends in 97 without a config warning. Safety is intact either way
(nothing is stolen or deleted); these two lanes trade diagnosis for not
stat/reading the path's content on every poll.

1. mtime above floor and age ≥ stale window;
2. **the lock path must be a regular file and not a symlink**
   (`[ -f ] && ! [ -L ]`; ps1: not `PSIsContainer` and no `ReparsePoint`
   attribute — `[ -f ]` alone follows links, and acquire's O_EXCL/CreateNew
   refuses a symlinked path anyway, so a symlink can never be a legitimate
   lock); anything else (a directory: config typo or leftover old-protocol
   lock; a symlink; a device) ⇒ log a loud one-time config warning, never
   steal, let waiters reach 97. This is what makes `AGENT_LOCK_DIR=$HOME`
   harmless;
3. **the content must be lock-shaped**: steal only when the file is empty
   (the crash-orphan lane) or line 1 starts with `tok.` (both impls' token
   prefix — now a wire-format constraint on line 1, binding for future
   implementations; pre-release this is free). Real user files are neither,
   so a typo'd `AGENT_LOCK_DIR` pointing at an existing regular file becomes
   non-stealable instead of renamed-and-deleted — closing most of what
   remained of TODO #11. **ps1 determines "empty" by stat (`Length -eq 0`)
   WITHOUT opening the file, and opens for read only when size > 0** — on
   Unix a FIFO at the lock path is neither a container nor a reparse point,
   so it reaches this step, and a read-open on a writer-less FIFO blocks in
   `open(2)` before any timeout logic runs (the same hazard class the bash
   pre-create guard kills; bash's *steal* is already safe via `[ -f ]`).
   Residual (ps1-on-Unix only; bash refuses all of these via `[ -f ]`): a
   typo'd-path FIFO — and likewise a device node or socket, which .NET has no
   clean portable type probe for, so step 2's "never steal a device" is
   delivered by bash but not by ps1 on Unix — stats as size 0 and takes the
   empty-orphan lane: renamed aside AND grave-deleted, so damage is capped at
   the one misconfigured inode (in practice /dev permissions make real device
   nodes unrenamable anyway). Same accepted class as the empty-user-file
   residual. (The .NET-on-Unix blocking claim is
   reasoned-not-probed — no pwsh-on-Unix on this box; one line on CI's
   ubuntu leg settles it.) Two lanes pinned identically in both impls:
   (a) a **persistent read failure with the file still present** is neither
   "empty" nor the never-steal lane — skip this steal attempt and re-poll
   (bash tells genuinely-empty from read-failed via `[ -s ]` plus the read's
   rc; ps1 catches the read exception rather than letting it escape or fire
   the config warning). Self-correcting: a handle that blocks the read
   usually blocks the rename too (D1), so refusing costs nothing.
   (b) a **torn token write** (line 1 a strict prefix of `tok.`, e.g. `to` —
   reachable only via ENOSPC/crash mid-write) is non-empty and non-prefixed,
   so it lands in the never-steal lane permanently: an accepted residual,
   loud (the config warning names the path) and fixed by one manual `rm`.
   The dir protocol would have recovered it by staleness; we trade that
   vanishing-rare case for not deleting real user files. The guard's
   converse residual is also accepted and documented: a stale *user* file
   whose first line happens to start `tok.` IS still stolen — the prefix is
   the whole wire test, deliberately (a fuller shape check would just bind
   the format harder for near-zero added protection against an already
   contrived collision);
4. read line 2 (best-effort) for the `STALE (holder=…)` log line — BEFORE the
   final mtime re-read, as today (both impls): an open+read inserted between
   the re-read and the rename would widen exactly the window the re-read
   exists to shrink;
5. re-read mtime immediately before acting; any change ⇒ abort attempt (as
   today); then `mv "$LOCK" "$LOCK.dead.$$.<ts>"` /
   `[IO.File]::Move(...)` — atomic on NTFS for files, exactly one concurrent
   stealer wins (probe E4: 60/60), losers get ENOENT/`FileNotFoundException`
   and re-race the create; winner `rm -f`s the grave and logs `STOLE`.

**Release** — token compare, then unlink:

1. read line 1 with the existing retry ladders (bash: 5× retry while
   empty-but-file-exists; ps1: the ok/gone/unreadable classification with
   escalating backoff, `FileNotFoundException` ⇒ gone). Probe F proves the
   empty-read window is real (555/198k reads caught the file created but not
   yet written), so these retries carry over verbatim;
2. classification is pinned identically in BOTH impls: a **non-empty foreign
   token, or a gone file** ⇒ restore traps, warn, **98** (theft); a file that
   still reads **empty after the retry ladder** is NOT definitive theft
   evidence (it is the probe-F create→write window of a successor after a
   boundary steal, or external truncation — it cannot be our own failed
   write, since acquire's read-back positively verified our token at the
   path, which is also what grounds treating "gone" as theft) ⇒ the unverifiable lane
   (bash rc 2 / ps1 'unreadable'): don't delete, don't claim success;
3. match ⇒ re-read once (boundary-shrink), **classified by the same step-2
   rules in BOTH impls** — empty-at-boundary ⇒ the unverifiable lane, do NOT
   delete (in the file era an empty boundary read is precisely the probe-F
   window of a successor mid-create after a boundary steal; today's ps1 lets
   an unreadable boundary read proceed to the delete, which must not port);
   gone-at-boundary ⇒ 98; our token ⇒ delete:
   `rm -f -- "$LOCK" 2>/dev/null`; rc 0 ⇒ released (`-f` masks only ENOENT,
   which is the "vanished mid-race = already released" branch). On failure ⇒
   retry ~5×20ms — grounded on D1, not on the failure itself: the handle
   class that blocks our unlink also blocks any steal's rename, so the path
   cannot be stolen-and-recreated while the delete keeps failing (the
   read-only-attribute exception is documented below; its residual is the
   same detected-98 class) ⇒ persistent
   failure ⇒ **leftover**: warn, return 1. Recovery needs BOTH conditions: the
   stale window elapsing AND the blocking handle closing — the no-delete-share
   handle that blocks our unlink blocks a stealer's rename identically (D1),
   so until it closes waiters re-poll on failed steals and may reach 97 if it
   never does. ps1: `File.Delete` (silent on missing = same vanished branch),
   `IOException` + still-exists ⇒ retry ⇒ leftover. **No rename-aside**: probe
   D1 shows a handle that blocks unlink blocks rename identically for files
   (a share-mode fact: both ops need DELETE access on the source), so the
   fallback can never fire usefully — replaced by the retry. One non-handle
   exception, for the header comment: the Windows **read-only attribute**
   fails `File.Delete` but not `File.Move` (and bash `rm -f` clears it).
   Nothing in the protocol ever sets read-only; if something external does,
   the leftover warning fires and the stale steal (a rename) recovers the
   path, so the deleted fallback stays deleted.

**Unchanged:** exit-code contract (96/97/98 + command's own), all `AGENT_LOCK_*`
knobs and validation, lock/log location in the git dir, trap/signal handling,
reentrancy guard, the STALE≥MAX_WAIT advisory (in its landed *gated* form:
fires only when MAX_WAIT was left at default), log size cap, the KNOWN RESIDUAL
RACES (both windows persist with the same detection: the displaced party's
release cries 98 — see "races" below).

### State machine

| State | How reached | Exit |
|---|---|---|
| ABSENT | initial; clean release; steal-rename | one O_EXCL create wins ⇒ read-back verify ⇒ HELD (failed verify ⇒ not acquired, re-enter wait) |
| HELD (token+owner content, mtime=now) | create won, content written, path read-back verified | release ⇒ ABSENT; crash ⇒ token-bearing file, stale after the window; overlong hold ⇒ stealable |
| EMPTY ORPHAN (file exists, empty or `tok.`-prefixed partial content, valid mtime) | crash between create and write; dropped/truncated write | normal staleness steal (mtime ages past window) — the regression test for old T3. (A torn write SHORTER than `tok.` lands in NON-LOCK below, not here) |
| UNSETTLED (mtime < floor) | observer-side FILETIME-zero transient on a brand-new lock | waiters treat as live and wait; settles in ms |
| STALE (age ≥ window) | crash, or contract-breach slow hold | exactly one stealer renames it aside; victim (if alive) gets 98 at release |
| LEFTOVER (release unlink blocked persistently) | foreign no-delete-share handle (AV, naive reader) | release returns 1 loudly; stealable only once stale AND the blocking handle closes (same handle blocks the steal rename, D1) — waiters re-poll, 97 if it never closes |
| NON-LOCK at lock path (dir, symlink, device, non-lock-shaped content, or a torn `tok`-prefix write) | config typo; old-protocol dir lock; user file at a typo'd path; ENOSPC/crash mid-write | never stolen (bash also refuses the create via the pre-create type guard — noclobber alone would block on a FIFO); loud config warning; waiters reach 97; manual fix |

### Residual races (unchanged, for the record)

- *Acquire-side:* between the steal's mtime re-read and the rename, a rival
  completes steal+re-acquire ⇒ our rename moves a brand-new live lock.
- *Release-side:* between the token check and the unlink, a boundary steal +
  re-acquire slips in ⇒ our unlink deletes the successor's live file.
- *Release-retry gap (new with the retry, for completeness):* the D1 guarantee
  ("the handle blocking our unlink also blocks a steal's rename") holds while
  the handle is OPEN — it can close *between* our ~20ms retries, letting a
  steal + re-create land before the next attempt, whose `rm -f` then deletes
  the successor's live file. Needs a contract-breach stale hold plus a full
  steal+create inside the gap; the retry technically widens the release-side
  window by the ~100ms budget. Same detection as the others (successor's
  release ⇒ 98).

All require a hold that overran the stale window, and all are detected
(the displaced holder's release finds a missing/foreign token ⇒ 98). Note for
the future, not this change: the ps1 side *could* close both windows outright
with handle-based ops (open the file with delete sharing, fstat the mtime /
read the token via the handle, delete via `FILE_DISPOSITION` on that same
handle — a rival's re-created file is a different inode and is untouched).
bash has no handle persistence, so the protocol-level claim must stay "shrunk,
detected, not closed"; record the option in the header comment only.

### Compatibility notes

- The two impls change **in lock-step in one commit**; mixed old/new agents in
  one repo were never supported and the suites pin the new protocol. (Mixed
  versions would still *contend* correctly — `mkdir` fails on an existing file
  name and O_EXCL fails on an existing dir — but steal/release semantics
  diverge; don't run mixed.)
- A leftover old-protocol *directory* at `.git/commit.lock` (only possible if
  an old agent crashed mid-hold) is deliberately not auto-deleted: the
  non-file guard warns and names the fix (`rmdir`/`rm -rf` it once, by hand).
- O_EXCL is atomic on local POSIX filesystems and NTFS (probed). On ancient
  NFS it is historically *weaker* than `mkdir` (the classic reason mkdir-locks
  were the NFS-safe idiom) — out of scope rather than equivalent: the docs now
  exclude network/sync-backed filesystems outright.

## Empirical probe results (2026-06-10, Win 11 / MINGW bash 5.3.9 / pwsh 7.5.5, NTFS)

Scripts in `.agent-testing/lockfile-probes/`; re-run each with
`bash <script>`. Summary of observations:

| Probe | What | Result |
|---|---|---|
| A `probe-a-noclobber-race.sh` | 30 bash contenders × 6 rounds race `( set -C; printf > lock )` | exactly 1 winner every round; winner's token is the content. Gotcha: the loser's "cannot overwrite existing file" comes from **bash**, so silence the *subshell's* stderr |
| B `probe-b-cross-race.sh` | 8 bash + 4 pwsh contenders race noclobber vs `File.Open(CreateNew)` on one path, 4 rounds | exactly 1 winner per round; wins landed on both sides (ps×3, sh×1); content matches — the two gates contend correctly on NTFS |
| C/C1b `probe-c-mtime.sh`, `probe-c1b-mtime.sh` | tight create/delete loops; the OTHER runtime stats mtime continuously | bash-created files: pwsh `Get-Item` saw **37/93038 readings = FILETIME zero (−11644473600)**; pwsh-created files: 27/5017 sub-floor via pwsh observer, 0/11 via (slow) bash stat. Max readings always sane ("now"). ⇒ **keep the mtime floor in both impls**; the unsettled window is not a dir-rename artifact |
| D `probe-d-handles.sh` | handle/share semantics | D1: a `FileShare.Read` handle (what `ReadAllText` holds) blocks bash `mv`, bash `rm`, `File.Delete` **and** `File.Move` — unlink-blocked ⇒ rename-blocked, so release's rename-aside is useless for files. D2: a `ReadWrite|Delete`-share handle blocks nothing (rename succeeds, name gone, grave deletable). D3: a Cygwin/bash read fd never blocks .NET Move/Delete (Cygwin opens with delete sharing). D4: **0/200** steal-`mv` failures while a pwsh `ReadAllText` loop hammered the file — even the naive reader's window is microseconds |
| E `probe-e-churn.sh` | 400-cycle create/read/delete churn of `.git/commit.lock` in a real repo, file vs dir, bash and pwsh | **zero** failures in all three runs on this box (no AV/Defender/indexer transients observed); E4: concurrent `rm` and concurrent `mv` both give exactly-one-winner 60/60 |
| F `probe-f-emptyread.sh` | pwsh reads content in a tight loop while bash creates/deletes ×600 | **555 empty reads** (file exists, content not yet written) vs ~198k non-empty ⇒ the open→write gap is observable; keep the empty-read/unreadable retry ladders |

Caveats: the AV result (E) is machine-specific (this box may have exclusions);
the D4/E rates say "rare", not "impossible" — which is why the release keeps a
retry + leftover path and the steal loop simply re-polls on a failed rename.

One ps1 reader improvement falls out of D1/D2: **all ps1 reads of the lock file
should use an explicit `FileStream` with `FileShare ReadWrite|Delete`** (not
`ReadAllText`'s `FileShare.Read`), so our own readers can never block a steal or
release even transiently. bash/Cygwin readers already share delete (D3).

## Implementation phases (gate: all three suites green)

**Sequencing vs the CI plan
(.plans/2026-06-10-main-github-actions-ci-plan.md): land CI first.** This
plan's probes are Windows-only and its POSIX/macOS claims are reasoned, not
probed — running Phases 1–3 under CI's 3-OS matrix is exactly the missing
verification; porting before CI would also silently invalidate the CI plan's
dir-era measurements.

**Phase 1 — bash implementation + unit suite.**
Rewrite acquire (noclobber create, content = token+owner, read-back verify),
`_lock_cur_token` (line 1 of the lock file, same retry), steal (non-file guard,
file rename-aside), release (unlink + retry + leftover; delete the rename-aside
branch), sweep (one `rm -f` for `.dead.*`), and the header comment block
(WHY/STALENESS/RESIDUAL sections rewritten for the file design — subsumes TODO
#23/#24 wording). Port the suite: T2/T9 fabricate with `printf`+`backdate`
(backdate works on files unchanged); T3 becomes the **empty-file orphan**
regression; T6/T10 assert `-f` not `-d`; T15 fabricates file graves. One semantics flip to port deliberately: unit T16 (missing-token unverifiable
release) fabricates by deleting the token file inside the dir — under the file
protocol that becomes **truncating the lock file** (the "empty-but-exists ⇒
unverifiable" test below IS T16's replacement), while **deleting the lock file
now asserts 98**, not the unverifiable lane. New tests:
sub-floor file (T9 port), non-file-at-lock-path refusal (dir AND symlink, and
the pre-create type guard on a FIFO where mkfifo exists), non-lock-shaped-
content steal refusal (a stale "user file" at the lock path survives, incl.
the torn `tok`-prefix lane), empty-but-exists release classification
(unverifiable lane, not 98), gone-at-release ⇒ 98, token-line-1 parsing with
owner line present. Done = `git-commit-lock.test.sh` green.

**Phase 2 — ps1 implementation + interop suite.**
Replace `Lock-TryCreateDir` with the CreateNew open+write (delete-share);
delete the mtime stamp and the `.new.*` sweep arm; `Lock-ReadCurToken` reads
the lock file itself (`FileNotFoundException` ⇒ gone; delete-share
`FileStream` reads); steal via `File.Move` with the non-file guard; release via
`File.Delete` + retry + leftover; port the **`PowerShell.Exiting` best-effort
release backstop** too (today it reads `$lock/token` and calls
`Directory.Delete` directly — it becomes: read line 1 of the lock file,
compare the token, `File.Delete`). Port interop T4/T5 fabrication (file + first
line) — the suite already uses the portable `epoch_to_stamp`/`backdate`
helpers (landed 340a584); the port must preserve that pattern and not
reintroduce GNU-only `touch -d` (CI's macOS leg will be live by then). Keep
the behavioural tests as-is with one exception: **interop T11** (cross-impl
missing-token) fabricates by deleting the token file — re-split it into
(i) truncate-the-lock-file ⇒ both impls report the unverifiable lane, and
(ii) delete-the-lock-file ⇒ both impls report **98** (a new cross-impl
gone⇒theft agreement assertion). New interop tests (pwsh required,
so they live here). **Tests (a) and (b) — including (a)'s recovery half —
are gated to Windows** (skip-with-note elsewhere, like Phase 1's mkfifo
conditioning): they manufacture blocking via a `FileShare.Read` holder, and
on POSIX unlink/rename never block on open handles (.NET's Unix FileShare is
advisory among .NET openers and gates no namespace operation), so on the
ubuntu/macos CI legs (a) would fail outright — the release simply succeeds —
and (b) would pass vacuously: (a) **blocked release** — a pwsh process holds the lock
file with `FileShare.Read` while the bash holder releases ⇒ deterministic
leftover path — rc 1 meaning the *sourced* `lock_release` return value /
`LockReleaseStatus='leftover'`; the `run` wrapper keeps the wrapped command's
own exit code on a leftover, per the unchanged contract — then recovery once
the handle closes after the stale window (makes TODO #30 testable); (b)
blocked *steal* — same holder pattern against a stale lock ⇒ stealer re-polls,
acquires after the handle closes; (c) **ps1-side guard parity** — the dir /
symlink (reparse-point) / non-lock-shaped-content guards exercised from the
ps1 implementation, not only bash (they use different APIs — `PSIsContainer`,
reparse attributes, the catch-all open exception — so bash coverage proves
nothing about them); include dir-at-lock-path acquire degrading to `$false` +
config warning rather than throwing. Done = interop suite green.

**Phase 3 — integration suite + full matrix.**
Expected to pass nearly unchanged (it uses defaults and `-e` assertions); run
it, fix fallout, then run all three suites ×3 back-to-back **with
`GCL_TEST_FULL=1`** — this is the deliberate full-strength pre-publish canary
that TODO #58 designates as the explicit opt-in case (the same item that makes
routine dev runs reduced by default), so coordinate the timing with Ben rather
than running it while other agents are active. Done = 3×3 green runs, with the
suites' mode lines confirming full strength ran (58's masquerade guard).

**Phase 4 — docs, TODO, linters.**
README "How it works" + docs/git-commit-lock.md "How the lock works" / port
sections rewritten (mkdir→O_EXCL file, token-as-content, floor rationale now
file-based, release/steal text); delete the partial-rm/rename-aside/`.new.*`
prose. **Preserve the README's platform scoping (added 2026-06-11, Ben's
call): the ps1 implementation is *supported on Windows only* — no harness
drives pwsh on POSIX, so we ship no claim without a use case — while the
POSIX interop CI legs are framed as cross-implementation protocol
verification, not platform support.** The port closes TODO #59, so delete
the README's known-issue note about the red macOS leg, but keep the scoping
itself; also fix the ps1 owner line's `$env:COMPUTERNAME` →
`[Environment]::MachineName` so `host=` is populated on POSIX CI legs
(cosmetic, log-only); update the live TODO-main.md items (11, 48, 53–56, 58) per the table
below;
re-run shellcheck + PSScriptAnalyzer (item 48's residual). Done = docs describe
only the file protocol; no stale "lock dir(ectory)" wording outside the
changelog.

## TODO-main.md impact (by item number)

Numbering refers to the original consolidated review list. After the
2026-06-10 fix wave, only **11, 48, 53–56, 58** remain live in TODO-main.md
(see its header; the rest were fixed and deleted; the 58 TODO *item* was
added 2026-06-11 — the knob itself is implemented during the suite ports). The
full table is kept because it names dir-era behaviours and tests the port must
preserve or may delete — but Phase 4's TODO edits touch only the live items.

- **Mooted / shrunk:** **20** (`.new.*` and `.rel.*` litter cannot exist;
  sweep shrinks to one `rm -f .dead.*` line), **23** (header rewritten
  wholesale), **30** (rename-aside fallback deleted; replaced by
  retry+leftover, which gains the deterministic open-handle test it could
  never have), **52** (ps1 post-create stamp deleted; token retry comments
  reworded), **11** (largely closed: no `rm -rf` anywhere, the steal refuses
  non-regular-files and symlinks, and the token-shape content guard makes a
  typo'd path at a real user file non-stealable; residual = an *empty* user
  file at a typo'd path is still stealable, plus validate-the-path niceties).
- **Confirmed still required (do NOT drop):** **25** — the mtime-floor guard
  and its deterministic test stay; probes C/C1b show files need it too. **16**
  — token read/write retry asymmetry still applies, now against the lock file
  (probe F). **6** — residual races unchanged; keep the item, add the
  ps1-handle-hardening note as its possible future close-out.
- **Mechanical port, substance unchanged:** **2** (stat chain now probes a
  file; same fix), **26–29, 31–39, 50, 51** (fabrication sites and `-d`/`-f`
  assertions move; behavioural content identical), **48/49** (re-run linters
  after the rewrite).
- **Performance pass (53–56) + fan-out opt-in (58): fold into the rewrite.**
  53 (lazy gitdir) and 54 (builtin hot-forks) touch exactly the code Phases
  1–2 rewrite — apply them as part of the port rather than twice; 55
  (marker-polling) and 56 (`WAITING` log line) land with the suite ports in
  Phases 1–3. If 56 lands here, its log line is included in the Logging
  section below. **58** (reduced default fan-out, full strength only under
  `GCL_TEST_FULL=1`) rescopes the very fan-out tests Phases 1–3 rewrite (unit
  T1's 8×25, interop T1/T6, the integration swarms) — implement the knob as
  part of the suite ports rather than twice; it reduces fan-out *width* while
  56 protects *timing*, so the two compose without conflict.
- **Unaffected:** **3, 4, 5, 8, 9, 10, 12–15, 17–19, 21, 22, 40–47** (traps,
  exit-code plumbing, 5.1 encoding, CLI guards, docs errata — orthogonal to
  the lock's on-disk shape; the Phase-4 doc rewrite should land their fixes in
  passing where it touches the same sentences).

## Open questions for Ben (recommendation first; silence = go with it)

1. **Rename `AGENT_LOCK_DIR` → `AGENT_LOCK_PATH`?** Recommend **yes**: the
   value is now a file path and the name would actively mislead; pre-release
   is the only free moment. Cost: your dotfiles/agent instructions mention
   `AGENT_LOCK_DIR` (tests/docs in-repo are covered by the phases). If you'd
   rather not touch the instruction fleet now, keeping the old name is
   workable — it's "the lock's path" — but I'd rename.
2. **Steal: rename-aside (recommended) vs plain unlink.** Unlink would have
   zero grave litter and is even safer against path typos, but `File.Delete`
   is silent on a missing file so the ps1 loser can't tell it lost (winner
   ambiguity poisons the STOLE log line), and bash would need plain `rm`
   stdin-guarded against tty prompts. Rename keeps today's exactly-one-winner
   logging with one `rm -f` of a file grave. Recommend **rename-aside**.
3. **Drop `epoch`, keep `owner` as line 2?** Recommend **yes** (minimal file;
   log timestamps cover epoch; owner feeds the STALE log line).
4. **Keep the floor but drop the ps1 post-create mtime stamp?** Recommend
   **yes** — the floor is the proven backstop (probes), and CreateNew+write
   stamps mtime without help.

## Logging

The log design carries over unchanged: same `ACQUIRED`/`RELEASED`/`STALE
(age, holder)`/`STOLE`/`TIMEOUT`/theft-`WARNING`/release-failure lines, same
`<gitdir>/git-commit-lock.log` default, same 1MB truncation cap, per-acquire
tokens in the lines. Changes: message text says "lock file" not "lock dir";
the `SWEPT stale litter` line survives only for `.dead.*` file graves; one new
loud line for the non-lock-at-lock-path config warning (logged once per
process, like the mtime-probe warning). Two further new lines: the
**acquire-verification failure** ("create won but read-back found
foreign/empty/gone — not acquired, re-entering wait") and the steal's
**unreadable-content skip** (persistent read failure on a stale lock ⇒
skipped attempt — logged like the existing steal-abort line, so a
reconstruction can see why a stale lock wasn't taken). The blocked-release
retry logs its final leftover WARNING exactly as today. If TODO #56 lands
with this change (recommended above), the contended path also gains its
one-line `WAITING` entry on the first blocked poll.
