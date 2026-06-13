# Plan: move the test suites to `tests/` + remove stale install-path headers

Status: awaiting Ben's review. Not yet executed.

## Goal

Move the three test suites into `tests/`; the two implementations and
`install.sh` stay at root (they are the product — "copy these two scripts
anywhere"). While touching the suites' headers anyway, fix the stale usage
lines that claim the tests run from `~/.local/bin` (tests are not installed;
`install.sh` ships only the two implementation scripts — verified, and
`~/.local/bin` on this box contains only the two impl symlinks).

## Commits

**Commit 1 — pure rename.** `git mv` the three suites to `tests/`, no content
changes, so history/blame stays clean:

- `git-commit-lock.test.sh`             → `tests/git-commit-lock.test.sh`
- `git-commit-lock.interop.test.sh`     → `tests/git-commit-lock.interop.test.sh`
- `git-commit-lock.integration.test.sh` → `tests/git-commit-lock.integration.test.sh`

**Commit 2 — path + header fixes.**

1. Suite resolution (the only functional change): each suite resolves
   `DIR` from `BASH_SOURCE`, then `LIB="$DIR/git-commit-lock.sh"` (unit,
   integration) and `PS1WIN` from `$DIR/git-commit-lock.ps1` (interop,
   integration). Add `ROOT="$(cd "$DIR/.." && pwd)"` and point LIB/PS1WIN at
   `$ROOT/...` (resolved, no embedded `/../` to confuse cygpath -w).
2. Stale usage headers in all three suites:
   `bash ~/.local/bin/git-commit-lock.<suite>.sh` → `bash tests/git-commit-lock.<suite>.sh`.
3. CI (`.github/workflows/tests.yml`): `tests/` prefix on the three suite
   invocations and on the four test entries in the lint job's shellcheck list
   (lib + install.sh entries unchanged).
4. `docs/git-commit-lock.md`: Files table (3 rows), the three run commands in
   the Tests section, and the three prose leads naming the suites.
5. `git-commit-lock.ps1`: two comment references to suite filenames (lines
   ~6, ~316) — prose-only, update for precision.
6. Integration suite header's sibling mentions (lines 4–5) — same.

## Deliberately untouched

- `install.sh` — does not ship tests; no path references to them.
- `README.md` — zero test-file mentions (verified by grep).
- `.editorconfig` / `.shellcheckrc` — glob/ruleset based, no paths.
- `GCL_TEST_PRESERVE_DIR` plumbing — env-based absolute paths, unaffected.

## Known consequences / follow-ups

- **dotfiles**: `210-using-git.md` tells agents to run
  `git-commit-lock.test.sh` / `git-commit-lock.interop.test.sh` to verify a
  new machine — update to `tests/` paths in the dotfiles repo after this
  lands (separate repo, separate commit).
- **`shfmt-adoption` branch** will no longer rebase cleanly across the move.
  Already covered: the shfmt handover says regenerate the mechanical commit
  by re-running `shfmt -w`, never cherry-pick. If shfmt is revisited, re-run
  it on the moved tree.
- The suites' own headers each name their file in line 2 — updated as part
  of (2)/(6) where the path appears.

## Verification

- `bash -n` all five shell files; `shellcheck -S style` with the new paths
  (the gate list mirrors CI's).
- actionlint on the workflow (expect only the two pre-existing SC2016 infos
  in the untouched toolchain step).
- Run all three suites from the repo root; additionally run the unit suite
  once from inside `tests/` to prove resolution is location-independent.
  Read results from log files, not inline stdout.
- During implementation, grep each suite for other `$DIR` uses beyond
  LIB/PS1WIN resolution to confirm nothing assumes DIR == repo root.

## Open choice

Folder name: `tests/` (recommended; matches the plural the docs use) vs
`test/`. Proceeding with `tests/` unless Ben says otherwise.
