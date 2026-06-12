#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # info-level, deliberate: library functions
# run inside conditions/`||` chains BY DESIGN — the sourced API must behave
# identically with and without the caller's errexit, so every call site
# handles failure explicitly (see the "Strict mode" note above the source
# guard) and return values are never silently load-bearing.
# shellcheck disable=SC2249  # info-level, deliberate: `case` without a
# default is the idiom here — "no match" means "leave the value/state as-is".
#
# git-commit-lock.sh — the git-commit-lock mutex (bash implementation).
# Reachable at runtime as ~/.local/bin/git-commit-lock.sh
# (symlinked there by this repo's install.sh).
#
# Portable, flock-free mutex that serialises git's shared index/HEAD when
# several agents commit into the SAME working tree at once. The tool automates
# only the lock — the git steps themselves (what to stage, what to commit) are
# done MANUALLY by the agent, under this lock. Suggested agent operating rules
# live in README.md ("Suggested agent instructions"); the design rationale is
# in docs/git-commit-lock.md.
#
# WHY THIS EXISTS
#   git has ONE index (.git/index, or .git/worktrees/<wt>/index) and ONE HEAD
#   per working tree. A main agent and the sub-agents it spawns all share that
#   one tree — sub-agents do NOT get their own worktree — so even when the
#   top-level workflow uses worktrees, concurrent stage+commit still races
#   .git/index.lock and can blend half-staged work. This serialises that step.
#
#   `flock` is not portably available (absent on macOS, and on many Windows
#   Git-Bash/Cygwin setups), so we use classic portable primitives instead:
#     * acquire -> create a lock FILE with O_CREAT|O_EXCL (here: a `set -C`
#                  noclobber redirect — one open+write+close), whose CONTENT
#                  is the ownership token. Atomic create-or-fail on POSIX and
#                  NTFS; exactly one creator wins.
#     * steal   -> CLAIM-SERIALIZED: to steal a stale lock you must first
#                  win an O_EXCL CLAIM file
#                  (`${LOCK}.next`) carrying your own token; the claim IS the
#                  next lock — it is touched fresh and renamed OVER the stale
#                  lock in one atomic rename(2) replace (ghost destroyed +
#                  live lock installed in one op; no path-absent window —
#                  probe R1). See THE STEAL PROTOCOL below.
#
# LOCK FILE FORMAT (UTF-8, no BOM, LF; shared wire format with the ps1 port)
#     line 1: <token>            load-bearing: how lock_release detects theft.
#                                MUST start "tok." — the steal's content guard
#                                keys on that prefix, so it is wire format,
#                                binding on every implementation.
#     line 2: pid=<pid> host=<host>   informational (the STALE log line only).
#   Readers take line 1 and strip trailing CR/whitespace; they tolerate a
#   missing line 2 and an entirely empty file. Because creation and the token
#   write are ONE redirect, two states a multi-step acquire would risk cannot
#   exist: there is no acquirer-died-before-metadata orphan with unreadable
#   ownership (a crash between create and write leaves an EMPTY file with a
#   valid mtime, which ages into the normal staleness lane), and there is no
#   partially-failed multi-object cleanup at release (release is one unlink).
#
# CLAIM FILE (`${AGENT_LOCK_PATH}.next`)
#   Identical wire format, the CLAIMANT'S OWN token, written through the
#   creating O_EXCL redirect exactly like the lock — so the empty-file
#   crash-orphan lane and the mtime floor apply to it identically (a
#   sub-floor claim mtime means "unsettled, treat as just-created", never
#   "ancient, clear"). The claim path also gets the lock path's PRE-CREATE
#   TYPE GUARD: a noclobber `>` onto an existing FIFO blocks in open(2), so
#   omitting the guard on the claim path would be a HANG, not a warning.
#   Because rename preserves the source's mtime (probe R2), the installed
#   lock's staleness clock after a steal IS the claim's mtime — which is why
#   the protocol touches the claim immediately before the rename (the new
#   holder's lease starts ~now, not at claim-create time).
#
# STALENESS
#   Judged by the lock FILE's own mtime, stamped by the creating write. A lock
#   older than AGENT_LOCK_STALE_SECS (default 300s) is assumed crashed and may
#   be stolen, so one dead agent can never wedge the others forever. Two
#   defences are load-bearing here, both grounded in probes on plain files:
#     * the mtime FLOOR (946684800 = 2000-01-01): a freshly created file can
#       transiently report FILETIME zero (1601) to an observer on Windows;
#       sub-floor means "unsettled, wait", never "ancient, steal";
#     * the empty/unreadable READ RETRIES: the create->write gap of a rival is
#       observable (probe F), so token reads retry with escalating backoff
#       before classifying (the shared schedule lives at _lock_cur_token and
#       the ps1 port's Lock-ReadCurToken — keep them in lock-step).
#
# THE STEAL PROTOCOL (claim-serialized)
#   A poll that judges the lock stale (regular file, lock-shaped content,
#   plausible mtime >= floor, age >= AGENT_LOCK_STALE_SECS) runs:
#     1. CLAIM: O_EXCL-create `${LOCK}.next` with a FRESH PER-ATTEMPT token.
#        Create fails => someone else is stealing: check the CLAIM's own
#        staleness (below), keep waiting.
#     2. RE-VERIFY the lock still stale under the claim (content + mtime +
#        floor + shape, judged fresh).
#     3. Ordered install sequence:
#        3.1 CLAIM RECHECK: re-read `${LOCK}.next` — must carry OUR token and
#            be younger than AGENT_LOCK_CLAIM_STALE_SECS (a long-suspended
#            claimant must not act on a claim a waiter may already have
#            judged stale). Gone/foreign -> discovery + re-poll; ours but
#            overaged -> token-checked deletion + CLAIM-ABORT (contested) +
#            discovery; unreadable -> leave it (ages out) + leaked-token
#            memory (below).
#        3.2 TOUCH the claim — NON-creating: `touch -c --` followed by an
#            explicit [ -e ] existence check. `touch -c missing` exits 0
#            (POSIX, probe R3) so the exit code carries NO gone signal; only
#            the explicit check does. A creating touch would resurrect a
#            vanished claim as a fresh empty `${LOCK}.next` blocking every
#            rival claim until it aged out, and mask the gone signal the
#            discovery rule keys on. The touch makes the installed lock's
#            lease start ~now (probe R2: rename preserves the source mtime).
#        3.3 RE-VERIFY the lock still stale (as step 2).
#        3.4 RENAME-OVER: the claim is renamed over the lock (atomic replace;
#            `mv -T` where supported, see _lock_rename_over) and the normal
#            acquire read-back verification runs (must find our own token).
#     4. Not confirmed at step 2/3.3 -> token-checked deletion of our claim,
#        the final discovery read, then the lane outcome: lock GONE ->
#        CLAIM-ABORT (gone), do NOT rename onto the absent path (that lane
#        belongs to the normal create race); lock FRESH -> CLAIM-ABORT
#        (fresh), keep waiting. Either way the "fresh" lock may be OUR OWN
#        claim installed by a rival's rename — the discovery read decides.
#
#   TOKEN-CHECKED CLAIM DELETION (global rule): every "delete our claim"
#   path reads the claim first and unlinks ONLY if line 1 is our token.
#   Gone/foreign at the read -> leave it (a rival's live claim is never
#   touched); unlink hitting ENOENT after a passing read is NOT an error
#   (routes into the discovery read); unreadable after the ladder, or an
#   unlink that FAILS with the file still present (a no-delete-share
#   handle) -> the claim is LEAKED: its token joins the leaked-token
#   memory. Never blind-unlink the claim path.
#
#   OWNERSHIP DISCOVERY (global rule): a rival's rename can install OUR
#   claim file as the lock while we are anywhere past the claim create. So
#   after a claim attempt, EVERY exit that does not end in a successful
#   rename performs, as its final act — after any claim-deletion attempt,
#   regardless of which anomaly was observed — one read of the lock path's
#   line 1. Our claim token there => we HOLD the lock (per-attempt token
#   uniqueness makes this conclusive); otherwise the lane's outcome stands.
#   A miss is a true miss only on exits that installed the claim or
#   verifiably unlinked it — the three leave-it-unverified exits above feed
#   the leaked-token memory instead, which turns the one-shot read into
#   continuous discovery for exactly those lanes.
#
#   LEAKED-TOKEN MEMORY (global rule): an in-process list of attempt tokens
#   whose claim file was left in place without a verifiable unlink (exactly
#   three feeders: recheck-unreadable, deletion-read-unreadable,
#   deletion-unlink-blocked-while-present). While non-empty, every poll that
#   observes a lock at the lock path also reads its line 1; a LISTED token
#   there means a rival installed our leaked claim -> adopt it as the hold
#   token (the entry drops; the leak is resolved) and HOLD. The set persists
#   for the LIFETIME of the acquire — through a successful hold and into
#   release: at release, a lock token that is not our hold token but IS in
#   the set is OUR installed leaked claim — it is unlinked (with the
#   ours-path boundary re-read + bounded-retry + LEFTOVER behaviour) and the
#   release classifies as the stolen-mid-hold 98 (our actual hold WAS
#   displaced). Entries drop only on verifiable resolution (adoption, a
#   verified unlink, or a gone/foreign claim observation followed by one
#   lock read — and that lock read must be CONCLUSIVE: a different readable
#   token or a definitively absent path; our token there, or a lock present
#   but unreadable/empty, keeps the entry pending); release and the 97 exit
#   run one best-effort resolution pass over pending entries; entries still
#   pending when the arc ends are residual-5 class (see KNOWN RESIDUAL
#   RACES).
#
#   TRAP-TIME CLAIM CLEANUP (global rule; best-effort): the EXIT/INT/TERM
#   handlers are installed at acquire START (not at hold) and carry a
#   claim-window mode: a trappable exit while a claim attempt is in flight
#   performs the token-checked claim deletion (ONE bounded retry if the
#   unlink fails with the file still present — an exiting trap cannot wait
#   out a blockage) and then the final discovery read; a discovery-HOLD
#   inside the trap is released per normal trap semantics. If the claim
#   stays present-and-ours-but-undeletable, the process exits leaving it
#   (residual-5 class, bounded <= CLAIM_STALE after ageing). NO trap path
#   runs lock-release semantics (98) on a mere claim — a claim is not a
#   hold. A signal landing mid-claim-create can leave an empty/torn claim
#   the token-checked deletion correctly refuses: it ages out <=
#   CLAIM_STALE (a steals-only delay). Same class: a claim create failing
#   AFTER line 1 reached disk (e.g. ENOSPC mid-write) leaves an own-token
#   claim the process doesn't know it wrote — the same bounded residual-5
#   outcome if a rival's rename ever installs it.
#
#   PER-ATTEMPT TOKENS (global rule): a fresh token is generated for EVERY
#   create and claim attempt — never once per acquire. The winning attempt's
#   token becomes the hold token; release verifies against it. This makes
#   own-token-at-lock a true equivalence ("THIS attempt's file was
#   installed"): an own-token lock abandoned by a failed read-back can never
#   satisfy a later discovery read or alias a later attempt.
#
#   CLAIM STALENESS: a claim older than AGENT_LOCK_CLAIM_STALE_SECS (default
#   60 — claims are held for milliseconds; 60s says "claimant crashed"),
#   judged by the same mtime+floor rules, and claim-shaped (empty, or a
#   "tok."-prefixed line 1) is unlinked by any waiter, which then re-races
#   the claim create. The never-steal wrong-type guards (with the
#   two-consecutive-poll confirmation) apply to the claim path exactly as to
#   the lock path, with PER-PATH classifier and warn-once state. A crashed
#   claimant therefore delays only STEALS by <= the claim window; normal
#   acquisition on a free lock path is never blocked by a claim.
#
# ACQUIRE VERIFICATION (never repair by overwriting)
#   After winning the create — or completing a steal's rename-over — the
#   acquirer re-reads line 1 from the path and claims the hold only if it
#   finds its own ATTEMPT token. Anything else — foreign, empty, or gone
#   after the read ladder — means we cannot prove we hold the path (e.g. we
#   were suspended past the stale window and a waiter stole the path while a
#   successor re-created it): log loudly, treat as NOT acquired, re-enter
#   the wait loop. A "repair" overwrite would clobber the successor's
#   token and produce a silent, undetected double-hold; giving the lock up is
#   always safe (our own orphan ages into the steal lane and is reclaimed,
#   and per-attempt tokens mean it can never alias a later attempt's
#   read-back or discovery read).
#   This lane has no deterministic test (it needs fault injection to make a
#   winning create unreadable); like the read-retry ladders it is defence in
#   depth. Side effect: a verified read-back is what lets release treat a GONE
#   lock file as definitive theft (98) — our token provably WAS at the path.
#   No grace wait precedes the give-up: a steal installs by rename-over, so a
#   displaced lock is never moved aside and never comes back — there is
#   nothing to wait for.
#
# FAIL-OPEN CEILING + the holder's responsibility (important)
#   The stale window is a LEASE, and the file mtime is stamped once at create
#   and NOT refreshed while held. So a holder whose critical section runs
#   longer than AGENT_LOCK_STALE_SECS has its still-live lock stolen — the
#   lock "fails open". We do NOT prevent this with a background heartbeat
#   (keeps the tool a single synchronous script). Instead the contract is:
#   COMMITS MUST BE FAST (the golden rule — well under the window; git commits
#   should take seconds, not minutes), and a holder that was nonetheless too
#   slow DETECTS the theft when it returns: lock_release verifies the file
#   still carries our token and, if not, logs a loud WARNING and returns 98
#   instead of reporting success. Any steal that overlaps the holder's actual
#   git work happens before release and is therefore caught; a steal landing
#   after the work is benign. If you genuinely must run something slow under
#   the lock (e.g. a heavy pre-commit hook), raise AGENT_LOCK_STALE_SECS for
#   that invocation.
#
# KNOWN RESIDUAL RACES (detected, not silent)
#   The claim serializes stealers, so the displaced-live race of crash
#   recovery under contention (a straggler's steal robbing the recovery
#   winner — without serialization it fires near-certainly: probed 5/5 with
#   4 waiters on one ancient lock) is PREVENTED outright, with no
#   detect-and-repair machinery needed. What remains (residuals 1-6,
#   referenced by number throughout the code):
#     1. verify->rename gap: a live-slow holder releases between our final
#        re-verify (step 3.3) and our rename, and a waiter's create lands in
#        that same instant; our rename-over then replaces that fresh lock.
#        The displaced winner detects via the acquire read-back (if still
#        inside it) or at release (98). A few ms wide (the mtime stat is a
#        command substitution, mv is an exec) — far narrower than the whole
#        poll window an unserialized steal would expose.
#     2. recheck->rename gap: a clearer whose staleness read predates our
#        recheck can clear our claim and let a rival claim inside the
#        recheck->rename gap. Every such two-claimant interleaving is
#        SELF-HEALING per the ownership-discovery rule: exactly one claim
#        file ends up installed, its token's live owner discovers ownership
#        on whatever exit path it takes (discovery read or leaked-token
#        memory), everyone else reads a foreign token and backs off; any
#        displacement degrades into the detected-98 lane. No unowned orphan
#        is possible from a process actively inside an acquire/hold/release
#        arc (untrappable death and post-arc pending entries are residual 5).
#     3. lease accuracy: the installed lock's lease starts at the claim's
#        step-3.2 touch (rename preserves mtime). A claimant suspended
#        between touch and rename installs a correspondingly aged-mtime lock
#        (the shortfall is bounded by the touch->rename gap — ms when not
#        suspended). When a RIVAL renames our claim in (a discovery-HOLD),
#        the installed lock's age is the claim's age at the rival's rename —
#        worst case an instantly-stale install, self-healing via the next
#        steal, detected.
#     4. version skew: prevention holds only when ALL parties in a tree run
#        the claim protocol. Older releases stole with an unserialized
#        move-aside; a mixed-version tree degrades prevention to detection
#        (98) and can leave .dead.* litter current versions don't clean —
#        upgrade both implementations together.
#     5. untrappable death inside the claim window (SIGKILL, power loss) —
#        deliberately ACCEPTED, not prevented: the leftover claim can be
#        installed by a suspended rival's rename -> an unowned fresh lock
#        stalling waiters <= STALE, recovered by normal staleness; NO false
#        success anywhere (nobody believes they hold; the stall is the only
#        cost). The same bounded class covers: leaked-token-memory entries
#        still pending after the arc ends (97, clean release, or death) —
#        no discovery mechanism runs outside the arc; the owner's next
#        acquire can still adopt the token, and the arc-end resolution pass
#        narrows the window — and a trap-time claim unlink still
#        blocked-while-present after its one bounded retry. Why accepted:
#        same magnitude as the tool's FUNDAMENTAL accepted cost (a crashed
#        holder already stalls a full STALE window) at far lower
#        probability; the preventing alternative (capture-verify-install, a
#        two-rename compare-and-swap) would reintroduce crash litter at
#        private names plus an age-gated sweep to clean it, and was
#        rejected.
#     6. release-side: between the final token
#        re-read and the unlink, a boundary-stale steal + re-acquire slips
#        in, so our rm deletes the successor's live file; and the
#        release-retry gap (the D1 share-mode guarantee holds while the
#        handle is OPEN — it can close between our ~20ms delete retries).
#        Both need a hold that already overran the stale window; detected at
#        the displaced party's release (98). The release-path LEAKED-CLAIM
#        cleanup unlink shares this boundary class: its
#        immediately-before-unlink re-read backs off when a successor's
#        steal already replaced the leaked token, and the remaining
#        read->unlink gap is detected at the successor's read-back.
#   All residuals are DETECTED (or, for residual 5, bounded and
#   false-success-free): no silent lost update — the cost is a spurious
#   "redo" plus a transient double-hold or a bounded stall.
#
# ACCEPTED RESIDUALS (non-race, documented deliberately)
#   * A torn token write SHORTER than "tok." (e.g. "to"; reachable only via
#     ENOSPC/crash mid-write) is non-empty and non-prefixed, so it lands in
#     the never-steal NON-LOCK lane permanently: loud (the config warning
#     names the path), fixed by one manual `rm`. We trade that vanishing-rare
#     recovery for never deleting real user files at a typo'd path. The same
#     applies at the CLAIM path (it blocks steals, not acquisition).
#   * The converse: a stale USER file whose line 1 happens to start "tok." IS
#     stolen — the prefix is the whole wire test, deliberately (a fuller shape
#     check would bind the format harder for near-zero added protection).
#   * An actively-REWRITTEN user file at a typo'd path never ages into the
#     content guard, so it ends in 97 without a config warning (safety is
#     intact — nothing stolen or deleted; we just don't read content on every
#     poll). The same trade as the per-poll type guard avoids.
#   * FIFOs/devices/sockets at the lock path: bash refuses them all via the
#     pre-create type guard + `[ -f ]` steal guard — and the CLAIM path gets
#     the same guards with per-path state. The ps1 port on Unix has
#     no clean type probe for devices/sockets/FIFOs (they stat as size 0 and
#     take the empty-orphan lane there); that residual is documented in the
#     ps1 implementation — reference only here.
#   * Windows read-only attribute: it fails File.Delete/`rm` differently than
#     rename (bash `rm -f` clears it and succeeds; ps1's File.Delete fails
#     while File.Move would succeed). Nothing in the protocol ever sets
#     read-only; if something external does, the leftover warning fires and
#     the stale steal (a rename) recovers the path.
#   * Token-checked claim deletion resolves can't-prove cases by the harm
#     asymmetry, not by certainty: a claim we cannot READ is never unlinked
#     (deleting a rival's live claim aborts its steal; leaving an orphan
#     merely delays steals <= CLAIM_STALE) — the leaked-token memory keeps
#     the leaver's ownership discoverable. The deletion's own read->unlink
#     gap can in principle unlink a rival's JUST-created claim (clearer and
#     rival inside a microsecond window) — benign: the rival's recheck finds
#     its claim gone -> final discovery read -> it retries. No machinery is
#     added for this.
#   * No-`mv -T` platforms (BSD/macOS): the rename-over falls back to a
#     last-instant [ -d ] check + bare `mv`. A directory appearing at the
#     lock path inside that check->mv gap would have bare mv move the claim
#     INTO it (probe R4): the read-back then fails, the claimant re-polls,
#     and the wrong-type guard names the directory — no false success; the
#     claim file is left as litter inside the misconfigured directory.
#     Reaching this needs external interference creating a directory at the
#     lock path inside a ms window, on a platform without GNU mv.
#
# LOCK LOCATION
#   By default the lock and its log live in the repo's git dir
#   (`git rev-parse --absolute-git-dir`), e.g. <repo>/.git/commit.lock.
#   That is never tracked by git, and it auto-scopes to the exact index being
#   protected: every worktree has its own git dir (so independent worktrees get
#   independent locks), while all sub-agents sharing one checkout resolve the
#   same git dir and therefore share one lock — exactly what we want.
#
# CONFIG (all overridable via env; mainly for tests):
#   AGENT_LOCK_PATH        lock file path (default <gitdir>/commit.lock).
#                          The claim lives beside it at ${AGENT_LOCK_PATH}.next.
#   AGENT_LOCK_STALE_SECS  steal threshold in seconds vs file mtime (default
#                          300). Hard fail-open ceiling: keep it >> (max hold
#                          + any clock skew); no sub-5s windows outside tests.
#   AGENT_LOCK_CLAIM_STALE_SECS  claim ageout in seconds (default 60): a
#                          claim older than this is judged crashed and may be
#                          cleared by any waiter. Claims are normally held
#                          for milliseconds.
#   AGENT_LOCK_POLL_SECS   poll interval while waiting (default 2)
#   AGENT_LOCK_MAX_WAIT    safety cap on total wait (default 420; keep it >
#                          STALE + CLAIM_STALE so a crashed holder AND a
#                          crashed claimant can both be recovered before
#                          waiters give up — a warning is printed if it is
#                          not, gated on MAX_WAIT being left at its default)
#   AGENT_LOCK_LOG         log file (default <gitdir>/git-commit-lock.log)
#   STALE_SECS, CLAIM_STALE_SECS and MAX_WAIT must be positive integers,
#   POLL_SECS may be fractional; invalid values fall back to the default
#   with a stderr note (same rules in the ps1 port).
#
# PROBE RECORDS (this box: Git-Bash/MSYS on NTFS; see also the per-site
# probe citations through the code)
#   A     the noclobber failure message comes from bash itself, not printf
#         (stderr must be redirected on the SUBSHELL).
#   C/C1b a freshly created file can transiently report FILETIME zero (1601)
#         to an observer -> the mtime floor.
#   D1    a no-delete-share handle blocks our unlink AND a steal's rename
#         alike (the release-retry grounding).
#   F     a rival's create->write gap is observable (file exists, no content
#         yet) -> the escalating read-retry ladders.
#   R1    (2026-06-11) `mv` rename-over on NTFS: 400 atomic replaces, ZERO
#         absent reads, ZERO torn reads from a tight reader loop — the
#         no-path-absent-window property the steal rides on.
#   R2    (2026-06-11) rename preserves the SOURCE's mtime: the installed
#         lock's mtime == the claim's just-touched mtime (the lease rule).
#   R3    (2026-06-11) `touch -c` on a missing file exits 0 and creates
#         nothing (POSIX) — gone-detection MUST be the explicit [ -e ]
#         check, never the exit code.
#   R4    (2026-06-11) bare `mv` onto a directory moves the source INTO it
#         (POSIX mv semantics); GNU `mv -T` refuses (empty or not) — hence
#         the probed -T fast path + guarded fallback in _lock_rename_over.
#
# EXIT CODES (the published contract — do not repurpose)
#   `run` exits with the wrapped command's own exit code, EXCEPT three
#   reserved high codes:
#     96  usage error (bad/missing arguments, or `run` outside a git repo with
#         no AGENT_LOCK_PATH override) — the command was NEVER run. An
#         explicit `--help`/`-h` is NOT an error: usage on stdout, exit 0.
#     97  timed out waiting for the lock — the command was NEVER run
#     98  lock stolen mid-hold — the command RAN but was NOT serialised;
#         treat the work as failed and redo it under the lock
#   (A wrapped command that itself exits 96/97/98 is indistinguishable from
#   these; avoid those codes in wrapped commands.)
#   Sourced API: lock_acquire returns 97 on timeout and 1 on API misuse
#   (reentrant acquire); lock_release returns 98 if the lease was stolen
#   mid-hold (the file is GONE, or carries a non-empty FOREIGN token — both
#   definitive, because acquire's read-back verified our token at the path),
#   2 if the file still reads EMPTY after the retry ladder while present
#   (ownership unverifiable: that is the create->write window of a successor
#   after a boundary steal, or external truncation — not proof of theft;
#   `run` maps this to 1 only when the command itself succeeded, and keeps a
#   failing command's own exit code), and 1 if the lock file could not be
#   deleted (LEFTOVER: it is left behind; recovery needs the stale window to
#   elapse AND the blocking handle to close — the same handle blocks a
#   stealer's rename, so until then waiters re-poll and may reach 97).
#   The ps1 port returns the same verdicts for the same on-disk states.
#
# USAGE (two modes; pick one — both keep the critical section tiny)
#   1. Wrap your git in `run` (auto-releases; exit codes above):
#        ~/.local/bin/git-commit-lock.sh run -- bash -c '
#          git add -- path/to/file && git commit -m "msg"'
#   2. Source it and drive the lock yourself, in ONE shell invocation:
#        source ~/.local/bin/git-commit-lock.sh
#        lock_acquire || exit 1
#        git add -- path/to/file && git commit -m "msg"
#        lock_release || echo "WARNING: lock was lost; commit was not exclusive" >&2
#   Do the slow part (deciding what to stage, building a patch) OUTSIDE the lock.

