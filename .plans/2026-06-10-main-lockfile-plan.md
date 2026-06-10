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

- bash: `( set -C; printf '%s\n%s\n' "$tok" "$me" > "$LOCK" ) 2>/dev/null` —
  note the `2>/dev/null` goes on the *subshell*, because the noclobber failure
  message is emitted by bash itself, not printf (probe A finding).
- ps1: `[IO.File]::Open($path, CreateNew, Write, FileShare ReadWrite|Delete)`,
  write both lines, close. Any `IOException` ⇒ contended ⇒ `$false`.
- After winning, **read back line 1; if it doesn't match the token, rewrite
  (plain overwrite, we own the file) with the existing 5×20ms retry budget** —
  this replaces today's load-bearing token-write retry (a create that won but
  whose write was dropped would otherwise guarantee a false 98 at release).
- The ps1 post-create `SetLastWriteTimeUtc` stamp is **deleted**: CreateNew +
  the content write stamp mtime; the floor (kept, below) is the backstop.
- `mkdir -p "$(dirname "$LOCK")"` stays (explicit `AGENT_LOCK_DIR` parents).
- The grave sweep shrinks to `rm -f "$LOCK".dead.* ` (file graves only;
  `.new.*` and `.rel.*` no longer exist).

**Staleness** — unchanged: keyed on the lock *file's* own mtime
(`stat -c %Y` chain / `Get-Item ... LastWriteTimeUtc`), threshold
`AGENT_LOCK_STALE_SECS` (300), **mtime floor 946684800 kept** — probes C2/C1b
show freshly created *files* (both bash- and pwsh-created) transiently report
FILETIME zero (−11644473600) to a `Get-Item` observer at ~0.04–0.5% of reads,
so claim (c) of the hypothesis is refuted: sub-floor still means "unsettled,
wait", in both impls.

**Steal** — rename-aside, as today, with one new guard:

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
   remained of TODO #11;
4. re-read mtime immediately before acting; any change ⇒ abort attempt (as
   today);
5. read line 2 (best-effort) for the log; `mv "$LOCK" "$LOCK.dead.$$.<ts>"` /
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
   boundary steal, or our own 10×-failed write) ⇒ the unverifiable lane
   (bash rc 2 / ps1 'unreadable'): don't delete, don't claim success;
3. match ⇒ re-read once (boundary-shrink, unchanged), then delete:
   `rm -f -- "$LOCK" 2>/dev/null`; rc 0 ⇒ released (`-f` masks only ENOENT,
   which is the "vanished mid-race = already released" branch). On failure the
   file still exists and is therefore still ours ⇒ retry ~5×20ms ⇒ persistent
   failure ⇒ **leftover**: warn, return 1, stale window reclaims (unchanged
   contract). ps1: `File.Delete` (silent on missing = same vanished branch),
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
reentrancy guard, STALE≥MAX_WAIT warning, log size cap, the KNOWN RESIDUAL
RACES (both windows persist with the same detection: the displaced party's
release cries 98 — see "races" below).

### State machine

| State | How reached | Exit |
|---|---|---|
| ABSENT | initial; clean release; steal-rename | one O_EXCL create wins ⇒ HELD |
| HELD (token+owner content, mtime=now) | create won, content written | release ⇒ ABSENT; crash ⇒ ORPHAN; overlong hold ⇒ stealable |
| EMPTY ORPHAN (file exists, no/partial content, valid mtime) | crash between create and write; dropped write | normal staleness steal (mtime ages past window) — the regression test for old T3 |
| UNSETTLED (mtime < floor) | observer-side FILETIME-zero transient on a brand-new lock | waiters treat as live and wait; settles in ms |
| STALE (age ≥ window) | crash, or contract-breach slow hold | exactly one stealer renames it aside; victim (if alive) gets 98 at release |
| LEFTOVER (release unlink blocked persistently) | foreign no-delete-share handle (AV, naive reader) | release returns 1 loudly; stale window reclaims |
| NON-LOCK at lock path (dir, symlink, device, or non-lock-shaped content) | config typo; old-protocol dir lock; user file at a typo'd path | never stolen; loud config warning; waiters reach 97 |

