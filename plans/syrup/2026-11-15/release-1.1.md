# Syrup 1.1: integrate, review, merge, release

## Goal

Ship the AppState split, the state-machine models and statecharts, and the F1 to F3 Fn fixes on top of local `main`, as Syrup 1.1 build 15: reviewed, merged into `main`, pushed, built, signed, notarized, and published as a release with its feed entry.

## Context

- The work was on `fn-shortcut-fixes`, stacked on `state-machines` and `appstate-extraction`, based on `3492746`. Local `main` moved to `86008fb` meanwhile (25 commits): glossary learning removed (`a3dec87`), the speech-model manager made an explicit state machine, Delete Partial Download, provider stream fixes, and the mutation tool.
- The last release is 1.0 build 14, tag `v1.0` on `rafaelkupper/syrup`, which is private. The feed is `appcast.xml` on `main`; `script/release.py` reads the live feed over public HTTPS, which returns 404 while the repository is private (see `docs/logs/2026-11-13-syrup-1.0-public.md`).
- The maintainer chose 1.1 on 2026-11-15. Fn behavior will be tested by hand later.

## Constraints

- No regression. The three-delegate review (Astra, Fable, Muse) must pass before the merge; fixes to its findings are red-first and re-checked.
- Leave `docs/logs/2026-11-13-syrup-1.0-public.md` and the main checkout's working tree alone.
- Everything public about the release is minimal: title and notes `Syrup 1.1`.
- Do not run the app or touch the real microphone, clipboard, or hotkeys.
- Writing: lead with the result, straight quotes, no em dashes, dates as YYYY-MM-DD.

## Approach

1. Rebase the stack onto `main` as `release-1.1`, dropping what `main`'s learning removal made moot: the `RecordingFiler` extraction, its characterization tests, and the learning opt-out model. Build, then `script/ci_test.sh`.
2. Review the code (`main..release-1.1`) with three delegates in their own worktrees, blocking only on regressions or false passes. In parallel, a writer brings `docs/state-machines/` up to date with `main`'s code; check its links, anchors, and charts.
3. Fix findings red-first, re-check, rerun CI and the full replay.
4. Fast-forward `main`, push.
5. Version 1.1 build 15, CI, `script/release.sh` (archive, export, notarize), review the artifacts, publish, verify from GitHub. Log in `docs/logs/2026-11-15-syrup-1.1.md`. Update README.md if it names the version or the removed feature.

## Done when

- Review passed with no open blocker; CI and full replay pass on the merged commit.
- `main` pushed; release `v1.1` with `Syrup-1.1.zip` and the feed entry verified; deployment log written.

## Progress

- 2026-11-15: rebased as `release-1.1` (13 commits on `86008fb`). Dropped `0c1de1b` (RecordingFiler) and `cf9e1a4` (learning opt-out model); removed `RecordingFilingCharacterizationTests` and the learning replay; conflicts in `AppState.swift`, `AppState+VoiceRun.swift`, ARCHITECTURE.md, IMPLEMENTATION.md, and the AppState plan resolved by keeping `main`'s text and re-applying the stack's edits without learning lines. The app builds.