# Strict mode is scoped to EXECUTED mode only: sourcing must not impose
# errexit/nounset/pipefail on the caller's shell. The library functions below
# are written to behave correctly with or without errexit in effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
fi

# --- time primitives (probed once at source time, not per call) --------------
# bash 4.2+ printf '%(fmt)T' formats time without forking `date` (a hot path:
# every poll and every log line wants the clock). macOS /bin/bash is 3.2,
# which lacks it — probe once and fall back to external `date` there.
_lock_t="$(printf '%(%s)T' -1 2>/dev/null || true)"
case "$_lock_t" in
  ''|*[!0-9]*)
    _lock_now()   { date +%s; }
    _lock_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
    ;;
  *)
    _lock_now()   { printf '%(%s)T' -1; }
    _lock_stamp() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }
    ;;
esac
unset _lock_t

# --- resolve defaults (git-dir aware, CWD-independent within the repo) -------
_lock_gitdir() { git rev-parse --absolute-git-dir 2>/dev/null || true; }
# Remember whether the caller chose the lock location explicitly: outside a
# repo, `run` refuses to guess (see CLI below), while sourcing keeps a CWD
# fallback (with a logged warning) so sourcing never explodes.
if [ -n "${AGENT_LOCK_PATH:-}" ]; then _LOCK_PATH_EXPLICIT=1; else _LOCK_PATH_EXPLICIT=0; fi
# Lazy gitdir resolution (perf): the `git rev-parse` fork exists only to
# DEFAULT the lock/log paths, so skip it entirely when both are explicit (the
# common test/sub-agent-override case). When only AGENT_LOCK_PATH is explicit
# the log still defaults into the git dir, so the resolution stays.
if [ "$_LOCK_PATH_EXPLICIT" = 1 ] && [ -n "${AGENT_LOCK_LOG:-}" ]; then
  _LOCK_GITDIR=""
