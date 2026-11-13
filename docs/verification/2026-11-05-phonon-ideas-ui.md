# Phonon ideas UI, 2026-11-05

Personal identifiers and machine paths in this record use illustrative placeholders.

Settings UI for the three features in `plans/syrup/2026-11-05/phonon-ideas.md`: caret fit, early transformation, and mishearing suggestions. Engine work is described in `2026-11-05-caret-fit.md`, `2026-11-05-early-transformation.md`, and `2026-11-05-mishearing-suggestions.md`. No setting keys, persisted data, or permissions were added.

## What was built

- **Delivery.** "Match the sentence at the cursor" (`matchesSentenceAtCaret`) sits under "Add a space after a word" and uses the same `pasteOption` row, so it is indented and disabled while automatic paste is off.
- **Models.** A "Speed" section at the end holds "Start writing during a pause" (`transformsOnPause`) and a note on whether it applies. Models is where the provider, the server address, and the speech models are chosen, which are what decide eligibility. `EarlyTransformationNote` builds the note from the global provider and base URL, using the run's own `PauseTransformation.isLoopback`. A second line appears only when workflows differ from the global answer, for example "Works for 1 of 2 voice workflows. The other one uses a downloaded speech model." Transcribe and selected-text workflows are not counted. Workflow overrides use the global server address, as at run time.
- **Glossary.** Each term row gets a check button beside Delete and a short status at the end of its Sounds like cell: Checking…, N suggestions, Nothing new, Heard correctly, Not checked, or Check failed. Help text and VoiceOver carry the reason. A "Check with a system voice" section under the table has Check All, a progress bar with "5 of 7" and Stop, a summary after a run, one row per term with suggestions (chips: click the name to add, x to dismiss), one row per failed term with Try Again, and each language problem once with its fix (Open Accessibility…, Open Workflow, Open Privacy). The footer says once that a system voice isn't the user's voice. While a dictation runs, the row says "Not while you dictate" and every check control is disabled.
- **Everyday words.** Their chips are gray with a warning triangle instead of the accent color, and adding one asks first. Measured on this Mac, NSAlert gives the "Cancel" button Escape and assigns Return to no button, so "Add Anyway" is never the default.

Files: `Sources/Settings/DeliverySettingsPane.swift`, `ModelsSettingsPane.swift`, `GlossarySettingsView.swift` (changed); `EarlyTransformationNote.swift`, `EarlyTransformationSection.swift`, `MishearingCheckCopy.swift`, `MishearingCheckViews.swift` (new); `Tests/SyrupTests/PhononIdeasUITests.swift` (new).

## How it was rendered

A separate host, `org.syrup.SyrupUIVerify`, ad-hoc signed, was built from a copy of `Sources` in a temporary directory with its own `SyrupApp.swift`. It placed the real panes in 720-point windows with seeded state:

- One temporary `UserDefaults` suite per scenario, removed afterward. Secret store, speech-model folder, and comparison-model folder under the temporary directory. A fake `AutoPasting` that reports trust.
- No hotkeys, menu bar item, recording archive, or `UpdateController`. Sparkle automatic checks were also off in the host's Info.plist.
- Mishearing checks used a fake `MishearingProbing` engine with fixed outcomes per term: suggestions including an everyday form, heard correctly, unavailable (no Portuguese voice), failed (timed out), suggestions with a partly unavailable locale (English model not installed), and one term that never finishes, which keeps the run at 5 of 7. Checks start 1.5 s after the window opens and take 200 ms per term, so every state change happens after the first render.

Each window was captured with `screencapture -l` in light and dark, then inspected. Windows were captured inactive. Captures are in `2026-11-05-phonon-ideas-ui/`:

| Capture | Shows |
|---|---|
| `delivery-on-*` | Automatic paste on, caret fit on |
| `delivery-off-*` | Automatic paste off: caret fit disabled like smart spacing |
| `models-apple-*` | Apple On-Device: works; one Parakeet workflow excluded |
| `models-cloud-*` | Cloud endpoint: not used; one workflow still uses it through an Apple On-Device override |
| `models-local-*` | Loopback server, toggle off: works, no workflow line |
| `glossary-running-*`, `glossary-running-tall-*` | Run in progress at 5 of 7 with Stop; every row status; suggestions, failure, and both language issues |
| `glossary-done-*` | Finished run: summary, Check All, Try Again enabled |
| `glossary-dictating-*` | Dictation running: "Not while you dictate", controls disabled |
| `everyday-alert-*` | The everyday-words confirmation |

## Defects found by rendering, fixed

