# Plan: move the test suites to `tests/` + remove stale install-path headers

Status: awaiting Ben's review. Not yet executed.
Reviewed: 2 fresh-reviewer round(s); fixes folded in (see changelog).

## Goal

Move the three test suites into `tests/`; the two implementations and
`install.sh` stay at root (they are the product — "copy these two scripts
anywhere"). While touching the suites' headers anyway, fix the stale usage
lines that claim the tests run from `~/.local/bin` (tests are not installed;
`install.sh` ships only the two implementation scripts — verified, and
`~/.local/bin` on this box contains only the two impl symlinks).

## One commit

`git mv` the three suites to `tests/` and make the path/header fixes below in
the same commit. A single commit keeps every tree state green (a pure-rename
first commit would leave a tree whose suites can't find the lib — a bisect
hazard for no real gain); git's rename detection handles a rename plus small
content edits without losing history.

- `git-commit-lock.test.sh`             → `tests/git-commit-lock.test.sh`
- `git-commit-lock.interop.test.sh`     → `tests/git-commit-lock.interop.test.sh`
- `git-commit-lock.integration.test.sh` → `tests/git-commit-lock.integration.test.sh`

### Path + header fixes

1. Suite resolution (the only functional change). Each suite resolves `DIR`
   from `BASH_SOURCE`; add `ROOT="$(cd "$DIR/.." && pwd)"` (resolved — no
   embedded `/../` to confuse `cygpath -w`) and repoint every repo-file
   reference at `$ROOT`. Complete `$DIR` inventory (verified by grep):
   - unit `test.sh:29`        — `LIB="$DIR/git-commit-lock.sh"`
   - interop `:44`            — `SH="$DIR/git-commit-lock.sh"`
   - interop `:45`            — `PS1WIN` from `$DIR/git-commit-lock.ps1`
   - interop `:1139`          — static `grep … "$DIR/git-commit-lock.ps1"`
     (the never-`File.Replace` check)
   - integration `:40`        — `LIB="$DIR/git-commit-lock.sh"`
   - integration `:41`        — `PS1WIN` from `$DIR/git-commit-lock.ps1`
2. Stale usage headers in all three suites:
   `bash ~/.local/bin/git-commit-lock.<suite>.sh` → `bash tests/git-commit-lock.<suite>.sh`.
3. CI (`.github/workflows/tests.yml`): `tests/` prefix on the three suite
   invocations (lines ~80/89/98) and on the three test entries in the lint
   job's shellcheck list (lib + install.sh entries unchanged).
4. `docs/git-commit-lock.md`: Files table (3 rows), the three run commands in
   the Tests section, and the three prose leads naming the suites.
5. `git-commit-lock.ps1`: two comment references to suite filenames (lines
   ~6, ~316) — prose-only, update for precision.
6. Integration suite header's sibling mentions (lines 4–5) — same.

## Deliberately untouched

- `install.sh` — does not ship tests; no path references to them.
- `README.md` — zero test-file mentions (verified by grep).
- `.editorconfig` / `.shellcheckrc` — glob/ruleset based, no paths. (Reviewer
  confirmed: shellcheck discovers `.shellcheckrc` by searching upward from
  each script's directory, so `tests/` scripts still find the root rc.)
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
- Re-grep `\$DIR` across the moved suites to confirm the inventory above
  stayed complete.

## Open choice

Folder name: `tests/` (recommended; matches the plural the docs use) vs
`test/`. Proceeding with `tests/` unless Ben says otherwise.

## Changelog

- r2 (post-review): two-commit structure collapsed to one (pure-rename
  intermediate commit left a broken tree — bisect hazard, no benefit);
  corrected "four test entries" → three in the lint list; completed the
  `$DIR` inventory — the plan had missed interop's `SH=` (line 44) and the
  line-1139 static-check reference, both now explicit.