else
  _LOCK_GITDIR="$(_lock_gitdir)"
fi
_LOCK_BASE="${_LOCK_GITDIR:-$PWD}"

AGENT_LOCK_PATH="${AGENT_LOCK_PATH:-$_LOCK_BASE/commit.lock}"
if [ -n "${AGENT_LOCK_MAX_WAIT:-}" ]; then _LOCK_MAXWAIT_EXPLICIT=1; else _LOCK_MAXWAIT_EXPLICIT=0; fi
AGENT_LOCK_STALE_SECS="${AGENT_LOCK_STALE_SECS:-300}"
AGENT_LOCK_CLAIM_STALE_SECS="${AGENT_LOCK_CLAIM_STALE_SECS:-60}"
AGENT_LOCK_POLL_SECS="${AGENT_LOCK_POLL_SECS:-2}"
AGENT_LOCK_MAX_WAIT="${AGENT_LOCK_MAX_WAIT:-420}"
AGENT_LOCK_LOG="${AGENT_LOCK_LOG:-$_LOCK_BASE/git-commit-lock.log}"

# Validate the numeric knobs once, at source time: a garbage POLL would
# busy-spin the create loop, a garbage STALE would silently disable stealing,
# and a garbage MAX_WAIT would break the timeout arithmetic. On bad input,
# note it on stderr and fall back to the default rather than failing.
_lock_check_num() {  # $1=name $2=value $3=default $4=int|frac -> prints value to use
  local v="$2" ok=1
  case "$4" in
    int)  case "$v" in ''|*[!0-9]*) ok=0;; esac ;;
    frac) case "$v" in ''|.|*[!0-9.]*|*.*.*) ok=0;; esac ;;
  esac
  # Reject zero (e.g. "0", "0.0"): every knob must be strictly positive. A
  # format-valid value is positive iff it contains a nonzero digit.
  if [ "$ok" = 1 ]; then case "$v" in *[1-9]*) ;; *) ok=0;; esac; fi
  if [ "$ok" = 1 ]; then
    printf '%s' "$v"
  else
    echo "git-commit-lock: ignoring invalid $1='$v' (need a positive number); using default $3" >&2
    printf '%s' "$3"
  fi
}
AGENT_LOCK_STALE_SECS="$(_lock_check_num AGENT_LOCK_STALE_SECS "$AGENT_LOCK_STALE_SECS" 300 int)"
AGENT_LOCK_CLAIM_STALE_SECS="$(_lock_check_num AGENT_LOCK_CLAIM_STALE_SECS "$AGENT_LOCK_CLAIM_STALE_SECS" 60 int)"
AGENT_LOCK_POLL_SECS="$(_lock_check_num AGENT_LOCK_POLL_SECS "$AGENT_LOCK_POLL_SECS" 2 frac)"
AGENT_LOCK_MAX_WAIT="$(_lock_check_num AGENT_LOCK_MAX_WAIT "$AGENT_LOCK_MAX_WAIT" 420 int)"

# Worst-case recovery now stacks BOTH ageouts: a crashed holder costs a full
# STALE window, and a crashed claimant on top costs a CLAIM_STALE window
# before the steal can complete — so a waiter needs MAX_WAIT > STALE +
# CLAIM_STALE to be guaranteed a recovery chance before giving up (defaults:
# 300 + 60 < 420). Warn only in the documented footgun case — knobs raised
# while MAX_WAIT was left at its default; a caller who set MAX_WAIT chose
# the relationship deliberately (test suites do this constantly). The
# stacked relation strictly subsumes a bare STALE >= MAX_WAIT check, so no
# separate warning for that case is needed.
if [ "$_LOCK_MAXWAIT_EXPLICIT" = 0 ] \
   && [ "$AGENT_LOCK_MAX_WAIT" -le $(( AGENT_LOCK_STALE_SECS + AGENT_LOCK_CLAIM_STALE_SECS )) ]; then
  echo "git-commit-lock: warning — AGENT_LOCK_MAX_WAIT ($AGENT_LOCK_MAX_WAIT, default) <= AGENT_LOCK_STALE_SECS ($AGENT_LOCK_STALE_SECS) + AGENT_LOCK_CLAIM_STALE_SECS ($AGENT_LOCK_CLAIM_STALE_SECS): waiters may time out before a crashed holder (and a crashed claimant) can be recovered; raise AGENT_LOCK_MAX_WAIT too" >&2
fi

_LOCK_HELD=0
# $HOSTNAME is set by bash itself; the `hostname` fork is only a fallback for
# the rare shell that did not populate it.
_LOCK_ME="pid=$$ host=${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
# The HOLD token: set by _lock_take_hold from the WINNING attempt's token
# (per-attempt tokens — see PER-ATTEMPT TOKENS in the header); release
# verifies the on-disk lock against it. Empty while not holding.
_LOCK_TOKEN=""
# Fresh-token generator state: every create and claim attempt gets its own
# token (pid + $RANDOM + epoch + an in-process sequence number, so two
# attempts inside one second can never collide). Command substitution would
# run the generator in a subshell and lose the sequence increment, so the
# generator sets _LOCK_NEWTOK instead of printing. The "tok." prefix is wire
# format (see LOCK FILE FORMAT above).
_LOCK_SEQ=0
_LOCK_NEWTOK=""
_lock_new_token() {
  _LOCK_SEQ=$((_LOCK_SEQ+1))
  _LOCK_NEWTOK="tok.$$.${RANDOM}.$(_lock_now).$_LOCK_SEQ"
}
# The claim path (set at acquire start: ${AGENT_LOCK_PATH}.next) and the
# token of the claim attempt currently in flight (non-empty exactly while a
# claim we created may exist on disk unresolved — the trap handlers key
# their claim-window cleanup on it).
_LOCK_CLAIM_PATH=""
_LOCK_CLAIM_TOKEN=""
# LEAKED-TOKEN MEMORY (see the header rule): space-separated list of attempt
# tokens whose claim file was left in place without a verifiable unlink.
# Almost always empty. Tokens contain no whitespace/glob characters, so
# word-splitting iteration is safe.
_LOCK_LEAKED=""
# The caller's EXIT/INT/TERM traps as they were before lock_acquire installed
# ours (saved via `trap -p`, restored by lock_release on every path, and by
# lock_acquire itself when it resolves without a hold).
_LOCK_SAVED_TRAP_EXIT=""
_LOCK_SAVED_TRAP_INT=""
_LOCK_SAVED_TRAP_TERM=""

_lock_log()  {
  # Dumb size cap: if the log has grown past ~1MB (it gains ~2 lines per
  # commit and nothing ever prunes it), start it over rather than rotating.
  if [ -f "$AGENT_LOCK_LOG" ] && [ "$(wc -c < "$AGENT_LOCK_LOG" 2>/dev/null || echo 0)" -gt 1048576 ] 2>/dev/null; then
    : > "$AGENT_LOCK_LOG" 2>/dev/null || true
    printf '%s [pid=%s] %s\n' "$(_lock_stamp)" "$$" "log exceeded 1MB; truncated" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
  fi
  printf '%s [pid=%s] %s\n' "$(_lock_stamp)" "$$" "$*" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
}

# Sourced outside a git repo without an explicit AGENT_LOCK_PATH: keep the CWD
# fallback (sourcing must never explode) but say so on STDERR — not via
# _lock_log, which would CREATE $PWD/git-commit-lock.log in whatever random
# directory the caller happened to be in (the warning is about the location
# being wrong; leaving a file there compounds the problem). Mirrors the ps1
# port's dot-source warning: stderr only, no file created.
if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_PATH_EXPLICIT" = 0 ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  echo "git-commit-lock: WARNING — not inside a git repository; defaulting the lock to $_LOCK_BASE/commit.lock (CWD). Set AGENT_LOCK_PATH to control this." >&2
fi

# Loud, once-per-process config warning for a non-lock object at the lock
# path (a directory — e.g. a leftover old-protocol dir lock or a typo like
# AGENT_LOCK_PATH=$HOME — a symlink, a device, or a regular file whose
# content is not lock-shaped). Such a path is NEVER stolen or deleted;
# waiters will reach 97 until a human fixes the path or removes the object.
# The warn-once flag is PER PATH (lock vs. claim — see the claim variant
# below): a shared flag would let a lock-path warning suppress a claim-path
# one, hiding the second misconfiguration.
_LOCK_NONLOCK_WARNED=0
_lock_warn_nonlock() {  # $1 = what is wrong with the object
  [ "$_LOCK_NONLOCK_WARNED" = 1 ] && return 0
  _LOCK_NONLOCK_WARNED=1
  echo "git-commit-lock: WARNING — $AGENT_LOCK_PATH exists but is not a lock file ($1). Refusing to steal or delete it; waiters will time out (97). If AGENT_LOCK_PATH is a typo, fix it; if this is a stray file or a leftover old-protocol lock directory, remove it by hand." >&2
  _lock_log "WARNING: non-lock object at lock path ($1) — never stolen; waiters reach 97 until it is removed by hand"
}

# The claim-path twin (per-path warn-once state, see above). A non-claim
# object squatting ${LOCK}.next blocks STEALS only — normal acquisition on a
# free lock path is unaffected — but a stale lock then wedges waiters to 97.
_LOCK_NONLOCK_WARNED_CLAIM=0
_lock_warn_nonlock_claim() {  # $1 = what is wrong with the object
  [ "$_LOCK_NONLOCK_WARNED_CLAIM" = 1 ] && return 0
  _LOCK_NONLOCK_WARNED_CLAIM=1
  echo "git-commit-lock: WARNING — $_LOCK_CLAIM_PATH exists but is not a claim file ($1). Refusing to delete it; stale locks cannot be stolen while it squats the claim path (waiters may time out, 97). If AGENT_LOCK_PATH is a typo, fix it; otherwise remove the object by hand." >&2
  _lock_log "WARNING: non-claim object at claim path ($1) — never deleted; steals are blocked until it is removed by hand"
}

# Best-effort single mtime probe (epoch secs) of an arbitrary path; prints
# empty if unreadable. Probe chain: GNU stat (-c %Y), then BSD/macOS stat
# (-f %m), then GNU date (-r FILE +%s; BSD date -r takes seconds, so it fails
# harmlessly there). The numeric guard rejects any probe that "succeeds" with
# non-epoch output (e.g. GNU stat -f's mount point).
_lock_stat_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" \
    || m="$(stat -f %m "$1" 2>/dev/null)" \
    || m="$(date -r "$1" +%s 2>/dev/null)" \
    || m=""
  case "$m" in ''|*[!0-9]*) m="";; esac
  printf '%s' "$m"
}

