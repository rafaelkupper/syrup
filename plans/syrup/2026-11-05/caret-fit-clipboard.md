# Caret fit on the clipboard

## Goal

Write the fitted final result to the clipboard whether automatic paste is on or off. Preserve exact history output and reuse the streaming typing context.

## Context

The baseline includes the integrated features and Settings changes. Existing caret fitting happens during paste and leaves the clipboard unchanged.

## Constraints

Own only App, Context, Paste and their tests. Do not commit, branch, launch or quit the app, download dependencies, or edit product/architecture/QA documentation. Use a private isolated test copy and private unsigned build directory; delete them after verification. Exclude onboarding holds and untrusted or unreadable targets. Never retain or log caret text.

## Done-when

- Atomic, Transcribe, revision, retry, early-hit and streaming delivery fit before clipboard writes, while history stays exact.
- Automatic paste uses its ordinary Command-V or typing strategy and shares the fitting context with smart spacing.
- Paste Last fits at its current target; explicit copy actions keep their existing behavior.
- Tests cover enabled/disabled fitting, automatic paste off, trust, onboarding, streaming, target changes and failed clipboard recovery.
- Whole isolated suite and unsigned Debug build finish; append verification evidence and report proposed documentation text.
