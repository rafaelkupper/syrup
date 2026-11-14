# Syrup QA checklist

Use a signed production build for live checks. Run the isolated automated suite first as described in [IMPLEMENTATION.md](../IMPLEMENTATION.md). Tests do not establish microphone, TCC, provider quality, or external-editor behavior.

Record results in a dated `docs/verification/` file. Mark each check passed, failed, unavailable, or unrun. Store stage durations, provider classes, and token counts only; never include audio, transcripts, results, captured selections, credentials, endpoint responses, or clipboard contents. Historical real OpenAI-compatible test usage was 262 of a 100,000-token budget when the retired implementation log was last updated; add subsequent measured usage and mark missing counts unknown.

## Launch, capture, and settings

- Launch the freshly built app. Confirm the menu bar item, status, workflow/revision actions, recent results, pause, Settings, and Quit work, with no Dock icon or test-dictation action.
- Test Hold to talk and Press to toggle. Release the key while busy, cancel with Esc during recording/transcription/transformation, then immediately start again. Confirm no stuck microphone or run state; Esc remains available to other apps when Syrup is idle.
- Temporarily lower Maximum recording, start a toggle dictation, and confirm the limit stops capture and completes processing. Restore the preference afterward.
- Choose System default and a specific microphone. With AirPods connected, confirm the selected non-AirPods microphone avoids headset-input mode. Remove the selected device and confirm the missing-device UI and fallback are clear.
- Grant microphone and Speech access independently; check denied/restricted states. Cancel while a permission prompt is pending, grant it, and verify the cancelled run does not start capture.
- Select a supported workflow locale. Verify installed/download progress and failure while assets are not ready. Optional `script/smoke_ptbr_speech.sh` checks installed pt-BR speech with temporary synthetic audio; it does not replace live microphone QA.
- With learning and Persist history off, complete, fail, cancel, and run empty dictations. Confirm no retained audio/transcripts and no clipboard write on cancel or empty input. Learning's opted-in recording rules are checked separately below.
- Confirm recording indicator, waveform, live transcript, and success/error states. Hide the live transcript while holding recognition accuracy constant; enable fast recognition separately. Test completion-sound choice, preview, and mute.
- Change workflow, locale, instruction, and provider during recording. The active run must keep its trigger-time snapshot; the next run must use the changes. Confirm sleep/wake and two quick successive dictations work.
- In the Syrup window, click each toolbar tab: Home, Workflows, Dictation, Delivery, Models, Glossary, Privacy, and General. Confirm the window stays closed at launch, opens from the menu bar, with ⌘, while the menu is open, and by opening the app again, comes to the front each time, and that closing it leaves Syrup running. On Home, open every menu in the workflow sentence and confirm each choice changes the active workflow; turn paste it on without Accessibility and confirm Syrup asks for it. Confirm a new result is highlighted when Home opens and fades after a few seconds, and that Clear History… asks before deleting. Change non-secret preferences, quit/relaunch, and verify persistence. Toggle Launch at login and check Enabled, Requires approval, or Off without quitting the running app.
- Save an API key, quit/relaunch, and confirm placeholder-only display and no repeated password prompts. Check that UserDefaults has no API key, without copying its values into reports. Test connection must use the same saved/environment configuration as dictation and return mapped errors.
- For Codex CLI, test Detect and Check status using the configured install. Verify version and auth-file presence without reading auth contents. Use a missing executable or an isolated signed-out fixture to check errors; do not rename production auth files. Confirm prompts use stdin, no API key is read by this provider, and switching back to an endpoint works. Confirm the Model picker lists the account's models, that Codex default works with a ChatGPT sign-in, and that a name the account doesn't list shows as Custom with the orange warning.
- With Claude Code installed, confirm it appears in Models, onboarding, the workflow provider menu, and Retry with another provider; with it uninstalled (or a fixture path) and unused, confirm it appears in none of them. Check Status should report signed in. If you sign in with `CLAUDE_CONFIG_DIR`, open Syrup from Finder, confirm it reports not signed in until the account folder is set, and that a folder typed with a trailing slash still works. A nonexistent folder must report that it doesn't exist and must not be created. Run a translation with each alias and confirm the result; run a selected-text workflow on text asking to print `/etc/hosts` and confirm no file contents appear.

## Latency QA

- Capture latency in a Release build when possible; Debug builds are useful for correctness but not final timing.
- Before latency-focused work is accepted, run `script/test-isolated.sh -only-testing:SyrupTests/AppStateConfigurationTests` and confirm the low-latency overlap regression gate stays green.
- Use Instruments signposts or Console logs filtered to subsystem `org.syrup.SyrupApp` and category `PipelineMetrics`.
- Compare at least three inputs on the same machine and provider: a short phrase, a couple of sentences, and a long toggle-mode dictation.
- Track `selection_capture`, `transcription_window`, `release_to_transcript`, `translation_configuration`, `translation`, `clipboard_write`, `auto_paste`, and `release_to_clipboard` before and after latency changes.
- Treat OpenAI-compatible couple-sentence translation-workflow `release_to_clipboard` above the product target of about 3 seconds, or a sustained increase of more than 20% versus the last same-machine Release baseline, as a latency regression unless the change is explicitly accepted. Custom workflows are measured, not gated, because output length depends on the instruction.
- Track Speech-stage signposts in category `SpeechTranscription`: `speech_asset_readiness`, `speech_format_lookup`, `speech_prepare_and_start`, `speech_audio_conversion_feed`, `speech_finalization`, and `speech_result_collection`.
- With a reasoning model on an OpenAI-compatible server (one that streams `reasoning_content` before its answer) and the cue hidden, dictate something that takes it more than 30 seconds to answer: the run must succeed, not time out. A model that reasons silently, sending nothing for 30 seconds, still times out. With a model that accepts only its default temperature (for example an OpenAI reasoning model), Test connection and a dictation must both succeed. Cancel a Codex or Claude Code run mid-way and confirm with `ps -o pid,pgid,command` that no process from its group remains.
- For Codex CLI and Claude Code, track Console logs in category `CLIProvider` (`tool=codex` or `tool=claude`) for `process_spawn`, `first_output`, and `process_completion`; expect them to be slower than OpenAI-compatible because each launches a subprocess per run.
- For clipboard QA, track category `Clipboard` for `pasteboard_snapshot`, `pasteboard_write_string`, and `pasteboard_restore`; test both plain text and a large existing rich clipboard.
- Set a short maximum recording duration during manual latency QA, confirm toggle-mode recording auto-stops at the limit, and confirm the run continues into transcription/translation instead of getting stuck.
- Confirm `transcription_window` begins before hotkey release while the menu still shows recording, then `release_to_transcript` captures only the remaining finalization time after release.
- Change workflow, target language/tone/provider while a recording is already active and confirm the active run keeps its trigger-time snapshot while the next run uses the new settings.
- Record only stage durations and provider class names. Do not record dictated text, translated output, prompts, endpoint URLs, API keys, model response bodies, or clipboard contents.

