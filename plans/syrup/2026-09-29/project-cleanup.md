# Project cleanup

## Goal

Remove obsolete build products, completed planning material, and confirmed unused scaffolding. Leave the project ready to develop and the current signed release available.

## Context

Cleanup started at main `2b87dd7`, manifest 0.6/build 6. Unrelated local changes were preserved. `dist` used about 55 MiB, local release archives/exports about 57 MiB, and Git loose objects about 45 MiB.

## Constraints

- Preserve source behavior, active tests, assets, credential configuration, unrelated local changes, package resolution, current release ZIP/checksum, and current archive with debug symbols.
- Remove obsolete plans only after their decisions and remaining QA are represented in current docs.
- Keep Git history, refs, reflogs, and all stored objects. Compress object storage without pruning.
- Do not touch installed apps, user recordings/history, global build caches, or remote branches.
- No new version, release, commit, or push is needed for cleanup.

## Done-when

- [x] Inventory and justify removals; consolidate current development and manual QA guidance.
- [x] Remove old/duplicate release products, redundant assets, stale plan files, obsolete helpers, and uncalled scaffold types.
- [x] Regenerate the project; production build and remaining isolated tests pass.
- [x] Current release checksum, signature, staple, and Gatekeeper verification pass.
- [x] Git object inventory, refs/reflogs, credentials, package pins, and unrelated local changes are preserved.
- [x] Record measured space reclaimed and remaining useful artifacts.

## Result

Cleanup is complete. Approximately 94 MiB was reclaimed, production compilation passed, and the full isolated suite passed with 358 tests in 37 suites on rerun. Current ZIP integrity/signature/staple/Gatekeeper checks and archive/dSYM matching passed. All stored Git objects, refs, reflogs, credential configuration, package pins, and unrelated local changes were preserved. One pre-existing cancellation-test ordering flake is recorded in `docs/verification/2026-09-29-project-cleanup.md`. Temporary builds/logs were discarded after verification. No cleanup commit or push was made.


## Delivery follow-up: 2026-10-25

The user authorized committing and pushing all pending changes to main. The previous no-push constraint applied to the original cleanup task. A subsequent read-only review found the documented 0.6 release archive and matching dSYMs missing; locating or restoring them remains unresolved and is recorded in the cleanup verification report.
