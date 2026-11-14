# CLI providers: Codex model picker and Claude Code

## Goal

1. Codex gets a model picker filled from the signed-in account's own catalog, so the provider works out of the box. Today the default `gpt-5.4-mini` is rejected for ChatGPT accounts.
2. A new writing provider, Claude Code, runs `claude -p` with no tools. It shows up in Settings only when the CLI is installed (or is already selected).

## Context

Branch `cli-providers`, based on `review-round-3` (`155647c`), which already restricts and fences Codex. Facts measured on 2026-11-13:

- `codex debug models` prints the account's catalog as JSON in about 0.2 s. Each entry has `slug`, `display_name`, `visibility` (`list` or `hide`), and `priority`.
- `claude` 2.1.323 has no model-list command. `--model` accepts aliases (`haiku`, `sonnet`, `opus`, `fable`) or full names.
- A locked-down `claude -p` translation took 1.9 to 2.5 s with `--tools "" --strict-mcp-config --safe-mode --disable-slash-commands --no-session-persistence --permission-mode dontAsk --effort low --system-prompt ...`.
- Claude finds its login with `HOME` + `USER` + the right `CLAUDE_CONFIG_DIR`. A Finder-launched app does not inherit `CLAUDE_CONFIG_DIR`, so Settings needs an optional account folder. `claude auth status` prints JSON with `loggedIn` in about 0.1 s.

## Constraints

- AGENTS.md hard rules. Claude Code is cloud-backed, so it receives only the fenced input and the composed instruction, the same as Codex. The prompt goes on stdin, never in argv.
- Scalar settings stay raw strings: `claudePath`, `claudeModel`, `claudeConfigDirectory`.
- Swift 6, Swift Testing, `xcodegen` after adding files, and the boundary check.
- No commit to `main`, push, or release without a go. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.

## Done when

- Codex: a Picker lists the catalog's `list` models plus "Codex default" (omits `--model`, now the default) and "Custom". If the catalog can't be read, a text field is the fallback.
- Claude Code works as a provider everywhere a provider is chosen (default, per-workflow, retry with another provider, glossary judge). It is listed only when installed or already in use. Pause transformation stays off.
- Tests pin the Claude invocation, environment, error mapping, catalog parsing, empty-model Codex arguments, and provider visibility.
- `script/ci_test.sh` passes. A real hostile-input run through `claude -p` makes no tool calls.
- ARCHITECTURE.md and docs/QA.md are updated.

## Progress

- 2026-11-13: CLI facts measured, plan written.
- 2026-11-13: implemented.
  - Codex: the default model is now empty (the account's default). Settings has a catalog picker with Custom and a warning for an unlisted name.
  - Claude Code provider: `ClaudeCLITransformer`, resolver, status checker, Settings section, onboarding row, and offered only when installed or in use.
  - The runner's working directory is now part of the `CommandRunning` protocol.
  - Found while testing: a trailing slash on `CLAUDE_CONFIG_DIR` makes Claude report signed out, so paths are passed without it. Claude also creates a missing config folder, so a missing folder fails before launch.
  - Real runs:
    - Hostile input through locked-down `claude -p`: 0 tool calls, no tools or MCP servers at init, translated in 1.8 s.
    - `codex exec` without `--model` used `gpt-6.1-sol` and translated in 4.8 s.