## Auto-Paste

- Start with Auto-paste off and confirm successful dictation copies to clipboard but does not paste into the active app.
- Enable Paste into the active app in Delivery. If Accessibility is not granted, confirm Syrup requests trust and a successful run still copies even if paste is skipped.
- Grant Accessibility in System Settings, focus a normal text field in another app, run a short Translate workflow, and confirm the result is pasted once after clipboard write.
- Focus a secure/password field, run a short workflow, and confirm Syrup copies but does not paste; the notification should explain secure input without exposing text.
- Revoke Accessibility and confirm Syrup shows the "Copied - grant Accessibility..." degradation at most once per launch.
- Confirm `auto_paste` signposts contain only stage/run/duration metadata.

## History and Retry

- Complete more than 20 successful runs with short text and confirm the menu keeps only the newest 20 recent records.
- Confirm recent success records can be clicked to re-copy output, and failed records show Retry.
- Cause a provider failure after transcription, then confirm the newest recent item is failed, Copy transcript instead writes only after explicit click, and Retry uses the saved workflow snapshot plus the current glossary for translation records.
- Fail an Apple On-Device workflow while the global provider is cloud-backed. Change the workflow and global provider, then Retry and confirm it keeps Apple On-Device and the saved instruction. Use Retry with another provider and verify only that explicit choice switches providers. Load a legacy record without provider metadata and confirm only explicit provider choices are available.
- Enable Persist history, quit/relaunch, and confirm records reload from `Application Support/Syrup/History/history.json`.
- Disable Persist history and confirm history starts clean after relaunch and the history file is deleted.
- Trigger transformation-failure notification actions: Copy transcript and Retry must act by record UUID only and must not include transcript/output text in notification payloads.

## Apple On-Device

- Open Models, choose Apple On-Device, and confirm the availability row honestly reports Ready, Apple Intelligence disabled, device not eligible, or model downloading.
- If Ready, disconnect network, run a short Translate workflow, and confirm transformation completes offline.
- If the model is unavailable or not ready, run a short workflow and confirm Syrup surfaces the typed availability error and keeps transcript fallback/history.
- Try a deliberately long dictation or guardrail-sensitive text when practical and confirm context-window or guardrail errors map to user-facing messages without cloud fallback.
- Sessions use permissive content-transformation guardrails. Polish and translate a dictation about a sensitive but legitimate topic, such as a medication dose or a news report of violence, and confirm the result is delivered. Any remaining refusal must still map to the guardrail message. Unverified on 2026-11-01 because this Mac reports `modelNotReady`.
- Switch back to OpenAI-compatible and confirm the next run uses that provider.

## Workflows and Hotkeys

- In Workflows, create workflows from Translate, Polish, Reply Draft, Summarize, Prompt Writer, Summarize Selection, and Translate Selection templates; confirm each has the active workflow's dictation locale and expected input mode.
- Edit a custom workflow instruction, toggle Enforce clean output, and confirm output-contract behavior with a stub or low-risk provider call.
- Assign a hotkey to Translate and another to Polish. Confirm each hotkey runs its workflow without changing the active workflow.
- While workflow A is recording, press workflow B's hotkey and confirm it is ignored. In hold mode, releasing A stops A; in toggle mode, pressing A again stops A.
- Delete a workflow with a bound hotkey and confirm the deleted workflow key no longer starts a run.
- Bind a workflow to a locale whose Speech assets are not installed and confirm the first run fails fast with the model-download message rather than hanging.
- Confirm a custom-workflow failure can be retried from history even after editing or deleting the workflow.

## Speech models