### Residual races (unchanged, for the record)

- *Acquire-side:* between the steal's mtime re-read and the rename, a rival
  completes steal+re-acquire ⇒ our rename moves a brand-new live lock.
- *Release-side:* between the token check and the unlink, a boundary steal +
  re-acquire slips in ⇒ our unlink deletes the successor's live file.

Both still require a hold that overran the stale window, and both are detected
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

**Phase 1 — bash implementation + unit suite.**
Rewrite acquire (noclobber create, content = token+owner, read-back verify),
`_lock_cur_token` (line 1 of the lock file, same retry), steal (non-file guard,
file rename-aside), release (unlink + retry + leftover; delete the rename-aside
branch), sweep (one `rm -f` for `.dead.*`), and the header comment block
(WHY/STALENESS/RESIDUAL sections rewritten for the file design — subsumes TODO
#23/#24 wording). Port the suite: T2/T9 fabricate with `printf`+`backdate`
(backdate works on files unchanged); T3 becomes the **empty-file orphan**
regression; T6/T10 assert `-f` not `-d`; T15 fabricates file graves. New tests:
sub-floor file (T9 port), non-file-at-lock-path refusal (dir AND symlink),
non-lock-shaped-content steal refusal (a stale "user file" at the lock path
survives), empty-but-exists release classification (unverifiable lane, not
98), token-line-1 parsing with owner line present. Done =
`git-commit-lock.test.sh` green.

**Phase 2 — ps1 implementation + interop suite.**
Replace `Lock-TryCreateDir` with the CreateNew open+write (delete-share);
delete the mtime stamp and the `.new.*` sweep arm; `Lock-ReadCurToken` reads
the lock file itself (`FileNotFoundException` ⇒ gone; delete-share
`FileStream` reads); steal via `File.Move` with the non-file guard; release via
`File.Delete` + retry + leftover. Port interop T4/T5 fabrication (file + first
line) and keep every behavioural test as-is. New interop tests (pwsh required,
so they live here): (a) **blocked release** — a pwsh process holds the lock
file with `FileShare.Read` while the bash holder releases ⇒ deterministic
leftover path, rc 1, stale-window recovery (makes TODO #30 testable); (b)
blocked *steal* — same holder pattern against a stale lock ⇒ stealer re-polls,
acquires after the handle closes. Done = interop suite green.

**Phase 3 — integration suite + full matrix.**
Expected to pass nearly unchanged (it uses defaults and `-e` assertions); run
it, fix fallout, then run all three suites ×3 back-to-back on the loaded
machine (the historical flake-finder). Done = 3×3 green runs.

**Phase 4 — docs, TODO, linters.**
README "How it works" + docs/git-commit-lock.md "How the lock works" / port
sections rewritten (mkdir→O_EXCL file, token-as-content, floor rationale now
file-based, release/steal text); delete the partial-rm/rename-aside/`.new.*`
prose; update the TODO-main.md items per the table below; re-run shellcheck +
PSScriptAnalyzer (items 48/49). Done = docs describe only the file protocol;
no stale "lock dir(ectory)" wording outside the changelog.

## TODO-main.md impact (by item number)

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
- **Performance pass (53–56, landed after the plan's first draft): fold into
  the rewrite.** 53 (lazy gitdir) and 54 (builtin hot-forks) touch exactly the
  code Phases 1–2 rewrite — apply them as part of the port rather than twice;
  55 (marker-polling) and 56 (`WAITING` log line) land with the suite ports in
  Phases 1–3. If 56 lands here, its log line is included in the Logging
  section below.
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
process, like the mtime-probe warning). The blocked-release retry logs its
final leftover WARNING exactly as today. If TODO #56 lands with this change
(recommended above), the contended path also gains its one-line `WAITING`
entry on the first blocked poll.