1. **Clipped results.** The first design put the status and chips on a line under each Sounds like field. SwiftUI `Table` rows keep one height, so that line was cut off and the table showed empty space at the bottom. The suggestions moved to the section and the row shows a one-line status.
2. **Rows that never updated.** Row statuses stayed empty while the section showed results. A host scenario that finished checks before opening the window showed the badges correctly, so layout was not the cause. `MishearingSuggestionModel.state(for:)` returns `.idle` for a term not yet checked before it reads the observed `states`, so a view that rendered before any check never subscribed. The section updated only because it also reads `progress`. The views now read `suggestions.states` explicitly, and the running capture shows every state, including Checking… on the current term.
3. **Copy.** The caret-fit and early-start subtitles each wrapped to two lines and were shortened to one. The early-start section ran into the Apple Intelligence section, so it got a "Speed" header. The failure reason no longer ends in "Try again" beside a Try Again button.

## Tests

| Check | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Focused run, first version (`EarlyTransformationNoteTests`, `MishearingCheckCopyTests`) | 9 | 0 | 0 |
| Full isolated suite, final code: 681 tests in 87 suites | 676 | 0 | 5 |
| Unsigned production Debug build, final code | Succeeded | | |

The final suite includes 10 new tests in the two suites, covering every eligibility path and the copy for every check state. The five skipped tests are opt-in or need a model: `MishearingProbeRealTests` (2), `ReleasePathTimingTests` (2), and `availableModelSmokeTransformsShortPhrase`. No flaky, timed-out, or host-launch failures occurred.

```sh
build_root=$(mktemp -d /tmp/syrup-ui-build.XXXXXX)
test_root=$(mktemp -d /tmp/syrup-ui.XXXXXX)
packages=<DerivedData>/Syrup-<hash>/SourcePackages
cp -cR "$packages" "$build_root/SourcePackages"; cp -cR "$packages" "$test_root/SourcePackages"
xcodegen
xcodebuild -scheme Syrup -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath "$build_root" -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$build_root/SourcePackages"
SYRUP_TEST_ROOT="$test_root" script/test-isolated.sh -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$test_root/SourcePackages"
xcrun xcresulttool get test-results summary --path "$test_root"/build/Logs/Test/<result>.xcresult --compact
rm -rf "$build_root" "$test_root"
```

Host: macOS 27.0.1 (26A434), Xcode 27.2 (27B52). The temporary build, test, and host directories were deleted, and no verification host is running.

## Not verified

- No control was clicked: Check All, Stop, a row's check button, Add, Dismiss, Try Again, the three Open buttons, the alert's buttons, and both toggles. Nothing in this pass shows that Open Accessibility… lands on Spoken Content; it opens Accessibility, and the text names the rest of the path.
- The real probe engine with real voices and Speech authorization did not run here.
- VoiceOver output was not listened to. Labels, values, and help text are set, but only read in code.
- The selected-row highlight was not captured, so contrast of the accent-colored "N suggestions" on a selected row is unknown. Windows were inactive, so accent states of the active window were not seen.
- Typing in a Sounds like field while a check runs was not tried. Only the badge view redraws on a check, not the row, which is meant to keep focus.
- Chips stack through `ViewThatFits` when three long forms do not fit side by side. That case was not rendered; the longest pair rendered fit side by side.
- The note reads `settings.baseURL`. When no API key is saved and the process environment configures an endpoint, a run can resolve that environment endpoint instead, so the note can disagree with the run.
- The panes were not opened from the real menu bar app, and macOS 26 was not available.

## Follow-ups for other owners

- `MishearingSuggestionModel.state(for:)` could read `states[termID]` before its guard, so any observer subscribes. The views work around it today.
- PRODUCT.md, ARCHITECTURE.md, and docs/QA.md text is proposed in the task report, not applied here.

## Second pass, 2026-11-05: clearer early start and caret fit

the maintainer found both rows unclear. Early start now disables itself with a cue when no workflow can use it, and caret fit no longer depends on automatic paste.

### What changed

- **Models, Speed.** `EarlyTransformationNote` now answers one question: can any voice workflow start early? It counts voice workflows that aren't Transcribe, with Apple speech and an effective provider that keeps data on this Mac (Apple On-Device, or an OpenAI-compatible server on a loopback host, using the server address in Models).
  - None: the toggle is disabled and shown off. The stored `transformsOnPause` is not written. An `info.circle` cue says "This feature only works with Apple On-Device models or a server on this Mac." A second line appears only when something other than the provider is in the way: "It also needs the Apple speech model. Notes uses Parakeet Ultra." (or a count when several), or "It also needs a voice workflow other than Transcribe." when there is none.
  - Some or all: the toggle works, and a check mark note says which workflows it reaches. "Works for all your voice workflows." Or by name, up to three: "Works for Private." Then "Not for the other 2, which use a downloaded speech model or a provider that isn't on this Mac." Past three it gives a count.
  - The footer is now "Revise, Transcribe, and selected text wait for the final transcript."
  - The disabled toggle carries the cue as its VoiceOver hint and tooltip.