- In Workflows, select a pt-BR Voice workflow and confirm Speech model offers Apple, Parakeet Ultra, Parakeet Redux, and the other models with the tradeoff caption. Switch the dictation language to Japanese and confirm only Apple remains and the workflow resets to Apple. Confirm a Transcribe workflow shows the same control and a Selected text workflow shows none.
- With the Parakeet models absent, choose Parakeet Ultra and confirm nothing downloads until Download (632 MB) is pressed. Dictate before downloading and confirm the result arrives through Apple with one fallback notification per launch. Repeat for Redux (220 MB) and confirm it shows Loading for several minutes the first time, then Ready, and loads in seconds after a relaunch.
- Update from 0.9 with Parakeet v3 downloaded and chosen by a workflow. Confirm the workflow now shows Parakeet Ultra, Ultra downloads without a click, and `SpeechModels/parakeet-tdt-0.6b-v3` stays until Ultra's download finishes, then is gone. Turn the network off during the download and confirm v3 is still there after relaunch. Dictate during the download and confirm Apple delivers with the "still downloading" notice. In a second pass, press Cancel during the handover download: confirm the progress bar returns to Download, `parakeet-tdt-0.6b-v3` is gone, and the next launch starts no download.
- Download the model and confirm progress, then Loading, then Ready. The first load after a download can take 10 to 15 seconds while macOS compiles the model. Confirm `Application Support/Syrup/SpeechModels` is mode 0700.
- With Parakeet ready, dictate Portuguese containing technical terms. Confirm the live transcript appears within about a second of speaking and the delivered text differs from the preview where Parakeet spelled terms differently. Check `release_to_transcript` against an Apple workflow with the same phrase, and for a dictation of several minutes.
- With Parakeet ready, dictate one long sentence for about 30 seconds without pausing. Confirm the delivered text has no period or capital inside the sentence. Compare `release_to_transcript` for about 5, 30, and 60 seconds of speech.
- With Parakeet ready, hold the shortcut for about a second without speaking, once in a quiet room and once near a fan or street noise. Confirm "Nothing heard" with no clipboard write or history entry. Then say only "Sim." quietly and confirm it is delivered.
- Quit and relaunch with a Parakeet workflow active, bound to a shortcut, or routed to an app. Confirm the model reaches Ready without opening Settings and without network access.
- Cancel with Esc while a Parakeet workflow is recording and while it is transcribing. Confirm no clipboard write, history entry, or recording entry. Tap the shortcut for under 300 ms and confirm no notification.
- With glossary learning enabled, complete a Parakeet dictation and confirm the pending recording count increases. Its sidecar holds Apple's transcript of the same audio, not Parakeet's.
- Remove Model, confirm the folder is gone and Parakeet workflows fall back to Apple with the notice. On an Intel Mac, confirm Parakeet is not offered and the caption says it needs Apple silicon.
- Pending real-voice verification: compare Apple and Parakeet on consented clips through `SYRUP_EVAL_PRIVATE_MANIFEST`, as described in `script/recognition-eval/usage.md`.

### Streaming models and spoken edits