# mtime of the lock file itself, stamped by the creating write — the
# staleness clock. Sets _LOCK_MTIME rather than printing: a
# command-substitution caller would run this in a SUBSHELL, where the
# warn-once flag below could never persist — the broken-stat warning would
# repeat on every poll. Empty if the file vanished mid-check. If every probe
# fails while the file EXISTS, staleness detection is broken on this system —
# crashed holders can then never be stolen — so say so loudly, once per
# process. The retry loop is anti-false-alarm: under contention the lock
# routinely vanishes (release/steal) between our probes and is re-created by
# the next holder, which would misdiagnose a healthy system, so only
# persistent failure on a present file counts.
_LOCK_MTIME_WARNED=0
_LOCK_MTIME=""
_lock_path_mtime() {
  local m="" present=0
  for _ in 1 2 3; do
    m="$(_lock_stat_mtime "$AGENT_LOCK_PATH")"
    [ -n "$m" ] && break
    # All probes failed: either the file vanished mid-probe (normal
    # contention; the caller treats empty as "unsettled" and re-loops) or
    # mtime is truly unreadable here. Retry only while the file is present.
    if [ -e "$AGENT_LOCK_PATH" ]; then present=1; else present=0; break; fi
  done
  if [ -z "$m" ] && [ "$present" = 1 ] && [ "$_LOCK_MTIME_WARNED" = 0 ]; then
    _LOCK_MTIME_WARNED=1
    echo "git-commit-lock: WARNING — cannot read the lock file's mtime on this system (tried 'stat -c %Y', 'stat -f %m', 'date -r'). Staleness detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges waiters until AGENT_LOCK_MAX_WAIT." >&2
    _lock_log "WARNING: lock-file mtime unreadable (all probes failed); staleness detection disabled"
  fi
  _LOCK_MTIME="$m"
}

# Token currently recorded in the lock file — line 1, whoever holds it now —
# or empty. Retries with ESCALATING backoff while the read comes back empty
# but the file still exists: the rival create->write gap is observable (probe
# F: the file can exist with no content yet), and on Windows a concurrent
# scanner can transiently fail the open (sharing violation) for hundreds of
# milliseconds; treating one misread as "stolen" would be a false alarm with
# a destructive remedy ("redo your commit"). An empty result with the file
# still present is classified at release as UNVERIFIABLE ownership (rc 2),
# never as proven theft. Retrying never hides a genuine theft: a real steal
# renames the file away, so a later successful read returns a DIFFERENT
# token (still a mismatch).
#
# SHARED RETRY SCHEDULE (keep in lock-step with the ps1 port's
# Lock-ReadCurToken): up to 8 read attempts with inter-attempt sleeps of
# 20/40/80/160/320/320/320 ms — ~1.26s total budget, enough to ride out a
# sub-second transient (e.g. an AV scanner's no-delete-share open). The full
# ladder runs ONLY where a verdict hangs on the read — release verification,
# the acquire read-back, the claim recheck / token-checked deletion, and the
# discovery read — never inside the acquire poll loop (the steal content
# guard and the per-poll leaked-memory read are short reads), so a healthy
# lock costs one attempt and the poll cadence is unaffected.
_lock_read_tok() {  # $1 = path; $2 = max read attempts (default 8 = the full ladder)
  local p="$1" t="" i=0 max="${2:-8}"
  set -- 0.02 0.04 0.08 0.16 0.32 0.32 0.32   # the shared backoff schedule
  while :; do
    t=""
    # NB: 2>/dev/null BEFORE the input redirect — a failed open's error
    # message is emitted by the shell at the point of failure, so stderr
    # must already be redirected when the open is attempted.
    { IFS= read -r t || true; } 2>/dev/null < "$p" || true
    t="${t%"${t##*[![:space:]]}"}"   # strip trailing CR/whitespace (CRLF tolerance)
    [ -n "$t" ] && break
    [ -e "$p" ] || break   # file gone: genuinely no token
    i=$((i+1)); [ "$i" -ge "$max" ] && break
    sleep "${1:-0.32}"; [ "$#" -gt 0 ] && shift
  done
  printf '%s' "$t"
}
_lock_cur_token() {  # full-ladder read (8 attempts) of the lock path
  _lock_read_tok "$AGENT_LOCK_PATH" 8
}

# --- leaked-token memory (see the header rule) -------------------------------
# _LOCK_LEAKED is a space-separated token list; tokens are
# whitespace/glob-free by construction, so unquoted iteration is deliberate.
_LOCK_LEAK_WARNED=0
_lock_leaked_add() {  # $1 = attempt token; $2 = which feeder lane
  _LOCK_LEAKED="${_LOCK_LEAKED:+$_LOCK_LEAKED }$1"
  _lock_log "LEAKED-CLAIM ($2): claim tok=$1 left in place without a verifiable unlink — added to the leaked-token memory; polls will watch the lock path for it"
  if [ "$_LOCK_LEAK_WARNED" = 0 ]; then
    _LOCK_LEAK_WARNED=1
    echo "git-commit-lock: warning — a claim file of ours could not be verified/deleted ($2); its token is remembered and ownership stays discoverable (see the lock log)" >&2
  fi
}
_lock_leaked_member() {  # $1 = token -> 0 iff listed
  case " $_LOCK_LEAKED " in *" $1 "*) return 0;; esac
  return 1
}
_lock_leaked_drop() {  # $1 = token
  local out="" t
  # shellcheck disable=SC2086  # deliberate word-split of the token list
  for t in $_LOCK_LEAKED; do
    [ "$t" = "$1" ] || out="${out:+$out }$t"
  done
  _LOCK_LEAKED="$out"
}
# Is leaked token $1 verifiably RESOLVED at the lock path? Used after the
# claim-side resolution (a verified unlink, or a gone/foreign observation)
# to decide whether the entry may DROP. Three-way, because _lock_read_tok
# returns empty for BOTH "gone" and "present-but-unreadable/empty" — the
# existence check after an empty read is what separates them:
#   * a DIFFERENT readable token, or the path definitively absent -> the
#     leaked token sits at NEITHER path and can never reappear: resolved
#     (rc 0, the caller drops the entry);
#   * OUR token there -> installed by a rival's rename: NOT resolved (the
#     entry stays pending; the owner's next acquire can adopt it);
#   * present but unreadable/empty after the read -> INCONCLUSIVE: the read
#     proves nothing about whose token is installed, so the entry MUST stay
#     pending (dropping here could orphan an installed own-token lock with
#     nothing left watching for it).
_lock_leaked_lock_resolved() {  # $1 = leaked token -> 0 iff resolved
  local lk; lk="$(_lock_read_tok "$AGENT_LOCK_PATH" 1)"
  if [ -n "$lk" ]; then
    [ "$lk" != "$1" ]
    return
  fi
  ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]
}

# Arc-end best-effort resolution pass (run at release and at the 97 exit):
# for each pending entry, one token-checked look at the CLAIM file — the
# blocking handle may have closed by now. A verified unlink, or a
# gone/foreign observation, resolves the entry — each followed by one
# lock-path line-1 read before the drop (gone-from-.next may mean
# installed-at-lock; an entry whose token sits at the LOCK path stays
# pending: the owner's next acquire can adopt it; a lock that is present
# but unreadable at that read is INCONCLUSIVE and also keeps the entry —
# see _lock_leaked_lock_resolved). Any failure leaves the entry pending —
# no waiting, no retry loops.
_lock_leaked_resolve_pass() {
  [ -n "$_LOCK_LEAKED" ] || return 0
  local t ct
  # shellcheck disable=SC2086  # deliberate word-split of the token list
  for t in $_LOCK_LEAKED; do
    ct="$(_lock_read_tok "$_LOCK_CLAIM_PATH" 1)"
    if [ "$ct" = "$t" ]; then
      # Still ours at the claim path: try the unlink (token-checked, single
      # best-effort attempt).
      if rm -f -- "$_LOCK_CLAIM_PATH" 2>/dev/null && ! [ -e "$_LOCK_CLAIM_PATH" ]; then
        if _lock_leaked_lock_resolved "$t"; then
          _lock_leaked_drop "$t"
          _lock_log "leaked-token memory: resolved tok=$t (claim unlinked at arc end)"
        fi
      fi
    elif [ -n "$ct" ] || { ! [ -e "$_LOCK_CLAIM_PATH" ] && ! [ -L "$_LOCK_CLAIM_PATH" ]; }; then
      # Foreign-tokened, or verifiably gone: the leak is resolved UNLESS the
      # token was installed at the lock path meanwhile, or the lock read is
      # inconclusive (present but unreadable).
      if _lock_leaked_lock_resolved "$t"; then
        _lock_leaked_drop "$t"
        _lock_log "leaked-token memory: resolved tok=$t (claim gone/foreign at arc end)"
      fi
    fi
    # present-but-empty/unreadable claim, blocked unlink, token-at-lock, or
    # an inconclusive lock read: leave the entry pending (residual-5 class
    # once the process exits).
  done
}

# Restore the caller's traps exactly as they were before lock_acquire: re-arm
# each saved trap, or reset to the default disposition when there was none.
# (Without this, a sourcing caller's own traps would be silently replaced and
# the shell would stay TERM/INT-immune after release.)
_lock_restore_traps() {
  if [ -n "$_LOCK_SAVED_TRAP_EXIT" ]; then eval "$_LOCK_SAVED_TRAP_EXIT"; else trap - EXIT; fi
  if [ -n "$_LOCK_SAVED_TRAP_INT" ];  then eval "$_LOCK_SAVED_TRAP_INT";  else trap - INT;  fi
  if [ -n "$_LOCK_SAVED_TRAP_TERM" ]; then eval "$_LOCK_SAVED_TRAP_TERM"; else trap - TERM; fi
  _LOCK_SAVED_TRAP_EXIT=""; _LOCK_SAVED_TRAP_INT=""; _LOCK_SAVED_TRAP_TERM=""
}

# Extract the command string from a saved `trap -p` line ("trap -- 'cmd' SIG").
# A shell function shadows the trap builtin for the eval, so bash's own quoting
# is reused instead of hand-parsing.
_lock_saved_trap_cmd() {
  [ -n "${1:-}" ] || return 0
  # shellcheck disable=SC2329,SC2317
  # Invoked indirectly: the eval of the saved `trap -p` line below calls this
  # shadow function (SC2317 is the older linter versions' code for it).
  trap() { printf '%s' "$2"; }
  eval "$1"
  unset -f trap
}

# --- steal-protocol helpers ---------------------------------------------------

# Claim the hold: adopt the winning ATTEMPT token as the hold token. ONE
# helper for all three acquisition paths — create read-back, steal
# rename-over, and discovery-HOLD — so every hold runs the same HELD/trap
# machinery (the handlers were installed at acquire start and stay armed
# through the hold; lock_release restores them).
_lock_take_hold() {  # $1 = the winning attempt token
  _LOCK_TOKEN="$1"
  _LOCK_CLAIM_TOKEN=""
  _LOCK_HELD=1
  _lock_log "ACQUIRED ($_LOCK_ME tok=$_LOCK_TOKEN)"
}

# The OWNERSHIP-DISCOVERY read (see the header rule): the unconditional
# final act of every post-claim-create exit that did not end in a successful
# rename. One read of the lock path's line 1 (full ladder — a verdict hangs
# on it); our attempt token there means a rival's rename installed OUR claim
# as the lock => we hold it. Returns 0 iff the hold was taken.
_lock_discover() {  # $1 = attempt token
  local rb; rb="$(_lock_cur_token)"
  if [ -n "$rb" ] && [ "$rb" = "$1" ]; then
    _lock_log "DISCOVERY-HOLD: our claim (tok=$1) was installed at the lock path by a rival's rename — taking the hold"
    _lock_take_hold "$1"
    return 0
  fi
  return 1
}

# Classify the claim file against OUR attempt token. Sets _LOCK_CR_STATE to
# one of: ours | gone | foreign | unreadable, and _LOCK_CR_TOK to the token
# read (empty unless readable). "foreign" includes a present-but-EMPTY claim:
# our claim's content write was verified by the creating redirect, so an
# empty file is not ours — it is a rival's mid-create window or external
# truncation; either way it is left alone (it ages out). "unreadable" means
# present, non-empty, but the full read ladder came back blank (a sharing
# violation): we can NOT verify the claim is not ours, so callers must treat
# it as a possible leak (see _lock_claim_delete / the recheck).
_LOCK_CR_STATE=""
_LOCK_CR_TOK=""
_lock_claim_state() {  # $1 = our attempt token
  local t; t="$(_lock_read_tok "$_LOCK_CLAIM_PATH" 8)"
  _LOCK_CR_TOK="$t"
  if [ -n "$t" ]; then
    if [ "$t" = "$1" ]; then _LOCK_CR_STATE="ours"; else _LOCK_CR_STATE="foreign"; fi
  elif ! [ -e "$_LOCK_CLAIM_PATH" ] && ! [ -L "$_LOCK_CLAIM_PATH" ]; then
    _LOCK_CR_STATE="gone"
  elif ! [ -s "$_LOCK_CLAIM_PATH" ]; then
    _LOCK_CR_STATE="foreign"
  else
    _LOCK_CR_STATE="unreadable"
  fi
}