- **Delivery.** "Match the sentence at the cursor" moved out of the paste sub-options to the top of "The result", unindented, so it isn't disabled when paste is off. Its detail line is now "Starts lowercase mid-sentence and drops the final period before more text, in what Syrup copies and pastes." Without Accessibility (`PermissionStatusModel.accessibility != .granted`), it is disabled and shown off without writing `matchesSentenceAtCaret`. An `info.circle` cue says "Needs Accessibility to read the text around the cursor." with an Open Privacy button. The same text is its VoiceOver hint and tooltip. `DeliverySettingsPane` now takes the `SettingsNavigation` for that button.
- **Smart spacing.** The detail line was "The clipboard keeps the exact text." With caret fit on, the clipboard holds fitted text, so the line now says "Only when the cursor follows a word. The space isn't copied."

Files: `Sources/Settings/EarlyTransformationNote.swift`, `EarlyTransformationSection.swift`, `DeliverySettingsPane.swift`, `SettingsView.swift`, `Tests/SyrupTests/PhononIdeasUITests.swift`.

### How it was rendered

A new host, built the same way as in the first pass (`org.syrup.SyrupUIVerify`, ad-hoc signed, temporary directory, its own `SyrupApp.swift`), put the real `ModelsSettingsPane` and `DeliverySettingsPane` in 720 by 640 point windows. Each scenario had its own `UserDefaults` suite, and the secret store and speech-model folder were under the temporary directory. A fake `AutoPasting` set Accessibility trust through `PermissionStatusModel.refresh`. Models windows open scrolled to the bottom. Each scenario stored `transformsOnPause` or `matchesSentenceAtCaret` as on. Three seconds after rendering, the host read both settings back: every scenario still held its stored value, including the ones whose toggle showed off. Windows were captured inactive with `screencapture -l`, in light and dark, and inspected.

| Capture (`2026-11-05-phonon-ideas-ui/`) | Shows |
|---|---|
| `r2-models-cloud-off-*` | Cloud endpoint, Apple speech workflows: disabled and off, cue only |
| `r2-models-parakeet-off-*` | Apple On-Device, only a Parakeet Ultra workflow: disabled, cue plus the speech line |
| `r2-models-apple-on-*` | Apple On-Device: enabled, "Works for all your voice workflows." |
| `r2-models-mixed-*` | Cloud default; one Apple On-Device override, one Parakeet workflow: enabled, "Works for Private." plus "Not for the other 2…" |
| `r2-delivery-paste-off-*` | Paste off, Accessibility granted: caret fit enabled and on, above the paste group |
| `r2-delivery-no-ax-*` | Paste off, no Accessibility: caret fit disabled and off, cue with Open Privacy |
| `r2-delivery-no-ax-paste-on-*` | Paste on, no Accessibility: the caret-fit cue and the paste row's own Allow… notice together |

### Defect found by rendering, fixed

The first render put caret fit last in "The result", unindented, right after the indented paste sub-options. It read like a fourth paste option. It moved to the top of the section, so the paste group stays together and ends the section.

### Tests

| Check | Passed | Failed | Skipped |
|---|---:|---:|---:|
| First full isolated run, before the fixture fix: 687 tests in 88 suites | 681 | 1 | 5 |
| Full isolated suite, final code: 687 tests in 88 suites | 682 | 0 | 5 |
| Unsigned production Debug build, final code | Succeeded | | |

The one failure was a test fixture, not the code: it gave a pt-BR workflow Canary 180M Flash, and `Workflow.init` resets an engine that doesn't support the locale to Apple. The fixture now uses Parakeet Ultra. `EarlyTransformationNoteTests` (5 tests) replaces the first pass's four and covers availability by provider, Transcribe and selection exclusion, the speech-model line, naming and counting, and the global endpoint for overrides. `CaretFitRowTests` (1 test) covers enablement for every permission status. The five skipped tests are the same opt-in ones as in the first pass. Nothing was flaky or timed out. Commands are the same as the first pass, with `/tmp/syrup-ui2-build.*` and `/tmp/syrup-ui2.*` directories. The host, its preference files, and every temporary directory were removed, and no verification host is running.

### Not verified

- No control was clicked: neither toggle, Open Privacy, nor Allow…. Open Privacy sets `navigation.selectedTab = .privacy`, which is read only in code.
- VoiceOver output was not listened to. The hint is set on each disabled toggle.
- Captures are of inactive windows. A disabled switch that is off looks close to an enabled one that is off, especially in dark mode. The cue row is what tells them apart. Row titles are not dimmed when disabled, which matches the existing paste sub-options.
- With paste on and no Accessibility, two notices show for the same permission, each with its own action (Open Privacy and Allow…). That is accepted for now.
- "The space isn't copied" assumes smart spacing still leaves the clipboard alone while caret fit changes it. The engine owner should confirm this.
- The note still reads `settings.baseURL`. When no API key is saved and an environment endpoint is configured, a run can resolve to a different endpoint than the note assumes.
- The real app and macOS 26 were not used.