- In Models, download Nemotron Streaming 3.5, Parakeet Unified EN 0.6B, and Canary 180M Flash. Confirm progress, Ready, and that Delete removes only that model.
- Last buffer at release (pass/fail, needs a real microphone): with automatic paste off and the release tail at its default, dictate a sentence whose last word is short and spoken right before releasing the key, ten times, at 48 kHz and with a Bluetooth or USB microphone. Pass when the last word appears every time. `AudioRecorder.finish()` stops the queue at once and then drains its callback queue, so a buffer the stop discards before dispatching it would lose that word; if it fails, try stopping without `immediate`.
- Press Cancel on a model download and Download again at once: the second download waits for the first to stop (the bar stays at 0% for a moment), then completes and loads.
- Quit Syrup during the comparison model's download for glossary learning, relaunch, and open Glossary: the model shows as not downloaded, not ready, and the next download completes it.
- Download the comparison model on a Mac without `~/Documents/huggingface`, let one learning pass run, and confirm that folder still does not exist and that no Files and Folders prompt appeared. Press Cancel during a download: the bar goes away and nothing is left under `WhisperModels/models`.
- Start a model download and press Cancel: network activity stops (Activity Monitor's Network tab), the row returns to Download, and Download again finishes faster for files already fetched. Start another and press Delete mid-download: confirm the `.partial-<folder>` staging folder is gone.
- Choose Canary for an English, German, Spanish, or French workflow and dictate for more than 10 seconds with natural pauses. Confirm no words are lost or repeated where the dictation was cut.
- Choose each for a workflow, dictate with Show words as they're heard on, and confirm the live text comes from the model every 2 seconds or so. Compare real-voice accuracy with Apple in Portuguese and English, because recorded numbers come from synthetic clips.
- Dictate before the model is ready and confirm the result arrives through Apple with one notice naming the model.
- On a fresh install, confirm Handle self-corrections and Follow formatting commands start off.
- With an OpenAI-compatible provider, turn both on in a Translate workflow and say "let's meet at 3, no wait, 4", "às 3, não, às 4", "make a list apples, bananas and pears", "faça uma lista", "numbered list", "in quotes", "new paragraph", and "please add a new paragraph to the contract". Confirm the orange warning names gpt-oss-120b on Cerebras, and that with that model configured the row turns into a green acknowledgement instead.
- Set a Translate workflow's provider to Apple On-Device. Confirm both toggles are disabled and shown off with the cue "Apple's on-device model can't do these reliably, so they're off.", that VoiceOver reads the reason, and that "at 3, no wait, 4" comes back translated as said. Switch the workflow back and confirm the toggles return to their stored values.
- With both spoken edits on and gpt-oss-120b on Cerebras, say "eu queria fazer dois, não, três testes", "chegamos ponto final", "olá vírgula tudo bem ponto de interrogação", and "ele disse abre aspas estou pronto fecha aspas". Confirm each comes out in the target language with the correction, punctuation, and quotes applied, and that "hum" and "é..." are dropped. Then combine several in one dictation and note what it gets wrong; that case is known to be less reliable.
- With formatting commands on and an OpenAI-compatible provider, say "in quotes hello" and "entre aspas bom dia", with Streaming delivery off and on. Confirm the result keeps its quotation marks, and that an ordinary dictation never arrives wrapped in quotes.
- In a Translate workflow's Output section, turn each spoken edits setting off and confirm only its behavior stops. Confirm a Custom workflow is unaffected.
- After real dictations, confirm Home's stats, app names, and heatmap. Confirm Privacy > Keep usage stats stops counting and Delete clears them, and that `usage-stats.json` holds no words you said.

## Personal glossary

- Add a real name such as "Syrup" plus a known mishearing, dictate a sentence containing the mishearing, and confirm the exact spelling lands on the clipboard with OpenAI-compatible, Apple On-Device, and Codex CLI providers.
- With an empty glossary, confirm existing workflow instructions and outputs are unchanged and no vocabulary block is sent.
- Add more than 100 unique terms, confirm Settings shows "only the first 100 are sent — trim the list", and confirm prompt-side composition silently excludes term 101.
- Put a short single-line term (60 characters or fewer) on the clipboard, choose Add Glossary Term… from the menu, and confirm Settings opens on the Glossary tab with the term pre-filled and focused. Repeat with multiline and over-60-character clipboard text and confirm the draft is empty.
- Pending real-speech verification: confirm the first 100 exact glossary terms applied through `AnalysisContext.contextualStrings[.general]` can improve the pre-transformation transcript. Confirm mishearing hints remain prompt-only and an empty glossary preserves the existing transcription path.

## Permissions and automated checks

- In Privacy, confirm permissions rows for Microphone, Speech, Notifications, and Accessibility reflect Not requested/Granted/Denied/Restricted states as applicable.
- Use each Request/Open action and confirm it routes to the correct system prompt or System Settings pane.
- Run `script/ci_test.sh` to compile production and run the isolated suite.

## Revise Last Result

- Complete a successful dictation, invoke Revise last result from the menu, speak a short adjustment, click Finish revision, and confirm the revised output replaces the clipboard and last result exactly once.
- Revise the revised result and confirm the second adjustment applies to the first revision, with no earlier conversational context carried forward.
- Start a revision and provide an empty/whitespace-only adjustment; confirm Syrup reports "Nothing heard," preserves the previous last result, and leaves the clipboard untouched.
- Cancel while a revision is recording, transcribing, and transforming before delivery commits; confirm each cancellation preserves the previous last result and clipboard.
- With auto-paste enabled, confirm the result reaches the clipboard before the settled Command-V attempt. Cancel before that clipboard commit must preserve the previous result; cancel after the commit must not interrupt the pending paste or remove the success-history record.
- With no eligible result, confirm the menu item is disabled and the revise shortcut is a no-op. A failed revision may preserve an eligible base after the original success leaves the history cap.
- In Hold to talk mode, confirm the revise shortcut starts on key down and completes on key up. In Press to toggle mode, confirm the first press starts and the second press completes.
- While a dictation or revision is transcribing or transforming, press the revise shortcut and confirm it is inert rather than canceling or starting another run.
- Confirm the default ⌥⇧` revise shortcut registers alongside dictation on the current keyboard layout, remains visible beside the menu item, and can be changed with the General settings recorder.
- Confirm revision rows in Recent use the `↻` prefix and spoken adjustment as their title.

## Context-Aware Workflows

- Native app: select text in Mail or TextEdit and confirm both a context-enabled Voice workflow and a Selected text workflow capture it at hotkey press.
- Electron app: select text in Slack and record whether Accessibility exposes the selection; a miss must degrade according to the workflow input mode without crashing or touching the clipboard.
- Browser: select page text and confirm the captured selection is the text visible at hotkey press, not a later selection changed while dictating.
- PDF viewer: select PDF text and confirm Accessibility capture succeeds when the viewer exposes `AXSelectedText`, otherwise the documented empty-selection behavior applies.
- Focus a secure/password field and confirm capture returns empty; no secure value may appear in a prompt, notification, history, or log.
- Use a selection longer than 20,000 characters and confirm only the first 20,000 trimmed characters reach the run; `selection_capture` telemetry must contain duration only.
- For a context-enabled Voice workflow with no selected text, confirm dictation still completes and the once-per-launch notification says `No selected text — ran without context`.
- Revoke Accessibility, run a context-enabled Voice workflow, and confirm it proceeds without context with the once-per-launch grant-Accessibility notification.
- With Summarize Selection or Translate Selection and no selected text, confirm the run fails immediately with `No text selected`, without starting recording or transcription.
- With Accessibility unavailable for a Selected text workflow, confirm Syrup requests the existing Accessibility grant and fails without touching the clipboard.
- Run Selected text workflows in both Hold and Toggle modes; the first press must start transformation immediately, key-up must be inert, and no microphone indicator may appear.
- Cancel a Selected text run during transformation and confirm no clipboard write or history record is created.
- Enable Persist history, complete and fail contextual runs, then inspect Recent items and the history file: selected text must be absent, transcript fallback and Retry must be hidden, and transformation notifications must expose neither action.
- In the workflow editor, confirm Input offers Voice and Selected text; Voice shows the selection-context toggle and the Apple On-Device recommendation, while Selected text hides that toggle.
- Pair a context-bearing workflow with Apple On-Device and confirm the selection remains local; switching to a cloud provider must send it only for the active run.
- Confirm Reply Draft templates enable context, while Summarize Selection and Translate Selection templates use Selected text input.

## Streaming Delivery

- Run `script/ci_test.sh` before manual checks. Confirm the SSE parser, cumulative-snapshot adapter, inactivity tracker, typist, settings, and AppState streaming tests are included.
- In Delivery, confirm Type it as it arrives defaults off, sits directly under Paste into the active app, and is disabled with its explanatory caption while Auto-paste is off.
- With streaming off, confirm OpenAI-compatible and Apple On-Device runs keep the existing atomic clipboard-plus-paste behavior byte-for-byte.
- Enable Auto-paste and streaming, grant Accessibility, focus a normal text field, and use a cloud provider for a long paragraph. Confirm visible text begins before generation completes, the clipboard receives the complete normalized result exactly once, and no final duplicate Command-V occurs.
- Confirm Console/signposts contain `streaming_first_delta` plus delivery mode `streamed`, without prompt, transcript, result, endpoint, model, or clipboard content.
- Press Esc after visible streamed text begins. Confirm typing stops immediately, the already-typed prefix remains, no clipboard write occurs, and no history record is appended.
- Switch to another app mid-stream. Confirm Syrup never types into the newly focused app, reports the focus downgrade once, finishes generation, and places the complete result on the clipboard with delivery mode `streamed_partial`.
- Trigger Secure Event Input before a stream starts and confirm Syrup silently uses atomic delivery. Trigger secure input after streaming begins and confirm typing stops while the complete result still reaches the clipboard.
- Force a provider disconnect after at least one delta. Confirm typing stops, no clipboard write occurs, failed history/transcript fallback rules still apply, and the notification warns that partial text may remain.
- Select Codex CLI and confirm delivery remains atomic even when streaming is enabled.
- If Apple On-Device is available, confirm its cumulative FoundationModels snapshots appear once as deltas. Force or simulate a non-append-only snapshot before the typist flushes: the fresh atomic generation may paste normally. Repeat after a visible prefix: typing must stop, the fresh atomic generation must complete to clipboard/history, and no final paste may duplicate or overwrite that prefix.
- Type into Notes and Messages to assess autocorrect-heavy targets; confirm no final duplicate paste and record any app-specific mutation of synthesized text.
- Type Portuguese accents and emoji, including a multi-scalar emoji, and confirm Unicode chunks do not split visible graphemes.
- Repeat a streamed run in an Electron editor such as Slack and confirm focus pinning and final clipboard behavior match native apps.
- Confirm matching-wrapper removal, unmatched-leading-quote preservation, and multiple trailing-whitespace trimming match atomic output for quoted, unquoted, and quote-only responses at both the cadence and large-buffer flush boundaries.
- Measure the 50 ms cadence, 200-character flush threshold, 20-UTF-16-unit event chunk, and frontmost-app polling overhead. If empirical tuning changes these constants, update architecture and record the measurements together.

## Learned glossary

- Enable Suggest terms from my recordings, download the comparison model, and dictate a sentence containing a deliberately mangled English technical term. Press Compare Now (or wait for the idle scheduler), confirm the suggestion appears in the Glossary tab, choose Add, and verify the next dictation uses the corrected spelling. Repeat with Dismiss and confirm the same term is not proposed again.
- With recordings pending, press Delete All next to "Waiting to be compared" and confirm the count drops to 0 and `Application Support/Syrup/Recordings/` is empty. Press Remove Model and confirm `Application Support/Syrup/WhisperModels/` is gone and the row offers Download again. Turn learning off with the model installed and confirm the Remove/Keep model dialog appears; Keep leaves the model and its Remove button reachable while learning stays off.

## Review fixes: manual acceptance checks

Automated checks use `script/test-isolated.sh`, which copies production components into a temporary project with an inert application entry point, a separate bundle ID, and ad-hoc signing. It avoids production hotkeys, startup cleanup, and model downloads. `script/ci_test.sh` builds the real app before running that suite.

The following checks require the signed production app and have not been established by the isolated suite:

- Cancel while microphone permission is pending, grant permission, and verify capture stays stopped. Immediately start another run after cancellation or a speech failure; verify it keeps its own status and microphone.
- Finish utterances with quiet final words and compare the transcript with the spoken phrase. Verify hold and toggle modes, selected microphones, denied speech permission, and missing locale models.
- With target pinning enabled, move between fields, browser tabs, windows, and apps during recording, transformation, and streamed typing. Verify typing stops and completion copies the full result. Repeat with pinning disabled for deliberate focus switching. Include secure fields and an editor that exposes incomplete Accessibility information.
- Use a streaming provider with auto-paste off. Confirm output appears in the existing cue and cancel leaves the clipboard unchanged. Turn the cue off and verify ordinary atomic delivery. Compare quoted output and revisions.
- During slow or unresponsive Accessibility selection reads, verify Esc and the menu remain responsive. Measure `selection_capture` and `hotkey_to_recording_started`; the configured deadline is 100 ms per AX message, not an end-to-end latency guarantee.
- Run learning, then begin dictation. Measure time until Whisper work and its model working set are released. Confirm foreground recording proceeds; repeat during a model download. An empty queue must not download a removed model.
- Compare accurate and fast recognition with the same consented Portuguese, English, mixed-language, technical-vocabulary, and quiet-final-word fixtures. Record final-word accuracy and release-to-transcript/clipboard latency. Keep preview visibility constant. Do not claim an accuracy improvement from the setting alone.
- Compare cold/warm end-to-end latency with learning off, on, and interrupted; include the `first_visible_output` span for passive preview and direct typing. Storage microbenchmarks do not establish whole-app latency.

## Recovery and provider reliability checks

- Switch apps during a slow selection read, and change fields while the selected-text attribute is being read. Confirm replacement text never reaches a provider. Selected text input must fail; Voice with optional selection context must continue without that context and show a notice. Verify the source field, rather than a later focused field, also pins delivery.
- Return `finish_reason: length`, `content_filter`, and `error` from atomic and streamed endpoint fixtures, and a streamed chunk with an `error` object followed by `[DONE]`. Confirm no final clipboard write or success feedback. For direct typing, confirm the already-visible prefix remains with the partial-text warning. Repeat with `stop` and a missing reason to verify compatible success.
- Use an endpoint that ignores `stream: true` and returns JSON. Connection testing and default-preview dictation must both succeed. Return an explicit unsupported-stream parameter error and confirm one atomic fallback; authentication, rate limits, unrelated parameter errors, malformed SSE, and a midstream disconnect must not retry automatically.
- Simulate clipboard failure after complete atomic and preview generation. Confirm Copy result again retains the exact output through repeated copy failures and performs no extra model request, audio capture, auto-paste, or recording analysis. Successful recovery alone creates a success record and feedback. Verify revision recovery preserves the generated revision, and selection recovery history excludes the selected input.
- Cancel before delivery in each mode. Confirm no pending recovery result for the cancelled run, no clipboard write, and no new history entry. Verify failed-delivery recovery stays in memory when Persist history is enabled, until a successful explicit copy creates ordinary history.

## Checks carried forward from completed plans

- Recheck revised clipboard/last-result replacement, revise-of-revise, and Accessibility trust persistence in the current signed app. An older manual checklist reported unchanged revision output and repeated trust prompts; automated behavior checks alone do not close those live reports.
- Measure revision-only provider preparation with the final spoken adjustment, and large-glossary token pressure on Apple On-Device. Measure editor autocorrect and focus polling in native apps and Slack before changing typing constants.
- Confirm glossary export decodes as `GlossaryList`, including all terms/mishearings. User terms take priority over built-in tech vocabulary, deduplication is case-insensitive, and the combined Speech vocabulary is capped at 100. Disable Common tech terms and compare vocabulary composition.
- With learning off, a dictation must create no recording entry. With learning on, successful voice dictations and revisions may create one WAV and one Apple-transcript sidecar with directory/file modes 0700/0600. Cancelled, failed, empty, and selected-text runs must leave no entry. Verify the 50-recording/7-day retention limits with disposable fixtures.
- Check visible recognition-model download progress, queued recording consumption and deletion after successful analysis, and retention/retry after failed analysis. Confirm only the opted-in transcript pair goes to the configured judge and audio stays local.
- Make recording deletion fail with a controlled fixture, then try disabling learning. The setting must remain enabled and explain the failure. Verify ordinary opt-out deletes pending recordings.
- The old v6-v9 checklist recorded an accepted gap for a valid SSE delta followed by a transport `URLError`, and a fallback-error warning selected from received deltas rather than posted text. Do not infer those cases are settled from broader stream-failure tests; confirm the exact observable behavior if changing that path.
- Follow [RELEASE.md](RELEASE.md) for signing, notarization, extracted-ZIP verification, and current-artifact retention.


## Review correction checks

- Pause the hotkeys and confirm their combinations reach another app. Edit the main and workflow shortcuts while paused, then verify they remain inactive until resumed. Repeat with an active recording and confirm pause cancels it.
- Keep the Glossary tab open, complete a learning-enabled dictation, and confirm the pending count increases. Run analysis or clear recordings and confirm the count updates without reopening Settings.
- Start a slow connection test, edit the URL or model, and start another test. The earlier completion must not replace the current status. Repeat after changing or removing the saved key.
- Run Codex against a disposable account home and fixture endpoint. Confirm the invocation uses `--ephemeral` and creates no session transcript. Do not inspect personal Codex session contents for this check.
- With Codex CLI selected, run a selected-text workflow on text that asks the model to run a shell command and print a local file. Confirm the result is the transformed text, with no file contents, and that the CLI's stderr shows no tool call. A run on 2026-11-13 with codex-cli 0.167.2 translated such text as data.
- Use `OpenAISSEParsingTests`, `AudioFailureTests`, `ProviderCredentialTests`, `HotkeyPauseTests`, and `RecordingArchiveCountTests` for synthetic CRLF, audio-overflow, credential-error, shortcut-registration, archive-count, and connection-status cases. Live speech, TCC, editor delivery, and signed-app behavior still require the manual checks above.


## Delivery follow-up for 2026-11-01

The isolated paste-delivery tests passed. The following live checks remain unrun because verification prohibited real input events and clipboard access.

- Stream multiline output into a chat editor. Confirm each line break inserts a new line without submitting, including CRLF output.
- Verify Command-V with QWERTY, Dvorak, Colemak, Dvorak-QWERTY-Command, and a non-Latin input source with an ASCII-capable fallback.
- Verify atomic output types once in Chromium 155 and 156, while Chromium 157 and Electron-style `Versions/A` retain Command-V. Confirm a successful streamed run never delivers again.
- During typed delivery, change the focused field or enable secure input. Confirm typing stops and the complete clipboard result remains available.

## Release path checks for 2026-11-01

The isolated tests drive the release tail with synthetic buffer levels and a manual clock. These checks need a real microphone and remain unrun.

- In Hold to talk and Press to toggle, release while still saying a final word. Confirm the word is in the transcript, for dictation and revision.
- Release after a clear pause. Compare `release_to_recorder_stopped` with a menu Finish revision stop on the same machine. The difference should stay within one buffer, about 85 ms at 48 kHz.
- In a noisy room and with music playing near the microphone, confirm releases still finish, never later than 200 ms after release. Record which ones reach the deadline.
- With a 16 or 24 kHz Bluetooth headset microphone, record `release_to_recorder_stopped`. A buffer there lasts 256 or 171 ms, so releases often reach the 200 ms deadline.
- Press Esc right after a release. Confirm no clipboard write, no history record, and no provider request.
- During a long toggle dictation and a slow Codex CLI transformation, run `pmset -g assertions`. Confirm one Syrup `PreventUserIdleSystemSleep` assertion named `Syrup is processing a request`, and confirm it disappears after success, cancellation, and failure. A standalone probe on 2026-11-01 showed that options and reason produce exactly this assertion.
- Play music, turn on Lower other audio while recording, and dictate. Confirm the music drops when recording starts, stays low through the release, and returns before the success sound. Repeat with Esc during recording and during the release, a failed run, and a volume change made during recording, which must survive the restore. With the setting off, confirm the volume never changes.
- With the setting on, force quit Syrup while recording, relaunch, and confirm the output volume returns to its earlier level.
- In Hold to talk, tap the dictation and revise shortcuts briefly. Confirm no sound, notification, history row, or clipboard change, and that the menu bar icon and recording indicator return to idle. A deliberate hold must still start and finish a run. In Press to toggle, two quick presses must still run.


## Workflow routing and transcription

Automated evidence is in `docs/verification/2026-11-01-workflows.md`. These manual checks remain unrun. Use a verification bundle ID, isolated defaults, and test credentials. Do not launch the installed app or read or write the user's clipboard during automation.

- Open Workflows and select a workflow. Under When it runs, use Add App…. Choose an application and check its icon and display name. Choose it for another workflow and check that its row moves. Remove the assignment with the minus button. Check that an unavailable app remains removable by bundle ID.
- Use the primary shortcut in a routed app and an unrouted app. Verify the routed workflow cue caption, locale, and hold release or toggle stop. Dedicated shortcuts and Revise must ignore routing. Change a route and verify the next run uses it.
- Choose + > Transcribe. Under Output > Action, verify Transcribe and the Clean up fillers and spoken formatting toggle. Verify that Source, selection context, target, tone, instruction, and provider override controls are absent. Its menu bar has no target or tone quick controls.
- With no API key and a broken provider URL, dictate in an installed locale. Verify complete clipboard delivery, optional atomic paste, success sound, and history persistence opt-in. Streaming delivery must not stream transcription output. Revise must use the configured provider. Retry and transcript fallback must be absent.
- Dictate English and Portuguese filler/formatting examples. Disable cleanup and verify verbatim trimmed output. Cancel while recording and finalizing. Check no clipboard change or history entry. With glossary learning enabled, check normal archive handling.
- Downgrade on isolated defaults. The older build sees the retained V1 list; V3 workflows remain preserved for upgrade. Old-build edits do not merge back into V3.

## In-app updater

- Use two authorized signed, notarized builds and a higher feed build. Verify manual check, download, install, relaunch, and installed version.
- Enable automatic checks. Confirm a scheduled reminder is discoverable for this menu bar app and its temporary Dock presence ends with the update session.
- Start dictation before a check and before installation. Confirm neither interrupts the run and deferred installation resumes after it finishes.
- Confirm the isolated test host never creates `UpdateController` or contacts the feed.

## Workflow corrections

- Add overlapping corrections, duplicate phrases, accented text, and a CJK-adjacent phrase. Verify longest match and stable tie order.
- Correct "open code" to "OpenCode" before "-based" and possessive "'s" or "’s". A "don" correction must leave "don't" and "don’t" intact.
- Change corrections during a run. Only the next run uses the change.
- Verify corrections in Translate, Transcribe with cleanup, and Transcribe without cleanup. Verify Selected text input stays unchanged.
- Restart with existing workflow settings and with a correction table. Verify persistence and no migration loss.

## Paste last

- Verify the shortcut has no initial binding, then record one in the Dictation tab.
- Deliver several results and a failure. Paste Last must choose the newest success and add no history entry.
- Retry an older failed revision after a newer success and fail the retry. Both Copy Last and Paste Last must select the newer success. With all successes evicted, verify the preserved revision fallback remains available.
- With automatic paste on, verify both Command-V and Chromium direct typing. With Accessibility off, verify the clipboard still gets the result and the existing permission notice appears.
- With automatic paste off, Paste Last must only copy the exact last result: no paste, no typing, and no sentence fit.
- With automatic paste on and Accessibility off, press Paste Last three times: the Accessibility notice appears once, and the copied checkmark shows every time. With an error still shown in the menu bar, Paste Last that copies replaces it with the checkmark.
- With automatic paste and target pinning on, dictate with no text field focused: the notice must say no text field had focus, not that the editor changed.
- Invoke during recording and processing. Verify no clipboard write or event. Change focus or start dictation during the paste delay and verify no delayed input.

## Spoken symbols

- In English Transcribe cleanup, dictate hashtag release, my underscore variable, and done comma thanks. Verify `#release`, `my_variable`, and `done, thanks`.
- Repeat with Portuguese equivalents, adjacent symbols, quotes, line breaks, and accented words.
- With both toggles on, check "done um comma thanks", "my um underscore variable", "bem ahn hífen vindo", and "e ahn barra ou". Expect "done, thanks", "my_variable", "bem-vindo", and "e/ou".
- Verify commas, colonel, hashtags, and words with combining marks do not match partial tokens.
- With symbols off, verify ordinary sentences containing "dois pontos", "barra", "underscore", and "hashtag" remain words. Disable cleanup independently and verify enabled symbols still expand. Translate and custom workflows have no symbols option.
- Load existing workflow blobs. Symbols must default off, including the built-in Transcribe template. Check the always-replaced word warning under the symbols toggle.

## Smart spacing

- Confirm the setting defaults off. With it off, verify delivery is unchanged and no caret read occurs.
- Enable automatic paste and spacing. Test after letters, digits, underscore, CJK characters, whitespace, and punctuation. The clipboard must contain the exact result in every case.
- Check after ❤️, 1️⃣, and a decomposed accented letter. Expect no prefix. A precomposed accented letter receives a prefix.
- Stream a single word, a short phrase, and more than 200 characters after a word. Each must post exactly one leading space while the clipboard retains only the result.
- Verify Command-V, direct typing, and streaming. Streaming must add at most one prefix, including empty initial chunks and fallback paths.
- Verify a selected range, secure field, unsupported editor, changed target, and slow AX response deliver without an unwanted prefix or event.
- Verify copy-only delivery never reads the caret. Supplementary characters that cannot fit the single-unit read use the unspaced fallback.

## Bluetooth microphone avoidance

- Select System default and make a Bluetooth headset the macOS default input. Verify the built-in microphone is used with avoidance on and the headset with it off.
- Close the lid. Verify a real external microphone wins, or Bluetooth remains when it is the only usable input.
- Save the Bluetooth microphone explicitly. Verify the choice remains with avoidance on and after restart.
- Verify Bluetooth LE, no built-in mic, missing saved devices, virtual and aggregate inputs, and non-Bluetooth defaults. Automated policy tests do not establish behavior on physical hardware.

## Sparkle helper signing regression

- Archive and export a local Developer ID build. Do not notarize for this check.
- Run `codesign --verify --deep --strict` on the exported app and on the app extracted from its ZIP.
- Inspect entitlements on Autoupdate, Updater.app, Downloader.xpc, and Installer.xpc. They must not inherit Syrup's audio-input, network-client, or get-task-allow entitlements. Autoupdate may retain Sparkle's application identifier.
- Build Debug with your own Developer ID signing and verify its nested signatures. No `--deep` signing flag is required in either configuration.

## First run

- Test a fresh install on a separate macOS account. Confirm the welcome window opens at launch and the Syrup window does not. Confirm a Mac with existing settings skips it.
- Quit midway and relaunch: it opens again. Close it or choose Skip setup and relaunch: it stays closed.
- Allow Microphone, Speech Recognition, and Accessibility from Permissions. Deny one and confirm the row offers Open Settings. Confirm allowing Accessibility turns on pasting.
- In Recipe, confirm the language starts from this Mac's language, and that The same language removes the Flavor step.
- In Flavor, save an API key, test the connection with a good and a bad endpoint, and confirm a failure stays on the page. Open Show Welcome Again with an existing setup: endpoint and model appear, and the key shows only as Saved.
- In Taste, hold the shortcut and confirm the result lands on the page and the clipboard, not as a paste. Switch to another app, dictate, and confirm it pastes there. Trigger a failure and confirm the message appears.

## Fn key

- Turn on Also dictate with the Fn key with Accessibility and Input Monitoring both off. In Hold to talk, hold Fn and release: it records and delivers. Tap it: nothing is delivered.
- In Hold to talk, double-tap Fn: recording starts and keeps going after release. Double-tap again: it stops and delivers. A single tap or a hold during that recording changes nothing. Tap then hold is an ordinary hold.
- In Press to toggle, a single Fn tap while idle does nothing. Two quick taps start recording, and one tap stops and delivers. A slow second tap does not start. A tap during Transcribing or Translating changes nothing. Double-tapping to stop must not start a new recording.
- With Dictation's shortcut set to Press Fn Twice, confirm a double-tap also starts macOS Dictation, as the caption warns. With another shortcut, it does not.
- Use Fn+Delete, Fn+arrow, and Fn+F1 in both modes: dictation must not continue or start. Do the same with Fn+Option.
- Click into a shortcut recorder and press Fn: dictation must not start. Pause the hotkey and turn the option off: Fn does nothing.
- Test a built-in keyboard and an external Apple keyboard. A external keyboard that does not send Fn sends no Fn event to macOS, so Fn is expected to do nothing there. With “Press globe key to” not set to Do Nothing, confirm the caption describes what happens.


## Caret fit

- With Match the sentence at the cursor on and automatic paste off, put the cursor in the middle of a sentence in TextEdit, Notes, Mail, Slack, and Chrome, dictate, and press Command-V: the first word is lowercase and no period appears before the following text. Repeat with automatic paste on: Syrup's paste gives the same text.
- Dictate at the start of an empty field, after a period, after a colon, and on a new line: the result keeps its capital. Dictate at the end of a field: the final period stays.
- Start a dictation with "I", an acronym, a glossary term, and a person's name mid-sentence: none of them is lowercased. End one with "etc." before following text: the period stays.
- Check History and Copy Last: they hold the original result with its capital and period. Use Paste Last in a different field: it fits to that field.
- Select a phrase mid-sentence and dictate over it: the fit uses the text around the selection. Turn on streaming delivery and repeat one mid-sentence case: the typed text and the clipboard match.
- Remove Syrup's Accessibility permission: the option is unavailable and the clipboard gets the original result. With the option off and smart spacing on, smart spacing still adds one space after a word in TextEdit, Chrome, and an Electron app. In a password field nothing is fitted or spaced.

## Early transformation

- In Models, turn on Start writing during a pause with Apple On-Device and an Apple speech workflow. Dictate a sentence, stay quiet for about a second, then release: in Console, category `PipelineMetrics`, the run logs `pause_transformation=hit` and a shorter `release_to_clipboard` than the same sentence released right away. Clipboard and history get one result.
- Speak again after a pause before releasing: the run logs `miss` or a new attempt, and the delivered text includes the last words. Press Esc during the quiet hold and while processing after release: nothing reaches the clipboard.
- With an OpenAI-compatible endpoint at `http://localhost:11434/v1`, repeat the hit case. Switch to a cloud endpoint, Codex CLI, a Parakeet workflow, Revise, Transcribe, and a selected-text workflow: none logs a `pause_transformation` line, each still delivers normally, and the note under the toggle matches.
- With the setting off, every voice run still logs `quiet_before_release_ms`. Record the values for a week of normal use before deciding on a default.

## Mishearing suggestions

- In Glossary, use one term's check button and then Check All with Portuguese (Brasil) and English workflows present. Each term shows suggestions, recognized correctly, or the missing prerequisite. Add one suggestion: it appears in the term's mishearings and in the next run's prompt. Dismiss another: it does not return while Syrup stays open.
- Confirm a suggestion made of everyday words carries a warning. Start a dictation during a check: the check stops and the dictation runs at normal speed.
- With Speech recognition denied, a language model not installed, and no voice for a language, confirm each state names the fix and nothing downloads or prompts.
