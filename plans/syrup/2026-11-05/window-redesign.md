# Syrup window redesign

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

Replace the Syrup window's nine sidebar pages with toolbar tabs and a Home that shows what Syrup will do next and what it just did. Deliverable for this round: a clickable mockup (`window-redesign-mockup.html`) plus the layout rationale. No Swift changes yet.

## Context

On 2026-11-05 the maintainer said the window is "so bad". The reported problems were: it looks generic and gray, things are hard to find, Home isn't useful, and the workflow editor is a slog. The chosen direction stays close to the native look ("polished native") and uses toolbar tabs. Restructuring was allowed.

Baseline: screenshots of the installed 0.8 build, taken 2026-11-05, plus the integrated stats, speech model list, and spoken-edit changes.

## Constraints

- Native SwiftUI controls only. No custom controls that imitate other platforms.
- Every existing setting stays reachable. No new setting keys. Workflow color comes from the workflow's action, not from a stored value.
- Privacy and clipboard rules in AGENTS.md are unchanged. Recent and stats show only what they show today.
- No commit, push, or release without the maintainer's request.

## Tab map

| Tab | Contents | From |
|---|---|---|
| Home | Status, active workflow as an editable sentence, items that need attention, stats, Recent | Home |
| Workflows | Workflow list and editor side by side, including each workflow's shortcut, apps, corrections, and spoken edits | Workflows, workflow page, Shortcuts (per-workflow), Recording (spoken edits) |
| Dictation | Shortcuts (Dictate, Revise, Paste last result, hold or toggle, Fn), microphone, while you speak, limits | Shortcuts, Recording |
| Delivery | Paste, typing, spacing, original editor, sound | After Dictation |
| Models | Speech models list, AI provider and its connection | Recording (models), AI Provider |
| Glossary | Terms table, suggestions, learning, built-in vocabulary | Glossary |
| Privacy | Permissions, what leaves this Mac, what's kept | Privacy |
| General | Startup, updates, welcome | General |

## Done when

- The mockup shows every tab and the key states: first run, needs attention, paused, a failed result, and the Transcribe and Selected text workflow variants.
- Each tab notes the SwiftUI building blocks and any platform risk.
- The findings name file-level evidence, and anything not measured is labeled as not measured.
- The maintainer approves a direction before any Swift changes begin.

## 2026-11-05: built

the maintainer approved the mockup and asked for the build. The implementation is complete. Evidence and open checks are in `docs/verification/2026-11-05-window-redesign.md`. Remaining: a person clicks through the tabs, the sentence menus, and the confirmation alerts, and opens the window from the real menu bar app.
