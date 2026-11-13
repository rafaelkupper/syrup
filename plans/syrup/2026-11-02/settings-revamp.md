# Syrup window revamp

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

Build the approved mockup (`settings-revamp-mockup.html`): a Syrup window with Home as the first page, and settings reorganized into Workflows, Shortcuts, Recording, After Dictation, AI Provider, Glossary, Privacy, and General.

## Context

Settings is one `Settings` scene with five panes. General mixes shortcuts, recording, delivery, and app options. Workflows puts a list beside a form, which leaves little width. The maintainer tested a build on 2026-11-01 and approved the mockup on 2026-11-02.

## Constraints

- Standard SwiftUI controls. No new TCC permission. No new setting keys.
- Saved settings and history stay compatible. Older builds must still decode new history.
- Delivery behavior and the translation pipeline do not change. Timing is read only.
- Never log user content. Recent shows it only in the window.
- No release, push, or commit without the maintainer's request.

## Done when

- The window does not open at launch, opens from the menu bar, and closing it leaves Syrup running.
- Every existing setting is still reachable.
- Home reflects real state: status, active workflow, problems, and recent results with timing.
- The isolated suite and production build pass, and rendered pages are inspected.
- Affected docs are updated.