# TOKEN-CHECKED CLAIM DELETION (see the header rule): read first, unlink
# only if line 1 is OUR token; never blind-unlink the claim path. Sets
# _LOCK_CD_STATE to: deleted | gone | foreign | leaked-unreadable |
# leaked-blocked. The two leaked-* outcomes append the token to the
# leaked-token memory (the claim stayed in place without a verifiable
# unlink, so the one-shot discovery read alone is not conclusive). An
# unlink hitting ENOENT after the passing read (rm -f masks it) is NOT an
# error — the claim left the path either way, and the discovery read that
# every caller runs next decides whether it left INTO the lock path.
_LOCK_CD_STATE=""
_lock_claim_delete() {  # $1 = attempt token; $2 = bounded retries on a blocked unlink (0 normal, 1 in traps)
  local tok="$1" retries="${2:-0}" try=0
  _lock_claim_state "$tok"
  case "$_LOCK_CR_STATE" in
    gone)    _LOCK_CD_STATE="gone";    return 0 ;;
    foreign) _LOCK_CD_STATE="foreign"; return 0 ;;
    unreadable)
      _LOCK_CD_STATE="leaked-unreadable"
      _lock_leaked_add "$tok" "deletion-read-unreadable"
      return 0 ;;
  esac
  # Ours: unlink, with the caller's bounded retry budget on a blocked unlink
  # (a no-delete-share handle can refuse the delete while the file stays).
  while :; do
    if rm -f -- "$_LOCK_CLAIM_PATH" 2>/dev/null; then
      _LOCK_CD_STATE="deleted"; return 0
    fi
    if ! [ -e "$_LOCK_CLAIM_PATH" ]; then
      _LOCK_CD_STATE="deleted"; return 0   # vanished mid-try: same as ENOENT
    fi
    [ "$try" -ge "$retries" ] && break
    try=$((try+1))
    sleep 0.05
  done
  _LOCK_CD_STATE="leaked-blocked"
  _lock_leaked_add "$tok" "deletion-unlink-blocked-while-present"
  return 0
}

