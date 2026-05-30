<!-- agents/details/commit-lock.md | canonical: C:\code\dotfiles\agents\details\commit-lock.md | shared reference | linked from agents/060-committing.md -->

# `commit-lock`: a mutex for committing from a shared working tree

Design reference for the commit lock. Operating rules live in
[`../060-committing.md`](../060-committing.md); read that first. This file is the
"why" and "how it works".

## Scope: lock only, git by hand

The lock is the **only** thing we automate. The git commands — what to stage,
what to commit — are run manually by the agent, under the lock. We deliberately
do **not** ship a commit wrapper: an earlier version did, and teaching it as
*the* way to commit led an agent to treat the wrapper's per-file scope as the
limit of the possible and escalate a one-line commit to the human. The lesson:
the lock is a shared invariant worth packaging; a commit is local git that
should stay flexible. Keep the automated surface minimal.

## The problem

Multiple agents (Claude, Codex, Gemini) often operate in **one** working tree:

- By design in some repos — several agents share a single checkout on `main`.
- **Unavoidably whenever an agent spawns sub-agents.** Sub-agents run in the
  parent's working directory; they do **not** get their own git worktree. So
  even a workflow that gives each *top-level* agent a worktree still has many
  sub-agents sharing each worktree.

A git working tree has exactly one index (`.git/index`, or
`.git/worktrees/<wt>/index`) and one `HEAD`. Concurrent commits therefore:

1. **Race** on `.git/index.lock` ("Unable to create '.../index.lock'"), and
   interleaved `git add`s can stage a half-written state.
2. Tempt **sweep-up** — `git add -A`/`commit -a` captures other agents'
   half-finished work. (Avoided by always naming your own paths, not by the
   lock.)

Worktrees solve this by giving each agent its own index — but sub-agents can't
have worktrees, so we need a lock inside the shared tree.

## How the lock works

`flock` is unavailable in our Cygwin/Git-Bash environment, so the lock is built
from primitives that are atomic on NTFS:

- **acquire** = `mkdir <lock>` — atomic create-or-fail.
- **steal** = `mv <lock> <grave>` — `rename(2)` is atomic, so exactly one
  concurrent stealer wins; the rest get `ENOENT` and re-race the `mkdir`.

**Staleness is judged by the lock directory's own mtime** (stamped atomically by
`mkdir`), via `stat -c %Y` with a `date -r` fallback. A lock older than
`AGENT_LOCK_STALE_SECS` (default **300s / 5 min**) is presumed crashed and may be
stolen, so one dead agent can't wedge the others. We key on the *dir* mtime, not
an `epoch` file inside it, on purpose: an acquirer that dies between `mkdir` and
writing its metadata — or a release whose `rm -rf` only partly completes (a real
intermittent on Windows when another process holds a handle in the dir) — leaves
an orphan with no readable epoch. Keying on a file would make that orphan
un-stealable and hang every waiter to the timeout. (Exactly the bug the
self-test caught 2026-05-30: 3 of 25 workers hung to the 420s cap.) The
`epoch`/`owner` files written inside the dir are for logging only.

**Release** deletes the dir; if `rm -rf` fails it renames the dir aside and
deletes that. Recovery triggers **only** on a non-zero `rm` — while the dir
exists no one else can `mkdir` it, so it is unambiguously ours. We must *not*
re-check after a successful `rm`: a successor may already have re-created the dir
and entered its own critical section, and renaming it aside would steal that live
lock (two holders → lost update — the second bug the self-test caught).

**Location.** The lock and its log default to the repo's git dir
(`git rev-parse --absolute-git-dir`), e.g. `<repo>/.git/commit.lock` and
`<repo>/.git/commit-lock.log`. Never tracked by git (no `.gitignore` needed in
any repo), and correctly scoped: every worktree has its own git dir, so
independent worktrees get independent locks, while all sub-agents sharing one
checkout resolve the same git dir and share one lock.

## API

Source it (`source ~/.agents/bin/commit-lock.sh`) for:

- `lock_acquire` — block until held (steal-if-stale); returns non-zero only on
  the `AGENT_LOCK_MAX_WAIT` timeout. Arms an EXIT/INT/TERM trap that releases.
- `lock_release` — release if held (idempotent).
- `lock_run <cmd...>` — acquire, run the command, always release, propagate its
  exit code. The `run` CLI subcommand is this:
  `commit-lock.sh run -- <cmd...>`.

Config knobs (env, mainly for tests): `AGENT_LOCK_DIR`, `AGENT_LOCK_STALE_SECS`,
`AGENT_LOCK_POLL_SECS`, `AGENT_LOCK_MAX_WAIT`, `AGENT_LOCK_LOG`.

## The golden rule: hold the lock only to commit

The lock must protect a *sub-second* critical section. Decide what to stage,
build any patch, and resolve failures **outside** it. If a commit fails under
the lock (e.g. a pre-commit hook rejects it), unstage your paths
(`git reset -- <paths>`, which never touches the working tree) and
`lock_release` **before** you investigate, then retry. Never acquire the lock
and then read, build, or ask the user.

Never `git stash` in a shared checkout — it rewrites the working tree on disk and
clobbers other agents' uncommitted edits.

## Committing: the manual recipes

Normal case — commit the paths you changed:

```sh
~/.agents/bin/commit-lock.sh run -- bash -c '
  git add -- path/a path/b && git commit -m "msg"'
```

Shared file (you own only part of it) — stage just your hunk, commit the index:

```sh
git diff HEAD -- path/to/file > /tmp/mine.patch   # outside lock; trim to your hunk(s)
~/.agents/bin/commit-lock.sh run -- bash -c '
  git diff --cached --quiet || { echo "index not clean" >&2; exit 1; }
  git apply --cached /tmp/mine.patch && git commit -m "msg"'   # BARE commit
```

`git apply --cached` patches the **index relative to HEAD**, so it isolates your
change even when it shares a working-tree hunk with someone else's edit;
`git add -p` is the interactive equivalent. Commit with a **bare** `git commit`
(commits the index). Do **not** use `git commit -- <file>`: a pathspec switches
git to `--only` semantics, re-reading the *working tree* and pulling the other
party's WIP back in. (Verified: `git commit -- file` after `git apply --cached`
ignores the clean index and stages the whole working-tree file.)

## Files

Under `~/.agents/bin/` (canonical `C:\code\dotfiles\agents\bin\`):

| File | Role |
|------|------|
| `commit-lock.sh`      | the mutex: source for `lock_acquire/lock_release/lock_run`, or `commit-lock.sh run -- <cmd>` |
| `commit-lock.test.sh` | self-contained tests (throwaway temp dirs); exit 0 == all pass |

## Verifying on a new machine

```
bash ~/.agents/bin/commit-lock.test.sh   # prints "RESULT: N passed, 0 failed"
```

Covers mutual exclusion over 8×25 concurrent workers, stale-lock theft, the
epoch-less-orphan regression, refusal to steal a live lock, exit-code
propagation, and the git-dir lock location.
