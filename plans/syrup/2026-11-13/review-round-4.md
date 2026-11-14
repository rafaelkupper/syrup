# Review round 4 fixes

## Goal

Fix the findings from the 2026-11-13 round-3 reviews of `main` at `0c61db6` (GPT-6 Astra 7, Fable 5.2 8, Muse Wonder Full 8). The `AppState` restructuring and hosted CI are left for a later round.

## Context

Branch `review-round-4` from `0c61db6`. Each fix gets a test where a seam exists.

## Constraints

- AGENTS.md hard rules, Swift 6, Swift Testing, `xcodegen` after file changes.
- No commit to `main`, push, or release without a go. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.

## Work items

Problems from recent work:
1. Unknown provider values decode as nil in workflows and history, instead of failing the whole list.
2. CLI child `PATH` includes the executable's folder and the Homebrew bins, so script launchers (npm installs) start. Exit 127 gets its own message.
3. The process runner's timeout bounds pipe draining; collected output is capped.
4. Atomic paste rechecks the frontmost app after the asynchronous focus check.
5. Early transformation waits for the resolved run configuration.

Other findings:
6. Codex result read from stdout, not a temporary file, if the CLI supports it.
7. Delete Stats clears only after the disk delete succeeds, and shows failures.
8. Recordings left by a failed cleanup show in Privacy and Glossary.
9. Dependencies pinned to exact versions.
10. Selection context fence uses a per-run boundary.
11. Streamed text events carry no physical modifier flags.
12. Speech model Retry loads an existing model instead of downloading again.
13. A stream that ends at EOF after `finish_reason: stop` succeeds.
14. The flaky revision archive test waits for pending work.
15. README, PRODUCT, and the ARCHITECTURE sandbox note mention Claude Code.

## Done when

Every item is fixed or recorded with a reason, `script/ci_test.sh` passes, and there are no new warnings.

## Progress

- 2026-11-13: plan written.
- 2026-11-13: items 1-15 implemented.
  - Item 6 holds: `codex exec` prints only the final message on stdout (checked with a real run), so `--output-last-message` and the result file are gone.
  - Codex stderr is matched only in its last 2 KB, because the CLI echoes the prompt there.
  - Item 9 pins KeyboardShortcuts 2.4.0 and WhisperKit 1.1.0, the versions already resolved. The transitive swift-argument-parser still follows WhisperKit's own requirement.
  - Item 10 uses a digest of the context as the fence boundary, not a random one, so the same input composes the same instruction (item 5 compares instructions).
  - Found while testing item 8: the archive's synchronous count lost overload resolution to the protocol's `async` default and returned 0. It is now `async`, with a test through the protocol.
  - Before the stdout cap, the runner collected everything a CLI printed; a runaway `yes` is now stopped at 4 MB.