# Re-judge the LOCK's staleness fresh (the step-2 / step-3.3 re-verify):
# type, mtime + floor, age, content shape. Sets _LOCK_LV_STATE to one of:
#   stale     confirmed stale (and _LOCK_LV_LINE2 for ghost attribution)
#   gone      path absent
#   fresh     not confirmable as stale (young mtime, sub-floor/unsettled,
#             unreadable mtime or content — never steal what we can't prove)
#   wrongtype not a regular file, or content not lock-shaped
_LOCK_LV_STATE=""
_LOCK_LV_LINE2=""
_lock_verify_stale() {
  _LOCK_LV_STATE=""; _LOCK_LV_LINE2=""
  if ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
    _LOCK_LV_STATE="gone"; return 0
  fi
  if ! [ -f "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
    _LOCK_LV_STATE="wrongtype"; return 0
  fi
  local mt age
  _lock_path_mtime; mt="$_LOCK_MTIME"
  if [ -z "$mt" ]; then
    # Vanished mid-probe, or mtime unreadable while present: not provably
    # stale either way.
    if [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
      _LOCK_LV_STATE="fresh"
    else
      _LOCK_LV_STATE="gone"
    fi
    return 0
  fi
  # shellcheck disable=SC2335  # the negated form is load-bearing: a non-numeric
  # or empty $mt makes the test itself FAIL, which `!` routes into the sub-floor
  # lane — the -le rewrite would route read errors to "settled" instead
  if ! [ "$mt" -gt 946684800 ] 2>/dev/null; then
    _LOCK_LV_STATE="fresh"; return 0      # sub-floor: unsettled, never stale
  fi
  age=$(( $(_lock_now) - mt ))
  if [ "$age" -lt "$AGENT_LOCK_STALE_SECS" ]; then
    _LOCK_LV_STATE="fresh"; return 0
  fi
  # Content shape (one open; line 2 is the ghost attribution for the log).
  local line1="" line2="" rdrc=0
  { IFS= read -r line1 || rdrc=$?; IFS= read -r line2 || true; } 2>/dev/null < "$AGENT_LOCK_PATH" || rdrc=$?
  line1="${line1%"${line1##*[![:space:]]}"}"
  line2="${line2%"${line2##*[![:space:]]}"}"
  if [ -n "$line1" ]; then
    case "$line1" in
      tok.*) _LOCK_LV_STATE="stale" ;;
      *)     _LOCK_LV_STATE="wrongtype" ;;
    esac
  elif ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
    _LOCK_LV_STATE="gone"
  elif ! [ -s "$AGENT_LOCK_PATH" ]; then
    _LOCK_LV_STATE="stale"                 # the empty crash-orphan lane
  elif [ "$rdrc" -ne 0 ]; then
    _LOCK_LV_STATE="fresh"                 # unreadable content: not provable
  else
    _LOCK_LV_STATE="wrongtype"             # non-empty but blank line 1
  fi
  _LOCK_LV_LINE2="$line2"
}

# Atomic rename-over of the claim onto the lock path. Bare `mv` onto a
# DIRECTORY destination moves the source INTO it (probe R4) — exactly the
# wrong thing — so use GNU `mv -T` (refuses any directory destination) where
# available, probed once per process via a temp-dir micro-rename; on
# platforms without it (BSD/macOS) fall back to a last-instant [ -d ] guard
# + bare mv (residual documented in ACCEPTED RESIDUALS). Returns mv's rc.
_LOCK_MVT=""   # "" = unprobed; 1 = mv -T supported; 0 = not
_lock_rename_over() {
  if [ -z "$_LOCK_MVT" ]; then
    local pd="${TMPDIR:-/tmp}/.gcl-mvt-probe.$$.$RANDOM"
    if mkdir -p "$pd" 2>/dev/null \
       && printf 'a' > "$pd/a" 2>/dev/null && printf 'b' > "$pd/b" 2>/dev/null \
       && mv -T -- "$pd/a" "$pd/b" 2>/dev/null && ! [ -e "$pd/a" ]; then
      _LOCK_MVT=1
    else
      _LOCK_MVT=0
    fi
    rm -rf "$pd" 2>/dev/null || true
  fi
  if [ "$_LOCK_MVT" = 1 ]; then
    mv -T -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null
  else
    [ -d "$AGENT_LOCK_PATH" ] && return 1
    mv -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null
  fi
}

# Trap-time claim cleanup (see the header rule; called by the EXIT/INT/TERM
# handlers when no hold exists): if a claim attempt is in flight, run the
# token-checked deletion with ONE bounded retry (an exiting trap cannot wait
# out a blockage), then the final discovery read — a discovery-HOLD here
# sets _LOCK_HELD, and the handler releases it per normal trap semantics.
# NO lock-release semantics (98) ever run on a mere claim.
_lock_claim_trap_cleanup() {
  [ -n "$_LOCK_CLAIM_TOKEN" ] || return 0
  local tok="$_LOCK_CLAIM_TOKEN"
  _LOCK_CLAIM_TOKEN=""
  _lock_claim_delete "$tok" 1
  if [ "$_LOCK_CD_STATE" = "leaked-blocked" ]; then
    _lock_log "trap: claim tok=$tok undeletable after the bounded retry; exiting leaving it (ages out <= ${AGENT_LOCK_CLAIM_STALE_SECS}s — residual-5 class)"
  fi
  _lock_discover "$tok" || true
  return 0
}

# EXIT while holding the lock: release it, then run the caller's ORIGINAL exit
# trap ourselves — bash does not re-run an EXIT trap re-armed during EXIT-trap
# execution, so lock_release's restore alone would silently skip it.
_lock_on_exit() {
  local rc=$? prev="$_LOCK_SAVED_TRAP_EXIT" cmd=""
  # Claim-window mode (handlers are armed from acquire START): no hold yet
  # means a claim attempt may be in flight — clean it up (token-checked, one
  # bounded retry) and run the discovery read; a discovery-HOLD falls
  # through into the normal release below.
  if [ "${_LOCK_HELD:-0}" != 1 ]; then
    _lock_claim_trap_cleanup
  fi
  if [ "${_LOCK_HELD:-0}" = 1 ]; then
    lock_release || true
  else
    # Exiting from the wait loop without a hold: the arc ends here — run the
    # best-effort resolution pass over any pending leaked entries and put
    # the caller's traps back.
    _lock_leaked_resolve_pass
    _lock_restore_traps
  fi
  cmd="$(_lock_saved_trap_cmd "$prev")"
  if [ -n "$cmd" ]; then eval "$cmd"; fi
  return "$rc"
}

# INT/TERM while holding the lock: release it, then RE-RAISE the signal so it
# is not swallowed. lock_release has restored the pre-acquire trap for the
# signal, so the re-raise lands on the caller's own handler (sourced mode) or
# the default disposition (executed `run` mode — the wrapper dies with the
# proper 128+N status, which is what a supervising watchdog needs to see).
# CAVEAT (INT): a SIGINT delivered to the run WRAPPER alone while its
# foreground child survives it is DISCARDED by bash before any trap runs
# (wait-and-cooperate: if the child didn't die of the INT, bash assumes the
# program handled it and carries on) — so this trap never fires on that
# delivery. A real Ctrl+C is delivered to the whole process GROUP, kills the
# child too, and DOES take this path; the TERM tests exercise the same
# release+re-raise machinery directly.
_lock_on_signal() {
  local sig="$1"
  # Claim-window mode: see _lock_on_exit. A discovery-HOLD inside the trap
  # sets _LOCK_HELD and is released per normal trap semantics right below.
  if [ "${_LOCK_HELD:-0}" != 1 ]; then
    _lock_claim_trap_cleanup
  fi
  if [ "${_LOCK_HELD:-0}" = 1 ]; then
    lock_release || true
  else
    _lock_leaked_resolve_pass
    _lock_restore_traps
  fi
  # Belt and braces: if our handler is somehow still armed (release was a
  # no-op), drop it so the re-raise cannot loop back here.
  case "$(trap -p "$sig")" in *_lock_on_signal*) trap - "$sig";; esac
  kill -s "$sig" "$$"
}

# Squatted-steal log damper (see lock_acquire): epoch of the last logged
# failed-steal attempt, 0 when the last attempt did not fail that way; and
# the per-attempt "may we log" verdict derived from it.
_LOCK_STEAL_FAIL_LAST=0
_LOCK_STEAL_LOG_OK=1

# The ordered install sequence (protocol steps 2-3.4), entered with OUR
# claim freshly created (token $1; _LOCK_CLAIM_TOKEN set by the caller).
# Returns 0 iff a hold was taken (rename-over read-back, or a
# discovery-HOLD); 1 means the attempt resolved without a hold and the
# caller falls through to the timeout check + poll sleep. Every exit that
# does not end in a successful rename runs its token-checked claim handling
# and then the FINAL DISCOVERY READ as its last act (the header's
# ownership-discovery rule — position-blind, unconditional).
_lock_steal_install() {  # $1 = this claim attempt's token
  local tok="$1" reason ghost rb cm cage
  # Step 2: re-verify the lock still stale under the claim. The claim
  # serializes stealers, so this judgment is fresh and exclusive — except
  # for the inventoried verify->rename residual (header, residual 1).
  _lock_verify_stale
  if [ "$_LOCK_LV_STATE" != "stale" ]; then
    case "$_LOCK_LV_STATE" in
      gone)      reason="gone" ;;       # do NOT rename onto the absent path:
                                        # that lane belongs to the create race
      wrongtype) reason="wrong-type" ;; # next poll's type guard classifies it
      *)         reason="fresh" ;;
    esac
    _lock_claim_delete "$tok" 0
    _lock_log "CLAIM-ABORT ($reason) tok=$tok (lock re-verify after claim: $_LOCK_LV_STATE)"
    _LOCK_CLAIM_TOKEN=""
    _lock_discover "$tok" && return 0
    return 1
  fi
  # Step 3.1: claim recheck — it must still carry OUR token and be YOUNGER
  # than CLAIM_STALE: a long-suspended claimant must not proceed on a claim
  # a waiter may already have judged stale (the stale-claim TOCTOU).
  _lock_claim_state "$tok"
  case "$_LOCK_CR_STATE" in
    gone)
      _lock_log "claim recheck: claim gone (tok=$tok) — a rival's rename may have installed it; discovery read"
      _LOCK_CLAIM_TOKEN=""
      _lock_discover "$tok" && return 0
      return 1 ;;
    foreign)
      # A clearer removed ours and a rival claimed (or a rival is
      # mid-create): leave the rival's claim alone. Ours may have been
      # installed at the lock BEFORE the rival claimed — discovery decides.
      _lock_log "claim recheck: foreign token '${_LOCK_CR_TOK:-<empty>}' at the claim (ours tok=$tok) — leaving it; discovery read"
      _LOCK_CLAIM_TOKEN=""
      _lock_discover "$tok" && return 0
      return 1 ;;
    unreadable)
      # We cannot verify the claim is ours OR not ours: leave it (it ages
      # out) and remember the token — the one-shot discovery read below is
      # NOT conclusive for this exit (the claim stays installable), so the
      # leaked-token memory keeps watching.
      _lock_leaked_add "$tok" "recheck-unreadable"
      _LOCK_CLAIM_TOKEN=""
      _lock_discover "$tok" && return 0
      return 1 ;;
  esac
  # Ours: overage check (same mtime + floor rules as everywhere; a
  # sub-floor or unreadable claim mtime means "unsettled, just created" —
  # never "ancient").
  cm="$(_lock_stat_mtime "$_LOCK_CLAIM_PATH")"
  if [ -n "$cm" ] && [ "$cm" -gt 946684800 ] 2>/dev/null; then
    cage=$(( $(_lock_now) - cm ))
    if [ "$cage" -ge "$AGENT_LOCK_CLAIM_STALE_SECS" ]; then
      # Overaged: a clearer may be acting on this claim right now — assume
      # contested; delete our own claim (token-checked) and back off.
      _lock_claim_delete "$tok" 0
      _lock_log "CLAIM-ABORT (contested) tok=$tok claim-age=${cage}s >= ${AGENT_LOCK_CLAIM_STALE_SECS}s"
      _LOCK_CLAIM_TOKEN=""
      _lock_discover "$tok" && return 0
      return 1
    fi
  fi
  # Step 3.2: NON-creating touch — the installed lock's staleness clock is
  # the claim's mtime (rename preserves it, probe R2), so the touch makes
  # the new holder's lease start ~now. `touch -c` on a missing file exits 0
  # (POSIX, probe R3): the exit code carries NO gone signal — only the
  # explicit existence check does. A creating touch would resurrect a
  # vanished claim as a fresh empty ${LOCK}.next blocking every rival claim
  # until it aged out, and mask the gone signal discovery keys on.
  touch -c -- "$_LOCK_CLAIM_PATH" 2>/dev/null || true
  if ! [ -e "$_LOCK_CLAIM_PATH" ]; then
    _lock_log "claim gone at touch (tok=$tok); discovery read"
    _LOCK_CLAIM_TOKEN=""
    _lock_discover "$tok" && return 0
    return 1
  fi
  # Step 3.3: re-verify the lock still stale, once more, immediately before
  # the rename.
  _lock_verify_stale
  if [ "$_LOCK_LV_STATE" != "stale" ]; then
    case "$_LOCK_LV_STATE" in
      gone)      reason="gone" ;;
      wrongtype) reason="wrong-type" ;;
      *)         reason="fresh" ;;
    esac
    _lock_claim_delete "$tok" 0
    _lock_log "CLAIM-ABORT ($reason) tok=$tok (lock re-verify before rename: $_LOCK_LV_STATE)"
    _LOCK_CLAIM_TOKEN=""
    _lock_discover "$tok" && return 0
    return 1
  fi
  ghost="${_LOCK_LV_LINE2:-?}"
  # Step 3.4: rename-over — ghost destroyed + our live lock installed in one
  # atomic op (probe R1: no path-absent window) — then the normal acquire
  # read-back verification. Attribution caveat: `ghost` names the last
  # VERIFIED occupant (the step-3.3 re-read); residual 1's verify->rename
  # gap means the object actually replaced could in principle differ.
  if _lock_rename_over; then
    _lock_log "STOLE-BY-CLAIM $AGENT_LOCK_PATH ghost=$ghost by $_LOCK_ME tok=$tok"
    _LOCK_STEAL_FAIL_LAST=0
    rb="$(_lock_cur_token)"
    if [ "$rb" = "$tok" ]; then
      _lock_take_hold "$tok"
      return 0
    fi
    _LOCK_CLAIM_TOKEN=""
    _lock_log "WARNING: acquire verification FAILED — steal rename completed but read-back found '${rb:-<empty-or-gone>}' (ours=$tok); not acquired, re-entering wait"
    echo "git-commit-lock: WARNING — acquire verification failed after a steal: the lock file did not read back our token; treating the lock as NOT acquired and waiting" >&2
    return 1
  fi
  # Rename failed: classify the failure.
  if ! [ -e "$_LOCK_CLAIM_PATH" ] && ! [ -L "$_LOCK_CLAIM_PATH" ]; then
    # Source (claim) gone at rename: the canonical discovery case — a
    # rival's rename may have installed OUR claim file as the lock.
    _lock_log "steal rename: claim (source) gone at rename (tok=$tok); discovery read"
    _LOCK_CLAIM_TOKEN=""
    _lock_discover "$tok" && return 0
    return 1
  fi
  if { [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; } \
     && { ! [ -f "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; }; then
    # Destination wrong-type (e.g. a directory appeared at the lock path):
    # refuse; the next poll's wrong-type guard classifies the object.
    # Shares the squatted-steal damper.
    _lock_claim_delete "$tok" 0
    if [ "$_LOCK_STEAL_LOG_OK" = 1 ]; then
      _lock_log "CLAIM-ABORT (rename-refused) tok=$tok — rename refused, non-file at the lock path; re-polling — repeats logged at most once per ${AGENT_LOCK_STALE_SECS}s"
      _LOCK_STEAL_FAIL_LAST="$(_lock_now)"
    fi
    _LOCK_CLAIM_TOKEN=""
    _lock_discover "$tok" && return 0
    return 1
  fi
  # Blocked: rename refused with the lock file still present (a
  # no-delete-share handle on the ghost — it blocks rename exactly like the
  # release unlink, probe D1 — or an unwritable parent dir). Delete our
  # claim IMMEDIATELY (a failed steal must NOT cost a CLAIM_STALE ageout
  # penalty), log damped, re-poll honouring MAX_WAIT (the caller's
  # fall-through reaches the timeout check — never busy-spin here).
  _lock_claim_delete "$tok" 0
  if [ "$_LOCK_STEAL_LOG_OK" = 1 ]; then
    _lock_log "steal FAILED: rename refused with the lock file still present (no-delete-share handle, or unwritable parent dir); claim deleted, re-polling — repeats logged at most once per ${AGENT_LOCK_STALE_SECS}s"
    _LOCK_STEAL_FAIL_LAST="$(_lock_now)"
  fi
  _LOCK_CLAIM_TOKEN=""
  _lock_discover "$tok" && return 0
  return 1
}

# A claim already exists (our O_EXCL claim create failed): a rival mid-steal,
# or a crashed claimant's leftover. Clear it ONLY when aged past CLAIM_STALE
# (same mtime + floor rules as the lock — a sub-floor claim mtime is
# "unsettled, just created", never "ancient, clear") AND claim-shaped (empty,
# or a "tok."-prefixed line 1) — the never-steal content guard applies to the
# claim path exactly as to the lock path, with per-path warn-once state. A
# successful clear logs CLAIM-STALE-CLEARED; the next poll re-races the
# claim create. A young claim means a live steal is in progress: just wait.
_lock_claim_stale_check() {
  local cm cage l1="" rdrc=0 shaped=0
  cm="$(_lock_stat_mtime "$_LOCK_CLAIM_PATH")"
  [ -n "$cm" ] || return 0                          # vanished/unreadable mtime: re-poll
  [ "$cm" -gt 946684800 ] 2>/dev/null || return 0   # sub-floor: unsettled, never clear
  cage=$(( $(_lock_now) - cm ))
  [ "$cage" -ge "$AGENT_LOCK_CLAIM_STALE_SECS" ] || return 0
  { IFS= read -r l1 || rdrc=$?; } 2>/dev/null < "$_LOCK_CLAIM_PATH" || rdrc=$?
  l1="${l1%"${l1##*[![:space:]]}"}"
  if [ -n "$l1" ]; then
    case "$l1" in
      tok.*) shaped=1 ;;
      *)     _lock_warn_nonlock_claim "its content is not claim-shaped" ;;
    esac
  elif ! [ -e "$_LOCK_CLAIM_PATH" ] && ! [ -L "$_LOCK_CLAIM_PATH" ]; then
    return 0                                        # vanished mid-check: re-poll
  elif ! [ -s "$_LOCK_CLAIM_PATH" ]; then
    shaped=1                                        # genuinely empty: the crash-orphan lane
  elif [ "$rdrc" -ne 0 ]; then
    return 0                                        # unreadable: skip this attempt, re-poll
  else
    _lock_warn_nonlock_claim "its content is not claim-shaped"
  fi
  [ "$shaped" = 1 ] || return 0
  if rm -f -- "$_LOCK_CLAIM_PATH" 2>/dev/null; then
    _lock_log "CLAIM-STALE-CLEARED $_LOCK_CLAIM_PATH age=${cage}s tok=${l1:-<empty>}"
    # If the cleared token was one of OUR leaked entries, this unlink is a
    # verified resolution — gated on one lock-path read (a rival's rename
    # can slip into our read->unlink gap and install it; an INCONCLUSIVE
    # read — lock present but unreadable — also keeps the entry, see
    # _lock_leaked_lock_resolved).
    if [ -n "$l1" ] && _lock_leaked_member "$l1"; then
      if _lock_leaked_lock_resolved "$l1"; then
        _lock_leaked_drop "$l1"
        _lock_log "leaked-token memory: resolved tok=$l1 (stale claim cleared)"
      fi
    fi
  fi
  return 0
}

lock_acquire() {
  # API misuse, not a CLI usage error (hence 1, not 96): the lock is NOT
  # reentrant. Without this guard a re-acquire would self-deadlock for the
  # stale window and then steal its own lock.
  if [ "${_LOCK_HELD:-0}" = "1" ]; then
    echo "git-commit-lock: lock_acquire called while already holding the lock (not reentrant)" >&2
    _lock_log "ERROR: reentrant lock_acquire refused"
    return 1
  fi
  mkdir -p "$(dirname "$AGENT_LOCK_PATH")" 2>/dev/null || true
  _LOCK_CLAIM_PATH="$AGENT_LOCK_PATH.next"
  local start; start="$(_lock_now)"
  local waiting_logged=0
  # Log damper for a squatted stale lock (a no-delete-share handle, or an
  # unwritable parent dir, makes the steal rename fail every poll with the
  # file still present): epoch of the last logged failed-steal attempt, 0 when
  # the last attempt did not fail that way. While the failures persist, the
  # STALE/steal-FAILED pair is logged at most once per stale window, so the
  # log growth stays bounded however long the squat lasts. (Global, not
  # local: _lock_steal_install shares it.)
  _LOCK_STEAL_FAIL_LAST=0
  _LOCK_STEAL_LOG_OK=1
  # Two-consecutive-poll confirmation state for the wrong-type guards below
  # (see WRONG-TYPE CLASSIFICATION): the concrete classification
  # observed on the PREVIOUS blocked poll, reset to empty whenever a poll
  # sees the path absent, a regular file, or no concrete type. PER PATH:
  # the lock path and the claim path each keep their own state (a shared
  # variable would cross-confirm the two-poll requirement between paths).
  local nonlock_prev="" claim_nonlock_prev=""

  # Save the caller's traps and arm our handlers NOW — claim-window mode
  # (see TRAP-TIME CLAIM CLEANUP in the header): the handlers are
  # state-/token-checked, so a signal landing before any claim or hold
  # exists passes through harmlessly. They stay armed through a hold
  # (lock_release restores the caller's traps) and are restored below on
  # every no-hold return.
  _LOCK_SAVED_TRAP_EXIT="$(trap -p EXIT)"
  _LOCK_SAVED_TRAP_INT="$(trap -p INT)"
  _LOCK_SAVED_TRAP_TERM="$(trap -p TERM)"
  trap '_lock_on_exit' EXIT
  trap '_lock_on_signal INT' INT
  trap '_lock_on_signal TERM' TERM

  while true; do
    # PRE-CREATE TYPE GUARD (mandatory). noclobber's exists=>fail protection
    # applies to REGULAR files only: `>` onto an existing FIFO blocks in
    # open(2) before any timeout logic runs, and onto a device node simply
    # writes. Only attempt the create when the path is absent or carries a
    # plain non-symlink file (where O_EXCL fails safely). The check-then-open
    # gap is acceptable: a non-lock object at the path is static
    # misconfiguration, not a racing peer. (A symlink — even dangling — is
    # refused by O_CREAT|O_EXCL itself; routing it to the wait loop just
    # lands it in the same warn lane coherently.)
    local creatable=0
    if [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
      if [ -f "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then creatable=1; fi
    else
      creatable=1
    fi

    # Fresh token per CREATE attempt (per-attempt tokens — see the header):
    # a verification-failure-abandoned lock can then never alias a later
    # attempt's read-back or a discovery read.
    local tokc=""
    if [ "$creatable" = 1 ]; then
      _lock_new_token; tokc="$_LOCK_NEWTOK"
    fi
    if [ "$creatable" = 1 ] \
       && ( set -C; printf '%s\n%s\n' "$tokc" "$_LOCK_ME" > "$AGENT_LOCK_PATH" ) 2>/dev/null; then
      # The redirect is one open(O_CREAT|O_EXCL)+write+close: the file now
      # carries our token and its mtime (the staleness clock) is stamped.
      # The 2>/dev/null is on the SUBSHELL because the noclobber failure
      # message comes from bash itself, not printf (probe A). A created-but-
      # write-failed file (e.g. ENOSPC) makes the subshell fail and falls
      # through below; the empty/torn orphan ages into its steal lane.
      #
      # VERIFY via a path read-back before claiming the hold (see ACQUIRE
      # VERIFICATION in the header): only our own token proves we hold the
      # path. NEVER repair a failed read-back by writing to the path. The
      # read runs the FULL retry ladder (the shared escalating schedule in
      # _lock_cur_token), then gives up with no further grace wait: a steal
      # installs by rename-over, so a displaced fresh lock is never moved
      # aside and never comes back — there is nothing to wait for.
      local rb
      rb="$(_lock_cur_token)"
      if [ "$rb" = "$tokc" ]; then
        _lock_take_hold "$tokc"
        return 0
      fi
      _lock_log "WARNING: acquire verification FAILED — create won but read-back found '${rb:-<empty-or-gone>}' (ours=$tokc); not acquired, re-entering wait"
      echo "git-commit-lock: WARNING — acquire verification failed: the lock file did not read back our token; treating the lock as NOT acquired and waiting" >&2
      # fall through to the blocked branch of this same iteration
    fi

    # Blocked (create lost, was skipped by the type guard, or won-but-failed
    # verification). One WAITING line on the first blocked poll only: lets a
    # reader of the log see that this acquirer actually contended, and lets
    # tests hold-until-WAITING instead of sleeping.
    if [ "$waiting_logged" = 0 ]; then
      waiting_logged=1
      _lock_log "WAITING for lock ($_LOCK_ME)"
    fi

    # LEAKED-TOKEN MEMORY per-poll check (see the header rule; the list is
    # almost always empty, so this costs nothing in the common case): while
    # entries are pending, every poll that observes a lock also reads its
    # line 1 — a LISTED token there means a rival's rename installed OUR
    # leaked claim as the lock: adopt it as the hold (the entry drops; the
    # leak is resolved).
    if [ -n "$_LOCK_LEAKED" ] && [ -f "$AGENT_LOCK_PATH" ]; then
      local lt; lt="$(_lock_read_tok "$AGENT_LOCK_PATH" 1)"
      if [ -n "$lt" ] && _lock_leaked_member "$lt"; then
        _lock_leaked_drop "$lt"
        _lock_log "DISCOVERY-HOLD (leaked-token memory): leaked claim tok=$lt found installed at the lock path — adopting the hold"
        _lock_take_hold "$lt"
        return 0
      fi
    fi

    # PER-POLL TYPE GUARD (cheap; every blocked poll, NOT age-gated): an
    # actively-written non-lock path (the canonical AGENT_LOCK_PATH=$HOME
    # typo: writes keep refreshing its mtime) never ages past the stale
    # window, so an age-gated guard would never diagnose it. Warn only on
    # exists-but-wrong-type — a path that vanished since the failed create is
    # normal contention (re-race the create), not a config problem. "Exists"
    # is `-e || -L`: a DANGLING symlink is refused by O_CREAT|O_EXCL forever
    # but reads as absent to a bare `-e`, which would misclassify it as
    # contention every poll and starve the waiter to 97 with no diagnosis.
    if [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
      if [ -f "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
        nonlock_prev=""   # regular file: any prior wrong-type observation is moot
        # A regular file: a live lock, a stale one, or a crash orphan.
        # Steal if the FILE's mtime is older than the stale window — but only
        # on a PLAUSIBLE mtime (>= 2000-01-01): a freshly created file can
        # transiently report the Windows FILETIME zero (1601), which would
        # look ~400 years old and spuriously steal a live, just-acquired
        # lock (probes C/C1b). A sub-floor read is unsettled, not stale.
        local mt age
        _lock_path_mtime; mt="$_LOCK_MTIME"
        if [ -n "$mt" ] && [ "$mt" -gt 946684800 ] 2>/dev/null; then
          age=$(( $(_lock_now) - mt ))
          if [ "$age" -ge "$AGENT_LOCK_STALE_SECS" ]; then
            # CONTENT GUARD (age-gated, runs only on a stale candidate):
            # steal only lock-shaped content — an EMPTY file (the crash-
            # between-create-and-write orphan) or line 1 starting "tok."
            # (a real token, possibly torn mid-token). Anything else is a
            # user file at a typo'd path or a torn write shorter than the
            # prefix: never steal it. Line 2 (owner) is read in the same
            # open, BEFORE the final mtime re-read below — an open inserted
            # after the re-read would widen exactly the window it shrinks.
            local line1="" line2="" rdrc=0 steal_ok=0
            { IFS= read -r line1 || rdrc=$?; IFS= read -r line2 || true; } 2>/dev/null < "$AGENT_LOCK_PATH" || rdrc=$?
            line1="${line1%"${line1##*[![:space:]]}"}"
            line2="${line2%"${line2##*[![:space:]]}"}"
            if [ -n "$line1" ]; then
              case "$line1" in
                tok.*) steal_ok=1 ;;
                *)     _lock_warn_nonlock "its content is not lock-shaped" ;;
              esac
            elif ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
              : # vanished mid-check: normal contention; re-poll
            elif ! [ -s "$AGENT_LOCK_PATH" ]; then
              steal_ok=1   # genuinely empty: the crash-orphan lane
            elif [ "$rdrc" -ne 0 ]; then
              # Persistent read failure with a non-empty file still present:
              # neither "empty" nor the never-steal lane — skip this steal
              # attempt and re-poll. Self-correcting: a handle that blocks
              # our read usually blocks the steal rename too (probe D1), so
              # refusing costs nothing.
              _lock_log "steal skipped: stale lock content unreadable (age=${age}s); re-polling"
            else
              # Read succeeded but line 1 is blank on a NON-empty file: a
              # torn write of ours always starts with 't', so this is not
              # lock-shaped either.
              _lock_warn_nonlock "its content is not lock-shaped"
            fi

            if [ "$steal_ok" = 1 ]; then
              local holder="${line2:-?}"
              # Damp the attempt logging while steals keep failing on a
              # squatted file (see _LOCK_STEAL_FAIL_LAST above): first
              # failure, then at most once per stale window.
              local now_s
              now_s="$(_lock_now)"
              _LOCK_STEAL_LOG_OK=1
              if [ "$_LOCK_STEAL_FAIL_LAST" != 0 ] \
                 && [ $(( now_s - _LOCK_STEAL_FAIL_LAST )) -lt "$AGENT_LOCK_STALE_SECS" ]; then
                _LOCK_STEAL_LOG_OK=0
              fi
              # CLAIM-PATH PRE-CREATE TYPE GUARD (mandatory, same reasoning
              # as the lock path's: a noclobber `>` onto an existing FIFO at
              # the claim path would HANG in open(2)). Wrong types get the
              # same two-consecutive-poll confirmation + warn-once, with
              # per-path state (claim_nonlock_prev — independent from the
              # lock path's nonlock_prev).
              local claim_creatable=0
              if [ -e "$_LOCK_CLAIM_PATH" ] || [ -L "$_LOCK_CLAIM_PATH" ]; then
                if [ -f "$_LOCK_CLAIM_PATH" ] && ! [ -L "$_LOCK_CLAIM_PATH" ]; then
                  claim_creatable=1
                  claim_nonlock_prev=""
                else
                  local claim_nonlock_cur=""
                  if   [ -L "$_LOCK_CLAIM_PATH" ]; then claim_nonlock_cur="a symlink"
                  elif [ -d "$_LOCK_CLAIM_PATH" ]; then claim_nonlock_cur="a directory"
                  elif [ -p "$_LOCK_CLAIM_PATH" ]; then claim_nonlock_cur="a FIFO"
                  elif [ -S "$_LOCK_CLAIM_PATH" ]; then claim_nonlock_cur="a socket"
                  elif [ -b "$_LOCK_CLAIM_PATH" ] || [ -c "$_LOCK_CLAIM_PATH" ]; then claim_nonlock_cur="a device node"
                  fi
                  if [ -n "$claim_nonlock_cur" ] && [ "$claim_nonlock_cur" = "$claim_nonlock_prev" ]; then
                    _lock_warn_nonlock_claim "it is $claim_nonlock_cur"
                  fi
                  claim_nonlock_prev="$claim_nonlock_cur"
                  # No claim create possible: steals are blocked until the
                  # object is removed; fall through to timeout + sleep.
                fi
              else
                claim_creatable=1
                claim_nonlock_prev=""
              fi
              if [ "$claim_creatable" = 1 ]; then
                # Fresh token per CLAIM attempt (per-attempt tokens — see
                # the header). _LOCK_CLAIM_TOKEN arms the trap handlers'
                # claim-window cleanup BEFORE the create: the handler is
                # token-checked, so a signal landing pre-create is a
                # harmless no-op.
                _lock_new_token
                local toka="$_LOCK_NEWTOK"
                _LOCK_CLAIM_TOKEN="$toka"
                if ( set -C; printf '%s\n%s\n' "$toka" "$_LOCK_ME" > "$_LOCK_CLAIM_PATH" ) 2>/dev/null; then
                  [ "$_LOCK_STEAL_LOG_OK" = 1 ] && _lock_log "STALE (age=${age}s holder=$holder) -> stealing (claim-serialized)"
                  _lock_log "CLAIM $_LOCK_CLAIM_PATH tok=$toka by $_LOCK_ME"
                  if _lock_steal_install "$toka"; then
                    return 0
                  fi
                  # Attempt resolved without a hold: fall through to the
                  # timeout check + poll sleep (never busy-spin — a blocked
                  # rename means nothing changes until the squatter lets go).
                else
                  # Claim create lost (or failed): a rival is stealing, or a
                  # crashed claimant's leftover squats the claim path. Clear
                  # the latter only when aged + claim-shaped; otherwise just
                  # wait — the rival's steal is in flight.
                  _LOCK_CLAIM_TOKEN=""
                  _lock_claim_stale_check
                fi
              fi
            fi
          fi
        fi
      else
        # WRONG-TYPE CLASSIFICATION (TOCTOU-hardened): the "exists" (-e/-L)
        # and "regular file" (-f && ! -L) checks above are SEPARATE stats,
        # so a normal contended poll can land here looking wrong-type with
        # nothing misconfigured; warning on a bare observation would fire
        # the loud config warning as a pure false alarm (reproduced under
        # vanilla contention and deterministically under create/delete
        # churn). Two transients cause it: a rival's release/steal unlink
        # between the two stats, and — worse — a Windows DELETE-PENDING
        # ghost (the unlink is queued until a rival reader's transient
        # handle closes; for up to ~ms the attribute stats FAIL while a
        # bare -e still reports existence), which probing showed defeats
        # any immediate re-check of the same -e/-f pair: the ghost outlives
        # it. Nor is it enough to warn only on a CONCRETE wrong type —
        # directory, symlink, FIFO, socket, device — on the theory that a
        # vanished or delete-pending path fails every one of these stats:
        # a delete-pending ghost can transiently MATCH one of the six
        # concrete stats under Cygwin (observed on windows-2025, CI run
        # 27325971668, unit T17d — a path that only ever held churned
        # REGULAR files), so one observation is not evidence of
        # misconfiguration. Hence TWO-CONSECUTIVE-POLL CONFIRMATION: warn
        # only when the SAME concrete type is observed on two consecutive
        # blocked polls. A ghost transient makes a same-type repeat across
        # a full poll
        # interval extremely unlikely (zero in hundreds of churn waiter-runs
        # locally and in probes) though not impossible - two INDEPENDENT
        # ghosts could land same-type on consecutive polls - and the one
        # observed long-lived delete-pending state (60s behind an AV handle,
        # see the unit suite T17d readiness note) reads as ENOENT/absent,
        # which RESETS the confirmation. A real misconfig needs >=2 blocked
        # polls before MAX_WAIT to warn (always true outside degenerate
        # test configs). A real misconfig object classifies identically forever — its
        # once-per-process warning just arrives one poll later, and the
        # never-steal safety is unaffected either way (the guard never
        # steals non-locks regardless of warning state). Residual: an
        # object so exotic that no stat classifies it would starve waiters
        # to 97 undiagnosed — transient ghosts are exactly that state, so
        # they win the tie. -L is tested FIRST so a symlink (whose target
        # would otherwise satisfy -d etc.) is named as the link it is.
        local nonlock_cur=""
        if   [ -L "$AGENT_LOCK_PATH" ]; then nonlock_cur="a symlink"
        elif [ -d "$AGENT_LOCK_PATH" ]; then nonlock_cur="a directory"
        elif [ -p "$AGENT_LOCK_PATH" ]; then nonlock_cur="a FIFO"
        elif [ -S "$AGENT_LOCK_PATH" ]; then nonlock_cur="a socket"
        elif [ -b "$AGENT_LOCK_PATH" ] || [ -c "$AGENT_LOCK_PATH" ]; then nonlock_cur="a device node"
        fi
        if [ -n "$nonlock_cur" ] && [ "$nonlock_cur" = "$nonlock_prev" ]; then
          _lock_warn_nonlock "it is $nonlock_cur"
        fi
        nonlock_prev="$nonlock_cur"
        # (no concrete type: vanished or delete-pending ghost — normal
        # contention; the next iteration re-races the create)
      fi
    else
      # path absent: normal contention — the next iteration re-races the
      # create. Also resets the wrong-type confirmation state above.
      nonlock_prev=""
    fi

    # A live holder has it (or a never-steal object squats it) — wait,
    # unless we have waited too long.
    if [ $(( $(_lock_now) - start )) -ge "$AGENT_LOCK_MAX_WAIT" ]; then
      _lock_log "TIMEOUT after ${AGENT_LOCK_MAX_WAIT}s waiting for lock"
      echo "git-commit-lock: timed out after ${AGENT_LOCK_MAX_WAIT}s waiting for commit lock" >&2
      # The arc ends here without a hold: run the best-effort resolution
      # pass over any pending leaked entries (the blocking handle may have
      # closed by now) and put the caller's traps back.
      _lock_leaked_resolve_pass
      _lock_restore_traps
      return 97
    fi
    sleep "$AGENT_LOCK_POLL_SECS"
  done
}

# Release. Returns 0 if we held the lock cleanly throughout; returns 98 (and
# logs a loud WARNING) if our lease had been stolen before release — the file
# is GONE or carries a non-empty FOREIGN token (both definitive: acquire's
# read-back proved our token was at the path) — meaning the work we just did
# was NOT under exclusive protection and should be treated as failed; returns
# 2 if the file still reads EMPTY after the retry ladder while present
# (ownership unverifiable — see the lane comment below); returns 1 if the
# lock file could not be deleted (LEFTOVER: left behind; recovery needs the
# stale window AND the blocking handle to close). Always restores the
# caller's pre-acquire traps, and always runs the best-effort arc-end
# resolution pass over any pending leaked-claim entries (see the
# leaked-token memory rule; a lock token found in the leaked set is OUR
# installed leaked claim — cleaned up here, still verdict 98). Idempotent: a
# second call (or a call without a hold) is a successful no-op.
lock_release() {
  [ "${_LOCK_HELD:-0}" = "1" ] || return 0
  _LOCK_HELD=0

  # Did we keep the lock the whole time? Compare the file's current token to
  # ours — and on a match, re-read it once more IMMEDIATELY before the rm to
  # shrink the steal-between-check-and-delete window. The boundary re-read is
  # classified by the SAME rules as the first read (empty-at-boundary is the
  # rc-2 lane, never a delete: an empty read is precisely the
  # create->write window of a successor after a boundary steal). The window
  # cannot be closed with these primitives — see KNOWN RESIDUAL RACES in the
  # header; the residual case is detected by the displaced party, never
  # silent.
  local cur; cur="$(_lock_cur_token)"
  if [ "$cur" = "$_LOCK_TOKEN" ]; then
    cur="$(_lock_cur_token)"
  fi
  if [ "$cur" != "$_LOCK_TOKEN" ]; then
    # LEAKED-CLAIM CLEANUP (see the leaked-token memory rule): a token that
    # is not our hold token but IS in our leaked set is — by per-attempt
    # token uniqueness — OUR leaked claim, installed over our held lock by a
    # rival's rename. Our actual hold WAS displaced (the verdict stays 98),
    # but the installed orphan is ours to clean: re-read immediately before
    # the unlink (the ours-path boundary mitigation — an instantly-stale
    # installed leak can already have been stolen by a successor whose live
    # lock a naive unlink would rob), then unlink with the ours-path bounded
    # retry + LEFTOVER behaviour.
    if [ -n "$cur" ] && _lock_leaked_member "$cur"; then
      local lre; lre="$(_lock_cur_token)"
      if [ "$lre" = "$cur" ]; then
        local _ltry=0 lcleaned=1
        while ! rm -f -- "$AGENT_LOCK_PATH" 2>/dev/null; do
          _ltry=$((_ltry+1))
          if [ "$_ltry" -ge 5 ]; then lcleaned=0; break; fi
          sleep 0.02
        done
        if [ "$lcleaned" = 1 ]; then
          _lock_log "RELEASE-CLEANED-LEAKED-CLAIM $AGENT_LOCK_PATH tok=$cur"
        else
          _lock_log "WARNING: release could not delete our installed leaked claim after $_ltry attempts; LEFTOVER (tok=$cur). It ages out within ${AGENT_LOCK_STALE_SECS}s once the blocking handle closes."
          echo "git-commit-lock: WARNING — could not remove our leaked claim installed at $AGENT_LOCK_PATH; it is left behind and will block waiters until the ${AGENT_LOCK_STALE_SECS}s stale window expires and whatever holds it open lets go" >&2
        fi
      fi
      # Re-read no longer the leaked token: a successor stole/replaced it —
      # its rename destroyed our leaked claim, resolving the leak; do NOT
      # touch the successor's live lock. Either way the entry is resolved.
      # (Unconditional drop — deliberately NOT the resolve-pass's
      # inconclusive-keep (_lock_leaked_lock_resolved): the boundary re-read
      # ran the FULL 8-try ladder immediately after this same arc read the
      # leaked token OK, so an empty-but-present re-read here means the leak
      # file was destroyed and a successor is mid-create at the path — not a
      # transient read flake — and the leaked token cannot reappear.)
      _lock_leaked_drop "$cur"
      _lock_leaked_resolve_pass
      _lock_restore_traps
      _lock_log "WARNING: lock LOST before release — our held lock was displaced by our own leaked claim (rival rename). This commit was NOT exclusive — redo it. (ours=$_LOCK_TOKEN installed-leak=$cur)"
      echo "git-commit-lock: WARNING — lock was stolen mid-hold (displaced by a leaked claim of ours, since cleaned). Your commit was NOT serialised; verify with 'git log' and redo under the lock." >&2
      return 98
    fi
    _lock_leaked_resolve_pass
    _lock_restore_traps
    if [ -z "$cur" ] && [ -e "$AGENT_LOCK_PATH" ]; then
      # The file still exists but reads EMPTY after the retry ladder. NOT
      # definitive theft evidence: it cannot be our own failed write
      # (acquire's read-back positively verified our token at the path), but
      # it can be a successor mid-create after a boundary steal (probe F's
      # window) or external truncation. We cannot verify ownership either
      # way: do NOT delete (it may be a successor's nascent live lock), do
      # not claim success — leave the file (the staleness backstop recovers
      # a true orphan) and fail distinctly. The ps1 port's 'unreadable' lane
      # gives the same verdict for the same state.
      _lock_log "WARNING: lock file present but EMPTY/unreadable at release (after retries); ownership unverifiable. Leaving it in place. (ours=$_LOCK_TOKEN)"
      echo "git-commit-lock: WARNING — the lock file read empty/unreadable at release (still present). Ownership unverifiable; lock file left in place. Verify with 'git log'." >&2
      return 2
    fi
    # Gone, or a foreign token: our lease expired and the lock was stolen
    # (and possibly re-acquired by someone else). Do NOT touch the path — it
    # may be a successor's LIVE lock. Loudly report the non-exclusive hold.
    _lock_log "WARNING: lock LOST before release (held longer than ${AGENT_LOCK_STALE_SECS}s stale window; stolen). This commit was NOT exclusive — redo it. (ours=$_LOCK_TOKEN now=${cur:-<gone>})"
    echo "git-commit-lock: WARNING — lock was stolen mid-hold (held > ${AGENT_LOCK_STALE_SECS}s). Your commit was NOT serialised; verify with 'git log' and redo under the lock." >&2
    return 98
  fi

  # Still ours — free it: one unlink. `-f` masks only ENOENT, which is the
  # "vanished mid-race = already released" branch. On Windows the unlink can
  # fail while a foreign no-delete-share handle (AV scanner, naive reader) is
  # open on the file; retry briefly. The retry is grounded on probe D1, not
  # on hope: the handle class that blocks our unlink also blocks any steal's
  # rename, so the path cannot be stolen-and-recreated while the delete keeps
  # failing (the read-only-attribute exception and the between-retries gap
  # are documented in the header; both end in the same detected-98 class).
  local _try=0
  while ! rm -f -- "$AGENT_LOCK_PATH" 2>/dev/null; do
    _try=$((_try+1))
    if [ "$_try" -ge 5 ]; then
      # Persistent failure: the lock is NOT released (LEFTOVER). Do not claim
      # success — waiters stay blocked until the stale window elapses AND the
      # blocking handle closes (the same handle blocks their steal rename,
      # so until then they re-poll and may reach 97).
      _lock_leaked_resolve_pass
      _lock_restore_traps
      _lock_log "WARNING: release FAILED — could not delete the lock file after $_try attempts; LEFTOVER (tok=$_LOCK_TOKEN). Waiters are blocked until the ${AGENT_LOCK_STALE_SECS}s stale window elapses AND the blocking handle closes."
      echo "git-commit-lock: WARNING — could not remove the lock file ($AGENT_LOCK_PATH); it is left behind and will block waiters until the ${AGENT_LOCK_STALE_SECS}s stale window expires and whatever holds it open lets go" >&2
      return 1
    fi
    sleep 0.02
  done
  # Arc end: one best-effort resolution pass over any pending leaked entries
  # (almost always a no-op — the list is empty in the common case).
  _lock_leaked_resolve_pass
  _lock_restore_traps
  _lock_log "RELEASED ($_LOCK_ME tok=$_LOCK_TOKEN)"
  return 0
}

# Run a command under the lock; always release; propagate the command's exit
# code — UNLESS the lock was lost mid-hold, in which case return 98
# (exclusivity failure overrides a "successful" command, because it wasn't
# serialised). An acquire failure returns 97 (timeout) or 1 (misuse) with the
# command NEVER run. An unverifiable release (rc 2) fails a SUCCESSFUL command
# with 1 but keeps a failing command's own code. A release that merely failed
# to delete the file (rc 1) does NOT override the command's code: the hold WAS
# exclusive, the warning has been printed, and the stale window cleans up.
lock_run() {
  lock_acquire || return $?
  local rc=0
  "$@" || rc=$?
  local rel=0
  lock_release || rel=$?
  if [ "$rel" -eq 98 ]; then
    return 98
  fi
  if [ "$rel" -eq 2 ] && [ "$rc" -eq 0 ]; then
    # Ownership unverifiable at release (file present but empty): not a
    # proven theft, but not a verified-exclusive hold either — a
    # "successful" command must not report success. A FAILING command keeps
    # its own exit code (parity with the ps1 run path).
    rc=1
  fi
  return "$rc"
}

# --- CLI (only when executed directly, not when sourced) --------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # Usage text goes to STDOUT: an explicit --help/-h is an answered question
  # (stdout, exit 0); genuine usage errors redirect it to stderr at the call
  # site and exit 96.
  _lock_usage() {
    echo "usage: git-commit-lock.sh run -- <command...>"
    echo "   or: source git-commit-lock.sh; lock_acquire; <git...>; lock_release"
    echo "exit codes: the command's own, or 96 usage error / 97 lock timeout (command not run) / 98 lock stolen mid-hold (redo the work)"
  }
  cmd="${1:-}"; shift || true
  case "$cmd" in
    --help|-h)
      _lock_usage
      exit 0
      ;;
    run)
      [ "${1:-}" = "--" ] && shift
      [ "$#" -gt 0 ] || { _lock_usage >&2; exit 96; }
      # Outside any git repo a defaulted lock would silently scope to the CWD
      # and serialise against NOBODY committing to a repo — refuse instead.
      if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_PATH_EXPLICIT" = 0 ]; then
        echo "git-commit-lock: not inside a git repository and AGENT_LOCK_PATH is not set — refusing to guess a lock location (a CWD-scoped lock would not serialise repo commits). cd into the repo or set AGENT_LOCK_PATH." >&2
        exit 96
      fi
      lock_run "$@"
      ;;
    *)
      _lock_usage >&2
      exit 96
      ;;
  esac
fi
