# Plan: claim-serialized stealing (claim-is-the-next-lock + atomic rename-over)

Status: CONVERGED (v7) — round-7 Codex confirmation clean; round-6 Claude confirmation clean given the v7 folds. IMPLEMENTING..

## Goal

Replace the current steal mechanism (racing `mv` to a grave, plus the wave-1
detect-and-restore machinery) with **claim-serialized stealing**: to steal a
stale lock you must first win an O_EXCL claim file; the claim file carries your
own token and *becomes* the new lock via one atomic rename-over. This
**prevents** the displaced-live race (a straggler stealing the recovery
winner's fresh lock) that wave 1 (`2843d4e`, `4e3f890`) could only detect and
repair. (Prevention is scoped, not absolute: processes actively inside an
acquire/hold/release arc are fully covered,
trappable exits clean up after themselves best-effort — a trap-time blocked
unlink joins the same bounded residual class — and one untrappable-death
residual is deliberately accepted — see residual 5 in the residual
inventory.)

Design lineage: Ben proposed serializing steals through a second
create-or-fail file; this plan adopts that with one refinement — the claim file
is the next lock itself, so the steal is a single atomic replace with no grave
and no path-absent window (bash and pwsh 7; the 5.1 lane accepts a claim-guarded
absent window, see Implementation notes). See "Alternatives considered".

## Why prevention wins over wave 1's detect+restore

- The verify-under-exclusivity step (re-read the lock's staleness while holding
  the claim) makes it impossible to `mv` a *fresh* lock: while the lock path is
  occupied, creates fail; steals require the claim you hold; the only other
  mutation (a live slow holder releasing) makes the steal target vanish, which
  is handled (see algorithm step 4a).
- Removes three novel wave-1 mechanisms: grave-token comparison, hard-link
  restore, restore grace. Removes graves entirely (and the age-gated grave
  sweep): rename-over destroys the ghost and installs the new lock in one op.
- No path-absent window during recovery in the common lanes (bash / pwsh 7),
  and a claim-guarded one on 5.1 ⇒ no thundering-herd create re-race. The
  claimant that did the recovery work wins the lock except in the inventoried
  residuals (residual 1's verify→rename displacement; the 5.1 fairness loss)
  — not "deterministically always".
- Drops the hard-link filesystem dependency wave 1 introduced.

## The protocol

### Objects

| Object | Path | Content |
|--------|------|---------|
| Lock   | `$AGENT_LOCK_PATH` (default `<gitdir>/commit.lock`) | line 1 `tok.<uniq>`, line 2 `pid=<pid> host=<host>` (unchanged) |
| Claim  | `${AGENT_LOCK_PATH}.next` | identical wire format, the **claimant's own** token |

The claim is written through its creation handle exactly like the lock (bash:
noclobber redirect; ps1: `FileMode::CreateNew` + write through that handle), so
the empty-file crash-orphan lane and the mtime-floor rule apply to it
identically (a sub-floor claim mtime means "unsettled, treat as just-created",
never "ancient, clear" — tested). The claim path also gets the lock path's
**pre-create type guard**: in bash a noclobber `>` onto an existing FIFO blocks
in open(2) — omitting the guard on the claim path is a *hang*, not a warning,
so it must be stated and implemented, not inherited by accident.

### Steal algorithm (replaces the current steal lane in both impls)

When a poll judges the lock stale (existing rules: regular file, lock-shaped
content, plausible mtime ≥ floor, age > `AGENT_LOCK_STALE_SECS`):

1. **Claim**: O_EXCL-create `${LOCK}.next` with our token.
   - Create fails because a claim exists → someone else is stealing; fall
     through to the claim-staleness check (below), then keep waiting.
2. **Re-verify under the claim**: re-read the lock fresh (content + mtime +
   floor + shape).
3. **Still stale** → the ordered install sequence:
   1. **Claim recheck**: re-read `${LOCK}.next`. It must (a) carry OUR token
      and (b) be younger than `AGENT_LOCK_CLAIM_STALE_SECS`. Rationale: a
      long-suspended claimant must not proceed on a claim a waiter may have
      already judged stale — this closes the stale-claim TOCTOU that round-1
      review flagged (a cleared-then-renamed claim installing an unowned
      lock). Outcomes:
      - **Gone** → the final discovery read (global rule, below): our claim
        may already have been installed as the lock by a rival's rename.
        Not ours at the lock either → re-poll.
      - **Foreign token** → the final discovery read (ours may have been
        installed as the lock *before* the rival claimed); otherwise a
        clearer removed ours and a rival claimed: leave the file, re-poll.
      - **Ours but overaged** → assume contested (a clearer may be acting on
        it right now); delete our own claim (token-checked, below),
        `CLAIM-ABORT (contested)`, then the final discovery read (a rival's
        rename can land between this recheck's read and the deletion),
        re-poll.
      - **Unreadable after the retry ladder** → leave it (it ages out) and
        append our attempt token to the **leaked-token memory** (global
        rule, below) — the claim stays in place without a verifiable
        unlink, so the one-shot final read alone is not conclusive for
        this exit; re-poll.
   2. **Touch the claim** (refresh its mtime) — **non-creating**, with
      per-runtime gone-detection (the two mechanisms differ; the spec names
      the real ones):
      - bash: `touch -c -- "$claim"`, followed by an **explicit existence
        check** (`[ -e "$claim" ]`). `touch -c` on a missing file exits 0
        (POSIX: no-create, no error; probed on this box, GNU coreutils) —
        the exit code carries NO gone signal; only the explicit check does.
        The check's own TOCTOU is benign: it only routes to the final
        discovery read, whose conclusiveness comes from the discovery rule,
        not from this check.
      - ps1: `[IO.File]::SetLastWriteTimeUtc` catching FileNotFound (the
        exception IS the gone signal there).

      A creating touch would resurrect a vanished claim as a fresh empty
      `${LOCK}.next` that blocks every rival claim until it ages out
      (O_EXCL fails on it; clearers must wait out CLAIM_STALE) — a
      self-inflicted steal outage — and it masks the gone-claim signal the
      ownership-discovery rule keys on. Claim gone at the touch → the final
      discovery read, then re-poll. (A missed gone-at-touch is not
      load-bearing — the step-3.3 re-verify or the rename-source-gone lane
      catches it, so the algorithm converges either way; the spec just must
      describe the real mechanism, not a fictional exit-code signal.)

      Purpose of the touch: because rename preserves mtime, **the installed
      lock's staleness clock after the rename IS the claim file's mtime**,
      so the touch makes the new holder's lease start ~now. This fixes the
      aged-lease defect (a claim created up to CLAIM_STALE ago would
      otherwise install a lock already that old). Two accuracy caveats: the
      touch does NOT defend the rename against a clearer whose staleness
      read predates the touch — what actually bounds things is the
      step-3.1 recheck (our claim is younger than CLAIM_STALE at recheck)
      plus the ownership-discovery rule catching any leak. And a claimant
      suspended between this touch and the rename still installs a
      correspondingly aged-mtime lock — the lease shortfall is bounded by
      the touch→rename gap (milliseconds when not suspended), not
      guaranteed ~zero. (Decision: no recheck margin — keep the spec
      simple; the discovery rule makes the gap-frequency question moot.)
   3. **Re-verify the lock** still stale (as step 2; unchanged).
   4. **Rename-over**: `mv ${LOCK}.next ${LOCK}` (ghost destroyed + our live
      lock installed in one operation). Then run the existing acquire
      read-back verification (must find our own token) — kept as
      defense-in-depth.
4. **Not confirmed** (at step 2 or 3.3) → token-checked deletion of our
   claim, then the **final discovery read** (global rule, below), then the
   lane outcome. Two sub-cases:
   - (a) lock **gone** (the "stale" holder was live-slow and released, or
     another mutation): `CLAIM-ABORT (gone)`; do NOT rename onto the
     now-absent path — that lane belongs to the normal create race and
     renaming there could clobber a rival's fresh create. A rival's rename
     can interleave with exactly this lane (round 3 exhibited a concrete
     orphan walk through it: lock-gone observed, then the rival installs
     our claim, then our deletion finds the claim gone) — the final read
     finding our token ⇒ we HOLD; otherwise re-race the normal create.
   - (b) lock **fresh** (mtime renewed / different token): the "fresh"
     lock may be OUR OWN claim, installed by a rival's rename — the final
     read finding our token ⇒ we HOLD the lock (without this we would
     abort on our own lock and orphan it). Otherwise `CLAIM-ABORT (fresh)`;
     continue waiting.

**Token-checked claim deletion (global rule).** Every "delete our claim" path
anywhere in this algorithm reads the claim first and unlinks **only if line 1
is our token**. Outcomes:
- **Ours** → unlink. The unlink hitting ENOENT after the passing read (the
  claim vanished in the read→unlink gap) is NOT an error: it routes into the
  final discovery read like every other exit — a rival may have renamed the
  claim in as the lock inside that gap.
- **Ours at the read, but the unlink FAILS with the file still present** (a
  no-delete-share handle blocking deletion — the outcome round 4 found
  unspecified) → treat as **leaked**: append the attempt token to the
  leaked-token memory, damped warning, re-poll.
- **Gone at the read** → likewise routes into the final discovery read.
- **Foreign** → leave the claim (it's a rival's live claim); the final
  discovery read still runs (ours may already have been installed as the
  lock before the rival claimed).
- **Unreadable after the retry ladder** → leave it to age out AND append the
  attempt token to the leaked-token memory (the read could not verify the
  claim is not ours, so ours may still be installable after our final read).
Never blind-unlink the claim path. (The deletion's own read→unlink gap can in
principle unlink a rival's just-created claim — clearer and rival inside a
microsecond window; benign: the rival's recheck finds its claim gone → final
discovery read → it retries. Implementations must NOT add machinery for
this.)

**Ownership-discovery rule (global rule): the unconditional final act.** A
rival's rename can install OUR claim file as the lock while we are anywhere
past the claim create. So: **after a claim attempt, every exit path that does
not end in a successful rename performs, as its final act — after any
claim-deletion attempt, and regardless of which anomaly was observed — one
read of the lock path's line 1.** Our claim token there ⇒ we HOLD the lock —
proceed to the acquire read-back verification; otherwise the lane's normal
outcome stands (re-poll / re-race). Positioned as the final act, the read
runs after our own deletion attempt; a hit is a true hit (per-claim-attempt
tokens, below). A miss is a true miss **only on exits that installed the
claim or verifiably unlinked it** — once we have ourselves unlinked our
claim (or verifiably watched it leave), it can never subsequently be
installed. Round 4 found three exits that violate that premise by leaving
the claim in place unverified — **recheck-unreadable**,
**deletion-read-unreadable**, and **deletion-unlink-blocked-while-present**
— where a suspended rival's rename can install our claim AFTER our final
discovery read, manufacturing an unowned own-token lock (a ≤ STALE stall).
Those exits therefore feed the **leaked-token memory** rule below, which
turns the one-shot read into continuous discovery for exactly those lanes.
The same family's dead-claimant case (the claimant dies mid-claim, so no
discovery can run at all) is handled by the trap-time cleanup rule below
for trappable exits, and inventoried as residual 5 for untrappable death.

v3 instead *enumerated* the exits needing the read (recheck-gone/foreign,
touch-target-gone, the step-2/3.3 fresh abort, rename-source-gone,
deletion-finds-foreign) — and the enumeration provably missed exits: step-4(a)
lock-gone, a token-checked deletion finding the claim GONE, the deletion's
unlink hitting ENOENT after a passing read, and the contested abort — each of
which a rival's rename can interleave with (round 3 exhibited a concrete
orphan walk through 4(a)). The per-position mentions throughout this plan
therefore remain only as *illustration* of where hits occur; the rule itself
is position-blind. Cost: one extra read per abort path, all of which already
read files. This rule plus the leaked-token memory is what makes "no unowned
orphan from a process **actively inside an acquire/hold/release arc**"
structural rather than per-lane: whichever claim file gets installed at the
lock path, its token's owner — while inside the arc — takes SOME exit path,
and the final discovery read on that path, the memory's per-poll check, or —
for a leaker whose acquire has since succeeded on another token — the
memory's release-path branch finds ownership; every other party reads a
foreign token and backs off. The arc scoping is load-bearing: all three
mechanisms run only between the start of an acquire and the end of its
release — a leaker whose arc has ENDED (97, clean release, or death) with
entries pending has no mechanism left running (round-6 walk: B leaks L,
releases cleanly, lives on between acquires; a suspended rival installs L
afterwards — none of the three can fire) — those pending entries are
residual 5's extended class, recovered by the owner's next acquire adopting
the token or by staleness. Trappable exits clean up via the trap-time rule
(best-effort — its blocked-unlink case joins residual 5's bounded class);
untrappable death leaves the inventoried bounded residual (residual 5).

**Leaked-token memory (global rule; closes every in-arc live-process lane
the one-shot read cannot).** Each acquire keeps an in-process list of **leaked
attempt tokens**: tokens whose claim file was left in place without a
verifiable unlink. Exactly three exits append to it — the step-3.1
recheck-unreadable outcome, and the token-checked deletion's
read-unreadable and unlink-blocked-while-present outcomes. While the list
is non-empty, **every poll that observes a lock at the lock path also reads
its line 1**; a LISTED token there ⇒ that leaked claim of ours was installed
by a rival's rename ⇒ adopt that token as the hold token — adoption DROPS
the entry (the leaked claim became our lock; the leak is resolved) — and
proceed to the acquire read-back verification (HOLD). An entry is removed
only when the leak resolves verifiably: adoption as above, a verified
unlink of the claim, or an observation
that the claim path is gone or foreign-tokened — that observation followed
by one lock-path line-1 read (the one-shot discovery pattern: gone-from-
`.next` may mean installed-at-lock) before the entry is dropped. Soundness:
per-attempt token uniqueness (below) means each listed token names exactly
one file ever written, and a token absent from both paths can never
reappear. Cost: the list is almost always empty; the extra per-poll read
happens only in the anomalous state. The discovery rule's one-shot final
read stays (cheap, immediate); the memory turns it from one-shot into
continuous for exactly the lanes where one-shot wasn't conclusive.

Scope: the set persists for the **lifetime of the acquire — through a
successful hold and into release**, not just the wait loop. A successful
acquire on ANOTHER token (normal create or steal) must NOT clear it: the
round-5 walk — B leaks token L (deletion-blocked lane), the lock goes
absent (live-slow release), B normal-creates token N and returns SUCCESS,
a suspended rival later renames `.next` (containing L) over the lock,
displacing B's held N and installing unowned L — would otherwise leave a
live-process unowned orphan nobody cleans, contradicting the structural
claim. Wiring: **during the hold** there is no new polling (the holder is
not in a loop); the set just rides along. **At release**, the existing
token verification gains one branch: if the lock's line 1 is not our hold
token but IS a member of our leaked set, the installed file is — by
per-attempt token uniqueness — OUR leaked claim. The cleanup unlink
inherits the ours-path release mitigations (round-6 fold; Codex's walk: an
installed L can be instantly stale — residual 3 — so a successor can steal
L and install its own lock between our leaked-token read and our unlink,
which a naive unlink would delete): perform the same immediately-before-
unlink re-read the ours-path does (the sh:909-911 class); if the re-read
no longer shows the leaked token (a successor stole or replaced it — under
this protocol the successor's rename destroys L, resolving the leak) → do
NOT unlink, drop the entry, classification unchanged; if it still shows
the leaked token → unlink it (we own it; best-effort cleanup — usually the
orphan is gone immediately, but not guaranteed), with the ours-path's
bounded-retry + LEFTOVER-warning behavior on a blocked unlink. Either way
classify the release as the existing stolen-mid-hold verdict (**98** — our
actual hold WAS displaced; the caller's command must be redone) and log
the leaked-claim cleanup. The remaining read→unlink boundary gap (a
successor's steal landing inside it) is inventoried as the SAME residual
class as the existing release boundary gap (see the implementation
headers' probe-D1 / boundary-gap discussion), detected at the successor's
read-back. A leaked-set member found at the lock during a LATER acquire
attempt by the same process keeps the adoption semantics above (HOLD,
entry dropped). **Arc-end resolution pass** (round-6 narrowing): at
release — and at the 97 exit — perform one best-effort token-checked
resolution pass over each still-pending entry's CLAIM file (the blocking
handle may have closed by then): a verified unlink or a gone/foreign
observation (plus the one-shot lock read) resolves the entry; any failure
leaves it pending — no waiting, no retry loop. Entry lifetime: entries
drop on verifiable resolution (as above); otherwise they live until
process exit, and a leaked token left installed at the lock path can still
be adopted by this process's NEXT acquire. Entries still pending when the
arc ends — 97, clean release, or death — leave those claims to the
next-acquire adoption and the staleness backstops, the same bounded class
as residual 5. (Rejected alternative, from round 5:
blocking a successful acquire's return until every leaked entry resolves
would close the same hole, but it stalls a healthy acquire unboundedly
behind e.g. an AV-held no-delete-share handle — rejected.)

**Trap-time claim cleanup (global rule; best-effort — trappable exits
don't leak, except the blocked-unlink case, which joins residual 5's
bounded class).** The existing EXIT/INT/TERM trap machinery (which today
releases a held LOCK; the bash handlers are installed only once HELD, sh
~599–610) gains a claim-window mode covering the post-claim-create region:
on a trappable exit while a claim attempt is in flight, the handler
performs the token-checked claim deletion — with ONE bounded retry if the
unlink fails with the file still present (the trap is exiting; it cannot
wait out a no-delete-share blockage) — and then the final discovery read;
on a discovery-HOLD inside the trap, adopt the hold and release per normal
trap semantics. If the claim remains present-and-ours-but-undeletable
after the retry, the process exits leaving it — explicitly inventoried as
residual-5 class (bounded ≤ STALE after ageing; no false success). So a
TERM'd claimant normally neither leaks its claim nor leaves an
installed-but-unreleased lock; the blocked-unlink exit is the bounded
exception. Micro-exception: a signal landing mid-claim-create can leave an
empty/torn claim the token-checked deletion correctly refuses to delete —
it ages out ≤ CLAIM_STALE (a steals-only delay). Explicitly: NO trap path
runs lock-release semantics on a mere claim (no 98-classification — a
claim is not a hold), and signal-time deletion still obeys the
token-checked deletion rule like every other deletion path.

**Per-claim-attempt tokens (global rule; makes the discovery premise sound).**
The discovery rule rides on "own token at the lock ⇒ our claim was installed"
— unsound with tokens as the code generates them today: once per ACQUIRE
(`_LOCK_TOKEN="tok.$$.${RANDOM}.$start"`, sh:529; analogous ps1:618), reused
across attempts. The acquire-verification-failure lane (sh ~612, ps1 ~683)
can abandon a lock file carrying OUR token while we keep waiting; an aged
abandoned own-token lock would then satisfy a later discovery read and
manufacture a double hold (plus the p≈2^-15 cross-acquire RANDOM collision
against a release-leftover). Fix: **the claim is created with a fresh token
generated for that claim attempt**; on a successful install or a
discovery-HOLD, that claim token becomes the hold token (release verifies
against it). That upgrades the premise to an equivalence with explicit scope:
own-token-at-lock ⇔ THIS claim was installed, because the token has never
been written anywhere else. Implementation detail: the read-back/release
machinery must use the per-attempt token variable, not a per-acquire
constant. Decision: normal (non-steal) creates go per-attempt too — fresh
token per attempt everywhere, for uniformity — which also fixes the
abandoned-lock aliasing for plain creates (a verification-failure-abandoned
lock aliasing a later create attempt's read-back).

#### Rename-failure lanes

- **Source (claim) gone at rename** → the ownership-discovery rule (this
  lane is simply one case of the global rule): our token at the lock path →
  a rival's rename installed our claim file as the lock; per-claim-attempt
  token uniqueness makes this sound — **we HOLD the lock**; proceed to the
  read-back verification. Foreign/absent → our claim was abandoned/cleared;
  re-poll.

  Self-healing here is structural, not a property of this lane alone: per
  the ownership-discovery rule, whichever claim file gets installed at the
  lock path, its token's owner runs the final discovery read on whatever
  exit path it happens to take — the rule is position-blind, so no
  enumeration of positions is load-bearing — and everyone else reads a
  foreign token and backs off — **no unowned orphan is possible from a
  process actively inside an acquire/hold/release arc** (the leaked-token
  memory — riding into the hold and the release path — covers the exits
  whose one-shot read is inconclusive; trappable exits clean up best-effort
  via the trap-time rule; untrappable death, the trap's blocked-unlink
  case, and entries still pending after the arc ends are residual 5). That
  answers round 1's wedge scenario structurally, not probabilistically.
- **Destination wrong-type** (rename onto a directory fails) →
  `CLAIM-ABORT (rename-refused)`, token-checked claim deletion, damped
  warning, re-poll; the next poll's wrong-type guard classifies the object.
- **Rename blocked** (Windows sharing violation / a no-delete-share handle on
  the ghost — the existing blocked-steal lane) → keep today's handling:
  token-checked claim deletion, damped once-per-stale-window `steal FAILED`
  log, re-poll, honour MAX_WAIT. A failed steal must NOT cost a 60s
  claim-stale delay — the claimant deletes its own claim immediately rather
  than leaving it to age out.

### Claim staleness (the "free-for-all" backstop)

- New knob `AGENT_LOCK_CLAIM_STALE_SECS`, default **60** (claims are held for
  milliseconds; 60s says "claimant crashed").
- A claim older than the window, judged by the same mtime+floor rules, and
  **claim-shaped** (empty, or `tok.`-prefixed line 1) is unlinked by any
  waiter, which then re-races the claim create. The never-steal wrong-type
  guards (directory/symlink/FIFO/socket/device, with the two-consecutive-poll
  confirmation) apply to the claim path exactly as to the lock path — refuse +
  loud config warning, never delete what we can't identify.
- **Per-path guard state**: the wrong-type classifier's two-consecutive-poll
  confirmation state and warn-once flag are today single lock-path-shaped
  variables (`nonlock_prev`, `_LOCK_NONLOCK_WARNED`). They must become
  per-path (lock vs. claim) — a shared flag would cross-suppress the warning
  or cross-confirm the two-poll state between the two paths.
- A crashed claimant (with the trap-time cleanup rule, only an UNTRAPPABLY
  crashed one) therefore delays only *steals* by ≤ the claim window; normal
  acquisition on a free path is never blocked by a claim.
- Knob relation: worst-case recovery = `AGENT_LOCK_STALE_SECS` +
  `AGENT_LOCK_CLAIM_STALE_SECS` must stay < `AGENT_LOCK_MAX_WAIT` (defaults:
  300 + 60 < 420 ✓). Warn-once at startup when `MAX_WAIT ≤ STALE +
  CLAIM_STALE`, but **only when MAX_WAIT was left at its default** — a
  caller who set both knobs chose the relationship deliberately. This new
  warning **REPLACES** the existing `STALE ≥ MAX_WAIT` warning
  (git-commit-lock.sh:300-307): it strictly subsumes it, under the same
  left-default explicitness gate. Consequence: tight-knob tests must set
  `AGENT_LOCK_CLAIM_STALE_SECS` alongside the other knobs.

### Crash-lane inventory

| Crash point | Outcome |
|-------------|---------|
| After claim create, before rename | **Trappable exit** (EXIT/INT/TERM): the trap deletes the claim (token-checked, one bounded retry) + runs the final discovery read; a discovery-HOLD is released per normal trap semantics — no leak, no CLAIM_STALE penalty. Best-effort: if the unlink stays blocked-while-present, the process exits leaving the claim → residual 5's bounded class. A signal landing mid-claim-create can leave an empty/torn claim the trap's token-checked deletion correctly refuses → next row. **Untrappable death** (SIGKILL/power): claim ages out (≤60s), steals resume; if a suspended rival installs it first → residual 5. |
| Between claim create and content write | Empty/torn claim file (untrappable death mid-create, or the trappable mid-create signal above); the empty-orphan + staleness rules clear it — ages out ≤ CLAIM_STALE, a steals-only delay. |
| After rename-over | Stealer is now just a normal holder that crashed; lock staleness rules apply. No grave exists at any point. |

### Residual races (all detected, none silent — replaces the wave-1 entries)

1. **verify→rename gap**: a live-slow holder releases between our re-verify
   and our rename, and a waiter's create lands in that same instant; our
   rename-over then replaces that fresh lock. The displaced winner detects via
   the acquire read-back (if still inside it) or at release (98). The window
   is a few ms; it does contain forks (the mtime stat is a command
   substitution, `mv` is an exec), but it is strictly narrower than the
   pre-wave-1 race and the same class as wave 1's unrestorable residual.
2. **recheck→rename gap**: the step-3.1 recheck bounds what a clearer can
   legitimately act on (at the recheck our claim is younger than
   CLAIM_STALE) — but a clearer whose staleness read predates the recheck
   (the touch does not defend this either) can still clear our claim and
   let a rival claim inside the recheck→rename gap. Every such two-claimant
   interleaving is **self-healing** per the ownership-discovery rule:
   exactly one claim file ends up installed, its token's live owner
   discovers ownership on whatever exit path it takes (discovery read or
   leaked-token memory), everyone else detects a foreign token — no unowned
   orphan is possible from a process inside its acquire/hold/release arc
   (untrappable death and post-arc pending entries are residual 5);
   any displacement degrades into the detected-98 lane. No infinite regress.
   (Decision: no recheck margin — the discovery rule makes the gap-frequency
   question moot.)
3. **Lease rule**: the installed lock's lease starts at the claim's
   step-3.2 touch (rename preserves mtime). A claimant suspended between
   touch and rename installs a correspondingly aged-mtime lock — the lease
   shortfall is bounded by the touch→rename gap (milliseconds when not
   suspended), not "always ~full lease". That ms bound describes only the
   self-rename case: when a RIVAL renames our claim in (a discovery-HOLD),
   the installed lock's age is the claim's age at the rival's rename —
   bounded only by the next poll; worst case an instantly-stale install,
   self-healing via the next steal, detected.
4. **Version skew**: prevention holds only when *all* parties in a tree run
   the claim protocol. A mixed-version tree (an old stealer doing mv-to-grave)
   degrades to detection (98) and can leave grave litter the new code does not
   sweep — upgrade both implementations together (one doc line).
5. **Untrappable death inside the claim window — deliberately accepted, NOT
   prevented.** A claimant killed untrappably (SIGKILL, power loss) after
   the claim create can leave a claim that a suspended rival's rename later
   installs → an unowned fresh lock stalling waiters ≤ STALE, recovered by
   normal staleness; **no false success anywhere** — nobody believes they
   hold, nothing corrupts, the stall is the only cost. The same outcome
   class covers leaked-token-memory entries still pending after the arc
   ends — 97, clean release, or death — until the owner's next acquire
   adopts the token or staleness recovers (round-6 walk: B leaks L,
   releases cleanly or at 97, lives on between acquires; a suspended rival
   installs L afterwards — no discovery mechanism runs outside the arc; the
   arc-end resolution pass narrows this window but cannot close it), and a
   trap-time claim deletion left blocked-while-
   present after its one bounded retry (the exiting trap cannot wait out the
   blockage — see the trap-time rule). Why accepted: this is the same magnitude as the
   tool's FUNDAMENTAL accepted cost — a crashed holder already stalls a full
   STALE window — at far lower probability (death inside a ms-wide window
   AND a suspended rival poised to install). The structural alternative that
   would prevent it (capture-verify-install) was considered and REJECTED —
   see Alternatives considered.
6. Existing residuals unrelated to stealing (release-time classification,
   delete-blocked leftovers, FILETIME-zero floor) are unchanged.

### What gets removed (precise inventory)

(Line cites here and throughout the plan: verify every file:line cite at
implementation time — the tree moves; `13166e2` alone shifted the docs
test-inventory and golden-rule passages.)

- Grave files, the grave naming, and the age-gated grave sweep — and with the
  sweep, **suite T15** (grave-sweep test) is deleted. (Not to be confused
  with plan test 15, the no-`File.Replace` check; see the labeling note in
  the Test plan.)
- Grave-token comparison, the `STEAL-DISPLACED-LIVE` lane, hard-link restore,
  and the wave-1 RESTORE-GRACE **outer loop** (sh 589–598, ps1 668–675) —
  both impls. **KEEP** `_lock_cur_token`'s internal empty-read retry ladder
  (pre-wave-1, probe F); only the outer grace loop goes.
- Docs: the test-inventory passage (docs/git-commit-lock.md ~441–466 pre-
  `13166e2`) and the README recovery sentences (~67–72) both describe
  restore — both are rewritten, not just the lease sentence.
- The ps1 header's PORT-SPECIFIC hard-link probe notes (~74–91) go with the
  header rewrite.
- Wave-1 **suite T2b** (unit) and **suite T16** (interop) are **kept and
  adapted** — they are the regression harness that proves the new protocol:
  same scenario (1
  ancient stale lock + N waiters, tight knobs), new assertions (exactly one
  steal per recovery, zero displacements, zero spurious 98s, no claim/grave
  leftovers).

## Implementation notes

### bash (`git-commit-lock.sh`)

- `mv` on the same NTFS volume maps to MoveFileEx(REPLACE_EXISTING) under
  MSYS — **probe before building**: tight reader loop asserting the lock path
  never reads absent across the replace, and content flips atomically
  ghost→ours.
- Rename-over onto a *directory* fails → the `rename-refused` lane above.
- Reuse the existing helpers: token generation (**moved to per
  claim/create attempt** — see Per-claim-attempt tokens; the per-acquire
  `_LOCK_TOKEN` assignment at sh:529 / ps1:618 goes), write-through-create,
  read ladder, mtime read + floor, wrong-type classifier — **parameterized
  by path, with per-path confirmation/warn-once state** (see Claim
  staleness).

### PowerShell (`git-commit-lock.ps1`)

- pwsh 7 / .NET Core: `[IO.File]::Move($src, $dst, $true)` (atomic overwrite
  overload) — probe on NTFS as for bash. bash keeps `mv`.
- Windows PowerShell 5.1 / .NET Framework: **no `File.Replace`** — round-1
  review showed it is unsafe here (throws on a read-only destination, and has
  partial-failure states when called without a backup file). Instead the 5.1
  steal completes as: **unlink the ghost, then `File.Move` (fail-if-exists)
  the claim in**. The transient absent window between unlink and Move is
  *safe under the claim*: a rival waiter's create landing in that window
  merely wins the lock — our Move fails-if-exists → token-checked claim
  deletion, re-poll. A fairness loss (the claimant did the recovery work and
  lost the lock), never a clobber. Ladder sub-lanes: (a) the ghost unlink
  finds the lock already gone (the live-slow holder released first) →
  `CLAIM-ABORT (gone)` for symmetry with step 4(a), routing as 4(a) does:
  token-checked claim deletion, then the final discovery read, then re-race;
  do NOT proceed to the Move. (b) the ghost unlink is blocked by a
  no-delete-share handle → the existing damped blocked-steal lane
  (token-checked claim deletion, damped log, re-poll).
- ps1-on-POSIX residual (extends the existing PORT-SPECIFIC notes): a
  FIFO/device/socket at the **claim** path stats as size 0 there and takes the
  empty-claim clear lane — damage capped at the one misconfigured inode,
  CI-only configuration. Consequence for tests: the claim wrong-type
  "refused" assertion is bash-only.
- Keep strictly ASCII; keep 5.1-compatible syntax.

### Both impls: claim-window traps, the hold helper, the memory

- **Claim-window trap coverage**: today the handlers exist only for holds
  (bash `_lock_on_exit` / `_lock_on_signal`, saved+installed only once HELD,
  sh ~599–610; ps1 analog). They gain the claim-window mode of the trap-time
  cleanup rule: install before the claim create — the handler is
  token-checked, so a signal landing pre-create or post-resolve is a
  harmless no-op — and restore the caller's traps when the attempt resolves
  without a hold (the existing `_LOCK_SAVED_TRAP_*` save/restore mechanics,
  sh ~319–323, extended with a claim-in-flight vs. held state distinction).
- **Shared "claim the hold" helper**: setting `_LOCK_HELD`, saving +
  installing the hold traps, adopting the attempt token as the hold token,
  and the ACQUIRED log line live in ONE helper used by all three acquisition
  paths — create read-back, steal rename-over, and discovery-HOLD — so
  steal-acquired and discovery-acquired holds run the same HELD/trap-install
  machinery as create-acquired ones (plan test 24 asserts the parity).
- **Leaked-token memory**: an in-process structure (bash array / ps1 list),
  empty in the common case. NOT cleared when the acquire returns
  successfully — it rides into the hold and is consulted by the release
  path's leaked-claim branch (see the memory rule); entries drop on
  verifiable resolution (including adoption) or at process exit; release
  and the 97 exit run the one best-effort arc-end resolution pass over
  pending entries' claim files (no waiting — see the memory rule).

### Probes (phase 1)

- bash `mv` replace atomicity on NTFS (no-absent-window, atomic content flip).
- pwsh 7 overwrite-`Move` atomicity, same assertions.
- **Post-rename lock mtime freshness**: from bash `mv`, pwsh 7
  overwrite-Move, AND the 5.1 `File.Move` leg, confirm rename preserves the
  claim's just-touched mtime (the lease rule rides on it in all three
  lanes).
- **5.1 `File.Move` fail-if-exists atomicity** (exactly one of N concurrent
  Moves onto one destination wins).
- **`touch` semantics on the claim from both runtimes** (bash `touch -c` +
  explicit existence check, ps1 `[IO.File]::SetLastWriteTimeUtc` catching
  FileNotFound): mtime visibly refreshed, content untouched, **a missing
  target is NOT created**, AND **the implementation's gone-detection
  actually fires on a missing target** — bash via the `[ -e ]` check (NOT
  the exit code: `touch -c missing` exits 0 per POSIX), ps1 via the
  FileNotFound catch. Exit-code reliance must fail this probe.
- (Dropped: all `File.Replace` probes.)

Abort criteria: if rename-over is not reliably atomic-no-absent-window on NTFS
from bash/pwsh 7, **or the installed lock's mtime is not the claim's fresh
mtime**, fall back to Ben's original grave variant (claim still prevents the
race; the no-absent-window and lease-touch bonuses are lost).

### Logging (design, per house rules)

To the existing lock log (same damping conventions):
- `CLAIM <path> tok=<attempt token> by <owner>` on claim create. The token
  is required: per-claim-attempt tokens make the once-per-acquire WAITING
  token line insufficient for reconstructing discovery-HOLDs, and the
  unowned-orphan forensics (plan test 21) rides on it — a log reader can
  identify an unowned lock's token as a leaked claim token.
- `CLAIM-ABORT (<reason>)` — reasons enum:
  `fresh | gone | wrong-type | rename-refused | contested`.
- `STOLE-BY-CLAIM <lockpath> ghost=<ghost line2> by <owner>` on the rename-over
  (replaces the old STOLE line). Attribution caveat: this names the last
  *verified* ghost (from the step-3.3 re-read); residual 1's verify→rename gap
  means the object actually replaced could in principle differ — the log claim
  and the residual inventory must stay consistent (no "always the true ghost /
  no displacement possible" wording).
- `CLAIM-STALE-CLEARED <path> age=<s>` when a stale claim is unlinked.
- `RELEASE-CLEANED-LEAKED-CLAIM <lockpath> tok=<leaked token>` when the
  release path's leaked-claim branch unlinks our installed leaked claim
  (alongside the existing stolen-mid-hold 98 classification — plan test 25
  asserts the line fires). The branch's pre-unlink re-read finding the
  token already replaced drops the entry WITHOUT this line (still 98); a
  blocked unlink takes the ours-path LEFTOVER warning.
- Damping: the `rename-refused` and blocked-steal lanes use the existing
  once-per-stale-window damper; existing damping on the other contended lanes
  unchanged.

## Test plan

Labeling: numbered items in this list are **plan test nn**; tests already in
the suites are **suite Tnn** — the two numberings are unrelated (e.g. suite
T15 is the deleted grave-sweep test; plan test 15 is the no-`File.Replace`
check).

Unit (`git-commit-lock.test.sh`):
1. Claim contention: N concurrent stealers over one ancient ghost → exactly one
   claim winner, one `STOLE-BY-CLAIM`, N−1 `CLAIM`-failed waiters that then
   acquire normally in sequence; no leftovers.
2. Adapted suite T2b multi-waiter recovery: zero spurious 98s, zero displacement
   lines, clean final state (mutation check: must fail against the wave-1
   implementation — e.g. by asserting no grave file is ever created and the
   STOLE-BY-CLAIM line shape).
3. Crashed claimant: plant an aged claim file → a waiter clears it
   (`CLAIM-STALE-CLEARED`) and completes the steal; recovery latency bounded.
4. Empty claim orphan: ages out via the same lane.
5. Claim wrong-type guards: directory/symlink/FIFO at `${LOCK}.next` → refused,
   warned once (two-consecutive-poll), steals blocked, normal acquire on a
   free lock path UNaffected. (bash-only for FIFO/device/socket; see the
   ps1-on-POSIX residual note.)
6. Live-slow holder: claim + re-verify sees fresh mtime → `CLAIM-ABORT
   (fresh)`, no steal; the slow holder releases normally.
7. Knob validation: `AGENT_LOCK_CLAIM_STALE_SECS` numeric checks; the
   `MAX_WAIT ≤ STALE + CLAIM_STALE` warning fires when MAX_WAIT is default and
   stays silent when MAX_WAIT was set explicitly.
8. **Aged-claim contested abort**: suspended claimant (backdated own claim) →
   the step-3.1 recheck finds it overaged → `CLAIM-ABORT (contested)`, NO
   rename (mutation check: an implementation that proceeds on an overaged
   claim must fail this).
9. **Discovery-position matrix**: steer a victim claimant to EACH discovery
   position, asserting in every case exactly one final owner, everyone else
   backs off, and no unowned lock. Each position is listed with the
   interleaving that actually reaches it — the v3 steering ("a clearer + a
   rival act AFTER the claimant's recheck passes") cannot reach
   step-2-fresh, since step 2 precedes the recheck. Setting: claimant A
   claims and passes its recheck; a clearer (staleness read predating A's
   touch) clears A's claim; victim B claims; A's delayed rename installs
   B's claim as the lock. Positions = where B sits when A's rename lands:
   - **step-2-fresh**: B sits BEFORE its own step-2 re-verify; its re-read
     finds a lock that looks fresh — with B's own token (→ 4(b) → HOLD).
   - **recheck-gone**: B has passed step 2; A's rename lands before B's
     step-3.1 recheck, which finds the claim gone.
   - **touch-target-gone**: A's rename lands between B's passing recheck
     and its step-3.2 touch — exercise the bash existence-check lane and
     the ps1 FileNotFound lane separately.
   - **step-4(a) lock-gone**: B's re-verify finds the lock GONE (live-slow
     holder released); A's rename lands before B's deletion + final read.
   - **contested-abort**: B's recheck finds its own claim overaged; A's
     rename lands between that read and B's deletion.
   - **token-checked-deletion-gone**: A's rename lands between the
     deletion's passing read and its unlink (the ENOENT lane).
   - **rename-source-gone**: A's rename lands between B's step-3.3
     re-verify and B's own rename.

   Every discovery-HOLD outcome in this matrix additionally asserts the
   discovered owner's `lock_release` returns **0** — no spurious 98 (an
   implementation keeping a per-acquire token for release must fail this).
10. **Delayed-claim lease**: claim aged close to CLAIM_STALE, then recovery →
    the installed lock's mtime is fresh (the step-3.2 touch), the holder gets
    a full lease.
11. **Step-4a abort-on-gone**: live-slow holder releases under a claimant →
    `CLAIM-ABORT (gone)`, NO install on the absent path (mutation check: an
    implementation that renames onto the absent path must fail this).
12. **Claim mtime floor**: a sub-floor claim mtime is NOT cleared — treated as
    just-created.
13. **Per-path guard state**: a lock-path wrong-type warning must not suppress
    a claim-path warning, and vice versa (warn-once and two-poll confirmation
    are independent per path).
14. **Blocked-steal claim cleanup**: the deterministic blocked-steal test
    gains an assertion that the claim is deleted immediately after the failed
    rename — no 60s ageout penalty.
15. **No-`File.Replace` static check**: assert `git-commit-lock.ps1` contains
    no `File.Replace` (anti-regression for the round-1-rejected primitive).
16. **Non-creating-touch static check**: assert the bash steal lane touches
    via `touch -c` followed by an explicit existence check, and the ps1 lane
    catches FileNotFound — a creating-touch implementation must fail the
    suite (static grep is acceptable, mirroring plan test 15's
    no-`File.Replace` check).

(Plan tests 21–25 are unit tests too, numbered past the interop block —
which keeps 17–20 — to avoid a second renumbering.)

21. **Leaked-claim discovery**: force a leaked-claim exit — the
    unreadable/undeletable-claim lane, via the suites' existing
    no-delete-share handle helper pattern — then steer a rival install of
    the leaked claim; assert the leaver discovers via the leaked-token
    memory (HOLD, and `lock_release` returns 0). Harness note (tests 21
    and 25): the leak-manufacturing no-delete-share handle ALSO blocks the
    rival's rename of that claim (probe D1) — the harness must close the
    handle before steering the install. **Steering variant**: the
    rival install lands between the leaver's poll-read and its NEXT claim
    create, so the leaver runs one full aborting claim attempt before
    discovery — assert HOLD by the following poll and release rc 0
    (mutation check: an implementation that drops memory entries on a
    claim-attempt abort must fail this). **Crashed-leaver variant**:
    kill the leaver untrappably after the leak → assert the bounded-orphan
    outcome (the unowned lock ages out; waiters recover at staleness; the
    log's `CLAIM ... tok=` line identifies the unowned lock's token as a
    claim token, for forensics).
22. **Per-attempt token regression** (Codex): force an abandoned own-token
    lock via a failed acquire read-back, then run a later claim attempt by
    the same process — assert the old token is NOT treated as current (no
    false discovery-HOLD), and that release verifies against the
    per-attempt token (a reused-per-acquire-token implementation must fail
    this test).
23. **TERM-mid-claim**: claimant killed with TERM between claim create and
    rename → the claim is deleted by the trap (or discovery-HOLD + released
    per trap semantics); assert no claim leftover and no 60s ageout penalty
    for the next stealer. **Blocked-unlink variant** (Codex round 5): TERM
    lands while the claim's unlink is blocked (the no-delete-share helper)
    → the process exits leaving the claim; assert it ages out and the next
    stealer recovers at CLAIM_STALE — bounded residual-5 behavior, no
    machinery pretending otherwise. **Foreign-claim leg** (Claude round 5):
    a foreign-token claim planted before the TERM survives the dying
    claimant's trap (kills a blind-unlink trap implementation).
24. **Steal-acquired-hold trap parity**: extend an existing TERM-release
    test to a steal-acquired hold — TERM on a steal-acquired holder releases
    cleanly, exactly as for a create-acquired hold (the shared
    claim-the-hold helper; see Implementation notes).
25. **Release-time leaked-claim cleanup** (Codex round 5): B leaks token L
    (no-delete-share lane), then acquires a fresh token N normally; a
    steered rival installs L over the lock, displacing B's held N; B's
    release → returns 98 AND B unlinks L — assert the lock path is clean
    immediately after B's release (no STALE stall in the unblocked case)
    and the `RELEASE-CLEANED-LEAKED-CLAIM` log line fired. (Same
    handle-close steering note as test 21.) **Boundary variant** (round
    6): the leaked L is installed with an instantly-stale mtime; a
    successor steal is steered between B's leaked-token verification and
    its cleanup unlink — assert B does NOT delete the successor's lock
    (the pre-unlink re-read backs off, entry dropped) and B's release
    still classifies 98.

Interop (`git-commit-lock.interop.test.sh`):
17. bash claimant vs ps1 claimant racing one ghost → one winner, both sides
    parse each other's claim files (wire format), loser waits correctly.
18. Cross-impl claim-staleness agreement: each side clears the other's aged
    claim.
19. Adapted suite T16 (as the adapted suite T2b above, mixed runtimes).
20. 5.1 lane: the **unlink+`File.Move` ladder** exercised under `powershell`
    where available (skip-with-note elsewhere). The suite already has a 5.1
    smoke lane — suite interop Test 17, landed in `51e55a3` — hook into it.

The 5.1 absent-window fairness case (a rival's create winning inside the
unlink→Move window) is deliberately left untested — non-deterministic, and
benign by design.

Integration: unchanged scenario; the final no-leftover sweep gains `*.next`
alongside the existing no-leftover-lock check.

Tight-knob tests across all suites set `AGENT_LOCK_CLAIM_STALE_SECS` alongside
the existing knobs (the warning gate assumes coherent explicit settings).

All three suites green (REDUCED locally, FULL is CI's job), shellcheck
`-S info` (the CI gate since `51e55a3`) + PSScriptAnalyzer clean.

## Docs

- `docs/git-commit-lock.md`: rewrite the steal bullet + "The protocol in
  detail" steal/grave passages for claim+rename-over; update the residual
  inventory and the golden-rule recovery paragraph (wave-1 text); rewrite the
  test-inventory passage (~441–466); knobs table gains
  `AGENT_LOCK_CLAIM_STALE_SECS`; one version-skew line (upgrade both impls
  together).
- `README.md`: rewrite the recovery sentences in "How it works" (~67–72) —
  recovery is serialized by a claim and hands the lock to the recovering
  waiter; a clause or two, not a protocol dump.
- Both implementation headers: protocol description + residual inventory
  rewrite; the ps1 header drops the hard-link probe notes (~74–91) and gains
  the 5.1 unlink+Move lane and the claim-path POSIX residual.

## Alternatives considered

- **Ben's original (claim file + mv-to-grave + re-race)**: same prevention
  property; keeps graves, keeps the path-absent recovery window and the create
  re-race, claimant may lose the lock it recovered. Rename-over strictly
  improves on those without weakening anything identified. (Retained as the
  probe-failure fallback.)
- **Wave-1 detect+restore (currently in tree)**: repair, not prevention;
  near-certain displacement under contended recovery repaired by hard-link
  restore; three subtle mechanisms; hard-link dependency. Superseded.
- **`File.Replace` for the 5.1 lane**: rejected in round 1 — read-only
  destination throws; partial-failure states without a backup file. The
  unlink+fail-if-exists-Move ladder is safe under the claim (see notes).
- **Capture-verify-install (two-rename compare-and-swap)** — for residual
  5's untrappable-death lane: rename the claim to a private per-claimant
  name, verify our own token there, only then rename into the lock. This
  makes installing a FOREIGN claim impossible (closing the residual), but it
  reintroduces crash-litter at private names and therefore an age-gated
  sweep — the exact machinery class this redesign removes — to close a
  residual that is already bounded, detected, false-success-free, and rarer
  than the accepted crashed-holder stall. Rejected.
- **Ticket queue** (`commit.lock.d/<ts>.<token>`, lowest non-stale ticket
  holds): no destructive steal at all, FIFO fairness — but a total wire-format
  rewrite, "lowest non-stale" must be evaluated identically across runtimes,
  and it reintroduces directory semantics + deleting-others'-files on Windows
  (delete-pending ghosts as routine). Rejected for this project's stage.

## Decisions adopted (round-1 open questions, silence = adopt)

1. Claim suffix `.next`. 2. `AGENT_LOCK_CLAIM_STALE_SECS` default 60s.
3. Knob relation: warn-once, gated on MAX_WAIT being default (not a hard
   error).

## Coordination

Waves landed since this plan was first written; the implementation builds on
them, not around them:
- Interop suite now has **suite Test 7b** (ps1 exit verdicts) and **suite
  Test 17** (Windows PowerShell 5.1 smoke lane) from `51e55a3` — the 5.1
  steal-ladder test (plan test 20) hooks into that lane rather than
  duplicating detection.
- Integration test uses **per-worker lock logs** from `0339dbe` — new
  assertions (e.g. the `*.next` no-leftover sweep) follow that structure.
- **Wave C (read-ladder parity) landed as `d40616f`**: shared 8-attempt
  20→320ms-capped retry schedule (≈1.26s) at release/read-back only;
  sourced-outside-a-repo warns on stderr and creates no file; `--help` →
  stdout/exit 0 in both impls; the doc's ladder definition updated. The
  implementation builds on that tree state.
- **`13166e2`**: the docs security / trust-assumptions section landed; the
  docs test-inventory and golden-rule line numbers cited in the removal
  inventory shifted accordingly (see the verify-cites caveat there).

## Phases

1. Probes (see "Probes" above) — recorded in the changelog; abort criteria as
   stated there.
2. bash implementation + unit tests (incl. the removal inventory).
3. ps1 port + interop tests.
4. Docs + README + headers.
5. Full suites, shellcheck/PSScriptAnalyzer, review/fix cycles (fresh Claude +
   Codex) to clean.

Changelog: `.plans/2026-06-11-aa-claude-a-steal-claim-changelog.md` during
implementation.

## Review history

- **Round 1 (2026-06-11)**: two independent reviewers (fresh Claude + Codex).
  Three blocking defect families: (1) stale-claim TOCTOU / unowned-orphan
  wedge (both reviewers' top finding) → claim recheck + token-checked
  deletions + self-healing rename-failure lanes; (2) aged lease at install →
  the pre-rename claim touch + lease rule + probe; (3) `File.Replace` unsafe
  on 5.1 (Codex) → unlink+fail-if-exists-Move ladder. Plus guard/knob/logging
  /test-coverage findings (per-path guard state, claim-path pre-create type
  guard, MAX_WAIT warning gate, attribution softening, CLAIM-ABORT enum,
  six test additions, precise removal inventory, version-skew note,
  coordination with `51e55a3`/`0339dbe`). All folded into v2.
- **Round 2 (2026-06-11)**: fresh Claude (2 blocking + 6 non-blocking) +
  Codex (0 blocking + 3 non-blocking); all folded into v3. Blocking family —
  make self-healing structural: (1) v2 wired own-token discovery into only
  the rename-source-gone lane, leaving three of the four positions a
  claimant can occupy when a rival's rename installs its claim (recheck-gone,
  step-2/3.3 fresh-abort, touch-target-gone) to orphan an own-token lock for
  a full STALE window → the global ownership-discovery rule on every
  post-claim-create exit path; (2) a creating `touch` would resurrect a
  vanished claim as an empty `${LOCK}.next` blocking all steals and masking
  the gone signal → non-creating touch (`touch -c` /
  `SetLastWriteTimeUtc`+FileNotFound). Non-blocking: residual/lease wording
  accuracy (recheck + discovery rule bound things, not the touch; lease
  shortfall bounded by the touch→rename gap), deletion-gap note, 5.1 ladder
  sub-lanes (unlink-finds-gone → `CLAIM-ABORT (gone)`; unlink-blocked →
  damped blocked-steal lane) + 5.1 `File.Move` mtime-probe leg, test-plan
  splits/additions (contested abort vs. discovery-position matrix,
  blocked-steal cleanup assertion, no-`File.Replace` static check, untested
  5.1 fairness note), stale shellcheck parenthetical dropped, MAX_WAIT
  warning stated as replacing the STALE≥MAX_WAIT warning, wave-C
  (`d40616f`) coordination.
- **Round 3 (2026-06-11)**: fresh Claude (3 blocking + 4 non-blocking) +
  Codex (3 blocking + 1 non-blocking), heavily overlapping — both
  independently converged on the first two blocking findings; all folded
  into v4. Blocking: (1) v3's outcome-keyed discovery wiring provably
  missed exits (step-4(a) lock-gone, deletion-finds-gone, deletion-unlink
  ENOENT, contested abort — a concrete orphan walk through 4(a) was
  exhibited) → the discovery read becomes the **unconditional final act**
  of every post-claim-create exit, run after any claim-deletion attempt;
  per-position wiring demoted to illustration. (2) Per-ACQUIRE token reuse
  (sh:529 / ps1:618) + the acquire-verification-failure lane (sh ~612 /
  ps1 ~683) breaks the discovery premise — an abandoned own-token lock
  satisfies a later discovery read and manufactures a double hold → **fresh
  token per claim/create attempt**; the claim token becomes the hold token;
  own-token-at-lock ⇔ THIS claim installed. (3) `touch -c missing` exits 0
  (POSIX; probed on this box) — the bash gone-at-touch exit-code signal was
  fictional → `touch -c` + explicit existence check (ps1 keeps the
  FileNotFound catch); the touch probe must assert the gone-detection
  actually fires. Test folds: discovery-position matrix extended
  (touch-gone in both runtime lanes, 4(a), contested-abort, deletion-gone)
  with corrected interleavings (v3's steering could not reach
  step-2-fresh); non-creating-touch static check added (plan test 16;
  interop renumbered 17–20). Non-blocking: motivation overclaims scoped to
  the inventoried residuals, line-citation refresh (restore-grace
  sh:589-598 / ps1:668-675; warning sh:300-307) + verify-cites-at-
  implementation-time caveat, suite-Tnn vs plan-test-nn disambiguation,
  residual-3 rival-rename lease clause, `13166e2` coordination.
- **Round 4 (2026-06-11)**: fresh Claude (1 blocking + 3 non-blocking) +
  Codex (3 blocking) — same defect family, independently converging; all
  folded into v5. The defect: v4's conclusiveness argument ("a miss is a
  true miss") requires the claimant to have installed OR verifiably
  unlinked its claim, and three "leave it" exits violate that —
  recheck-unreadable, deletion-read-unreadable, and
  deletion-unlink-fails-while-present (an outcome the deletion rule had
  not specified) — so a leftover claim can be installed by a suspended
  rival's rename AFTER the leaver's final discovery read → unowned
  own-token lock, ≤ STALE stall; same family, a claimant that DIES
  mid-claim can have its claim installed with no discovery possible at
  all. Dispositions: (1) **leaked-token memory** global rule — closes
  every live-process lane (continuous per-poll discovery while the list
  is non-empty; one-shot final read kept); (2) **trap-time claim cleanup**
  — trappable exits delete the claim (token-checked) + run the final
  discovery read, a discovery-HOLD releasing per normal trap semantics;
  explicitly no lock-release/98-classification on a mere claim; (3)
  **untrappable death accepted, NOT prevented** — inventoried as residual
  5 (same magnitude as the fundamental crashed-holder stall, far lower
  probability, no false success); the preventing alternative
  (capture-verify-install, a two-rename compare-and-swap) rejected under
  Alternatives because it reintroduces crash-litter + an age-gated sweep;
  (4) the deletion rule's unlink-blocked-while-present outcome specified
  (→ leaked, damped warning, re-poll); (5) tests: leaked-claim discovery
  + crashed-leaver forensics (plan test 21), per-attempt-token regression
  (22), TERM-mid-claim (23), steal-acquired-hold trap parity (24), and a
  discovery-HOLD release-rc-0 assertion folded into the test-9 matrix;
  (6) `CLAIM` log lines carry `tok=<attempt token>`; (7) "no unowned
  orphan" claims re-scoped everywhere: structural for live processes,
  trap-cleaned for trappable exits, bounded residual for untrappable
  death.
- **Round 5 (2026-06-11)**: fresh Claude judged the design **CONVERGED**
  (2 test folds + 3 wording items, no design defects); Codex found 2
  blocking defects in the v5 memory/trap rules + 1 test finding; all
  folded into v6. Blocking (Codex): (1) the leaked-token memory was
  cleared at acquire return, so a leaker whose acquire later SUCCEEDED on
  another token (leak L → live-slow release → normal-create N → success)
  had no discovery left when a suspended rival renamed `.next` (containing
  L) over the lock — displacing held N, installing unowned L, detected
  only as a 98 at release with nobody cleaning L: a live-process unowned
  orphan contradicting the structural claim → the set persists for the
  **lifetime of the acquire**: it rides into the hold (no new polling) and
  into release, where the token verification gains a branch — lock line 1
  in our leaked set ⇒ unlink it (ours by token uniqueness; orphan cleaned
  immediately) + classify as the existing stolen-mid-hold 98 + log line; a
  leaked member found during a LATER acquire attempt keeps the v5 adoption
  semantics (HOLD); entry lifetime: verifiable resolution or process exit
  (pending-at-exit stays residual-5 class). Codex's preferred
  block-success-until-resolved was REJECTED — it stalls a healthy acquire
  unboundedly behind e.g. an AV-held handle. (2) "trappable exits don't
  leak" was too absolute: a trap-time unlink blocked-while-present cannot
  be waited out by an exiting trap → best-effort cleanup specified (one
  bounded retry + the final discovery read, else exit leaving the claim —
  inventoried residual-5 class, bounded ≤ STALE after ageing, no false
  success), plus the mid-claim-create signal micro-exception (empty/torn
  claim the token-checked deletion correctly refuses → ages out ≤
  CLAIM_STALE, steals-only delay; crash-lane table updated). Test folds:
  test-21 steering variant (Codex + Claude converging — rival install
  between the leaver's poll-read and its next claim create; one aborting
  attempt before discovery; kills drops-entries-on-abort), release-time
  leaked-cleanup test (plan test 25, Codex), test-23 blocked-unlink
  variant (Codex) and foreign-claim leg (Claude). Wording (Claude): memory
  removal-condition ambiguity fixed ("that observation followed by one
  lock-path line-1 read" — the lock-read applies to both gone and foreign
  observations); crash-lane empty/torn row gains the trappable mid-create
  case.
- **Round 6 (2026-06-11, confirmation)**: fresh Claude judged the design
  **CONVERGED** (no mechanism defects; 2 scope/spec folds + 3 polish
  items); Codex found 1 blocking — the SAME item as Claude's second fold,
  independently converging. All folded into v7; prose/spec edits only, no
  mechanism change. (1) The structural no-unowned-orphan claim re-scoped
  from "live process" to "a process actively inside an acquire/hold/release
  arc": the round-6 walk (B leaks L, releases cleanly or at 97, lives on
  between acquires; a suspended rival installs L afterwards) shows none of
  the three discovery mechanisms runs outside the arc — residual 5's
  pending-entries clause extended to "after the arc ends (97, clean
  release, or death), until the owner's next acquire adopts the token or
  staleness recovers"; adopted narrowing: a one-shot best-effort
  token-checked resolution pass over pending entries' claim files at
  release and at the 97 exit (the blocking handle may have closed by then;
  failures leave the entry pending — no waiting). (2) (Claude + Codex
  converging; Codex's walk: an instantly-stale installed L lets a
  successor steal L and install its own lock between B's leaked-token read
  and B's unlink — a naive unlink deletes the successor's live lock) the
  release-path leaked-cleanup unlink inherits the ours-path mitigations:
  the immediately-before-unlink re-read (sh:909-911 class; re-read no
  longer leaked ⇒ no unlink, entry dropped — the successor's rename
  destroyed L — classification still 98), bounded retry + LEFTOVER warning
  on a blocked unlink, "cleans immediately — no STALE stall" softened to
  best-effort; the remaining read→unlink boundary gap inventoried as the
  same residual class as the existing release boundary gap (the headers'
  probe-D1/boundary discussion), detected at the successor's read-back.
  Polish (Claude): adoption of a listed token DROPS its entry; test-21/25
  harness note (the leak-manufacturing no-delete-share handle also blocks
  the rival's rename — probe D1 — close it before steering the install);
  test-21 steering variant asserts HOLD "by" (not "on exactly") the
  following poll. Test fold (Codex): test-25 boundary variant
  (instantly-stale L; successor steal steered between B's leaked-token
  verification and its cleanup unlink; B must not delete the successor's
  lock, release still 98).
