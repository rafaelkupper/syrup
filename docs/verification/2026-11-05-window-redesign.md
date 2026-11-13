# Syrup window redesign, 2026-11-05

Personal identifiers and machine paths in this record use illustrative placeholders.

Built from the approved mockup `plans/syrup/2026-11-05/window-redesign-mockup.html`. The plan is `plans/syrup/2026-11-05/window-redesign.md`.

## What changed

- The window is a SwiftUI `Settings` scene with toolbar tabs: Home, Workflows, Dictation, Delivery, Models, Glossary, Privacy, General. ⌘, and Open Syrup… open it through `openSettings`.
- Shortcuts and the microphone part of Recording merged into Dictation. After Dictation is now Delivery. Speech models moved to Models, beside the AI provider. Spoken edits moved into a Translate workflow's Output section. Per-workflow shortcuts live only in the workflow editor.
- Workflows shows the list beside the editor. Make Active, Duplicate, and Delete are in the ⋯ menu and the context menu. Delete asks first.
- Home and the editor open with the workflow sentence, whose words are menus. Clear History and Delete Stats ask first. The menu bar's Clear History asks too.
- No setting keys were added. Workflow colors come from the workflow's action.

## Checked

- Baseline before the change: 603 tests in 75 suites passed.
- After the change: 606 tests in 75 suites passed in the isolated suite. The new tests cover navigation keeping the selected workflow, provider problems opening Models, history row colors, and the Recent detail line. The Debug and Release builds succeeded, with no warnings in the changed files.
- A separate `org.syrup.SyrupUIVerify` host ran the real panes with seeded workflows, glossary, history, and 180 days of stats. It used temporary defaults, secret storage, history, and model folders, no hotkeys, and Sparkle automatic checks off. Every tab and all four workflow types were captured with `screencapture` in light and dark and inspected.
- Rendering found three defects, all fixed and recaptured: a visible "Name" label on the workflow name field, a duplicate "Search" label in Glossary, and sentence menus that ignored their color and font with `.borderless`, fixed with `.buttonStyle(.plain)`.
- Rendering also showed that toolbar tabs draw no badge. The Privacy icon now changes to `exclamationmark.shield` instead. That change built, but the display slept before it could be captured.

## Not checked

- No control was clicked. Computer Use access to the verify host was declined twice, so opening the sentence menus, switching tabs by click, the confirmation alerts, and the Fn disclosure need a person.
- The window was captured inactive, so the accent tint on the selected tab was not seen.
- Opening the window from the real menu bar app, including whether it comes to the front from an accessory app, was not tried. The installed app is still 0.8.
- The "new result" highlight fade, hover text on the activity grid, and the Privacy shield were not seen.
