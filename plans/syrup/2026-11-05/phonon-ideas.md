# Three ideas from phonon

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

Build the three improvements the maintainer chose on 2026-11-05 from the phonon evaluation:

1. Caret fit: when Syrup pastes into the middle of a sentence, lowercase the first word and drop a final period that text follows.
2. Early transformation: when the speaker goes quiet while still holding the key, start the transformation, and use that result at release only when the final input is identical.
3. Mishearing suggestions: speak each glossary term with a system voice, transcribe it on the Mac, and offer what the recognizer heard as mishearing hints.

## Context

- Phonon (GPL-3.0) is the source of the ideas only. No phonon code, prompt, table, or fixture is copied.
- Evidence from phonon's SPEC: 40 of its owner's 44 hand corrections only changed first-letter case or the final period. Its streaming refine reused a background result at release on 25 of 40 dictations.
- Syrup today: smart spacing reads one UTF-16 unit before the caret (`DeliveryTarget.needsLeadingSpace`). The provider call dominates release-to-clipboard. Glossary mishearings are typed by hand or proposed by the opt-in Whisper cross-check.

## Constraints

- AGENTS.md hard rules hold: no logging of user content, clipboard written once with the exact result, no new TCC permission, Swift 6, Swift Testing, `project.yml` plus `xcodegen` only.
- Caret fit and early transformation are new toggles, default off. Caret fit needs automatic paste, like smart spacing.
- Early transformation sends a not-yet-final transcript, so it is limited to providers that keep data on the Mac: Apple On-Device and OpenAI-compatible endpoints on a loopback host. Cloud endpoints and Codex CLI are excluded until the maintainer decides otherwise.
- Early transformation applies to normal voice dictation with the Apple speech engine. Parakeet and streaming engines, revisions, Transcribe, and selected-text runs keep today's path.
- Mishearing results stay in memory until the user accepts them into the glossary. No audio is written. Nothing leaves the Mac.
- No commit or push without the maintainer's word.

## Done when

- Each feature works behind its setting, with focused unit tests through its seams.
- The isolated suite and the production Debug build pass on the integrated tree.
- A release-path log records quiet time before release and the early-transformation outcome as numbers only.
- A real run of the mishearing probe on this Mac is recorded with sample technical terms.
- ARCHITECTURE.md, PRODUCT.md, and docs/QA.md describe the new behavior, and what remains unverified is reported.

## Status 2026-11-05

Built and verified. All three features are in the main checkout behind default-off toggles.

- Isolated suite on the final tree: 682 tests, 677 passed, 0 failed, 5 opt-in skips. Unsigned production Debug build passed with no warnings in changed files.
- Early transformation changed trigger after measurement: Apple's live partials matched the final transcript only 1.2 to 1.4 s after speech in fast mode and never in accurate mode, so attempts now come from an offline pass over the audio so far, which matched in 87.5% of trials at 300 ms and all trials at 600 ms.
- Mishearing suggestions: an evaluation run with real macOS voices showed useful mishearings plus everyday-word noise, which led to novelty-voice exclusion, a carrier-spill filter, and an everyday-word warning.
- Unverified: real microphone and editors, live clicks in the real app, real voices through the app with Speech authorization, VoiceOver, and macOS 26.
- Open decisions for the maintainer: the defaults of both toggles, and whether early transformation may ever send unfinished transcripts to cloud providers.

## Revision after the maintainer's first test, 2026-11-05

- Match the sentence at the cursor now fits the clipboard itself, so a manual Command-V and Syrup's paste deliver the same fitted text. It no longer needs automatic paste, only Accessibility. History keeps the exact result.
- Start writing during a pause is disabled and shown off, with the cue "This feature only works with Apple On-Device models or a server on this Mac.", when no voice workflow can use it.
- Isolated suite: 687 tests, 682 passed, 0 failed, 5 opt-in skips. The signed Debug build was relaunched for testing.
- The clipboard change was completed and verified during integration.
