# Syrup — Product Definition

## One-liner

Press a key, speak, and get the text you needed on your clipboard — transcribed, translated, polished, summarized, or shaped by a one-shot workflow.

## Problem

Writing from speech is slow when the desired output is not the raw transcript. You may need a translation, a polished same-language rewrite, a concise reply, a summary, or a prompt for another tool. Existing dictation tools transcribe what you say verbatim; they do not transform it into the final text you meant to use.

## Core loop

1. User presses a global workflow hotkey (hold-to-talk or toggle, configurable).
2. Voice workflows record and transcribe on-device; Selected text workflows capture the current selection and skip the microphone entirely.
3. Translate and custom workflows send the finalized transcript or selected text to the chosen provider. Transcribe workflows skip transformation and optionally clean up fillers and spoken formatting locally. Voice transformation workflows may optionally attach the trigger-time selection as reference context.
4. The result lands on the clipboard and can optionally be pasted into the active app. With streaming delivery enabled, capable providers type into the pinned target as text arrives while the clipboard still updates once with the complete final result. The recording indicator also previews generated text without auto-paste. A subtle sound/icon change confirms it is ready.

Releasing the key, or pressing it again in toggle mode, stops at once if the microphone was already quiet. Otherwise the microphone stays open until it hears quiet or 200 ms pass, so a word still being spoken at release is kept. With opt-in glossary learning, the stop can also wait for the recording file to open. In hold mode, a tap shorter than 300 ms is ignored without a sound, notification, or history entry. A provider setup error that appears before the tap ends is still shown, because the next dictation would fail the same way.

For Voice workflows, total target latency after releasing the key is **under ~3 seconds** for a couple of sentences. Selected text workflows start transformation on the trigger press, so release-to-result latency does not apply.

## Revise last result

The separate revise shortcut records one spoken adjustment, such as “shorter” or “more formal,” and applies it to the newest successful result. It uses the active workflow's dictation locale and provider choice, then replaces the last result only after the revision succeeds.

A revision operates **only on the last result**, takes **one spoken instruction per press**, and carries **no accumulated conversation** — each press is still speak → text. Revising a revision is allowed (it operates on whatever the last result now is); nothing else is remembered.

**Revision privacy:** Syrup sends the captured previous result and the current revision instruction to the selected transformation provider. If that provider is cloud-backed, both leave the Mac. Syrup does not send unrelated history or content, and it never logs the previous result or revision instruction.

## First run

A fresh install opens a short welcome window: Welcome, Permissions, Recipe, Flavor, and Taste. A fresh install means no saved settings at launch, so anyone updating skips it. Quitting midway shows it again at the next launch; closing it or choosing Skip setup ends it. **Show Welcome Again** in General reopens it at any time, showing what is already configured.

Recipe starts from this Mac's language and creates the first workflow. Choosing **The same language** makes it a Transcribe workflow, which uses no AI provider, so Flavor is skipped. Flavor selects Apple On-Device on a fresh install when Apple Intelligence is ready. Allowing Accessibility turns on pasting. While Taste is open and Syrup is in front, results stay on its page and on the clipboard rather than being pasted.

## What it is / isn't

**Is:** a macOS menu bar utility. No dock icon. One icon, configurable global hotkeys, and one window for Home and settings that opens only when asked. The window has toolbar tabs: Home, Workflows, Dictation, Delivery, Models, Glossary, Privacy, and General.

**Isn't:** a text editor, a chat app, a meeting transcriber, a multi-turn assistant, or a Windows/Linux app. Workflows are strictly one-shot: one press, one input, an optional transformation, and one delivery.

## Configuration surface

| Setting | Options | Default |
|---|---|---|
| Trigger hotkey | Any key combo; hold-to-talk or press-to-toggle | ⌥ + ` (hold) |
| Revise hotkey | Any key combo; uses the global hold-to-talk or press-to-toggle mode | ⌥ + ⇧ + ` |
| Fn key | Also dictate with Fn alone. With Hold to talk, hold it, or double-tap to start and double-tap again to stop. With Press to toggle, double-tap to start and tap once to stop. Needs no permission. Keyboards whose firmware keeps Fn to itself cannot use it | Off |
| Microphone | System default or a specific macOS input device | System default |
| Target language | Any language (free text + common presets) | English |
| Tone | Presets: Neutral, Professional, Casual, Friendly, Concise + custom prompt | Neutral |
| Dictation language | Picker over the locales supported by on-device transcription (42 on macOS 26, incl. Português (Brasil) `pt-BR`) | Português (Brasil) `pt-BR` |
| Speech model | Per Voice workflow: Apple, or an opt-in download: Parakeet Ultra (25 languages, 632 MB), Parakeet Redux (25 languages, 220 MB), Nemotron Streaming 3.5 (28 languages, 640 MB), Parakeet Unified EN 0.6B (English, 595 MB), or Canary 180M Flash (English, German, Spanish, French, 256 MB) | Apple |
| Handle self-corrections | Translate voice runs: "at 3, no wait, 4" becomes "at 4", and hesitation sounds are dropped. Not with Apple On-Device | Off |
| Follow formatting commands | Translate voice runs: new line, new paragraph, make a list, numbered list, in quotes, open quote and close quote, period, comma, question mark, exclamation mark, in English and Portuguese. Not with Apple On-Device | Off |
| Keep usage stats | Word counts, speaking time, and app names for Home, on this Mac only | On |
| Translation provider | OpenAI-compatible endpoint (base URL, model, API key), Apple On-Device, Codex CLI (path, model from the account's list), or Claude Code when installed (path, model, account folder) | OpenAI-compatible |
| Workflows | Voice or Selected text input; Transcribe, Translate, Polish, Reply Draft, Summarize, Prompt Writer, selection templates, or custom one-shot instruction | Translate (Voice) |
| Per-app routing | Choose a workflow automatically for each application with the primary shortcut | No routes |
| Personal glossary | Exact spellings with optional mishearing hints, sent with every transformation | Empty |
| Auto-paste | Copy-only or paste result into the active app after clipboard write | Off |
| Streaming delivery | Type capable-provider output into the active app as it arrives; requires Auto-paste | Off |
| Match the sentence at the cursor | Fit the clipboard to the sentence at the cursor: lowercase mid-sentence, no final period before more text; needs Accessibility | Off |
| Start writing during a pause | Start the transformation during a quiet hold, with Apple speech and a provider on this Mac | Off |
| History | Recent dictations in memory; optional local persistence | In-memory only |
| Feedback | Success sound on/off; error notifications follow macOS notification permission | Sound on |
| Maximum recording duration | 1 second to 1 hour (non-linear detent slider) | 120 seconds |
| Lower other audio while recording | Turn the Mac's output down to 30% while recording, then restore it | Off |
| Launch at login | macOS login item toggle | Off |

The Translate workflow uses target-language and tone presets. Custom workflows use a user-authored instruction with an optional system-owned output contract: "Output only the result: no preamble, explanation, or quotes."

## Spoken edits and usage stats

Translate voice runs can add two separate instructions to the default prompt, each with its own setting in a Translate workflow's Output section. The two settings apply to every Translate workflow whose provider can do them. Self-corrections keep only what the speaker settled on. Formatting commands apply line breaks, paragraphs, lists, and quotation marks, and the command words do not appear in the result. When the words are the subject of the sentence, as in "add a new paragraph to the contract", they are translated normally. The model decides which case applies, so results depend on the model. Custom instructions, Transcribe, Revise, and selected text never receive these instructions.

They are advanced features, segmented by model:

- **Apple On-Device:** off, and the toggles are disabled with the cue "Apple's on-device model can't do these reliably, so they're off." On 2026-11-09 it handled plain translation in 12 of 12 runs but resolved self-corrections in 12 of 21 and line breaks or paragraphs in none of 12, and once invented a sentence. The stored settings stay as they were for workflows on other providers.
- **OpenAI-compatible:** opt-in, off by default, with a warning that they need a capable model and the recommendation "We recommend gpt-oss-120b on Cerebras." With that model configured, the editor says so instead. In the same test, `gpt-oss-120b` and `qwen-3.8-27b` on Cerebras both passed 17 of 18 formatting runs and 19 of 21 self-correction runs; Qwen twice turned "quarta-feira" into Thursday, so the recommendation stays `gpt-oss-120b`.
- **Codex CLI and Claude Code:** opt-in, with no warning.

Quotation marks the speaker asked for with "in quotes" or "entre aspas" reach the result. Syrup still removes quotation marks a model wraps around a whole result unasked.

A dictation that combines several commands is less reliable than one command at a time: on 2026-11-10 `gpt-oss-120b` got 9 of 20 such runs fully right, against 138 of 140 for single features. A fragment left hanging before a command, as in "e é... ponto final", is usually kept as words.

The evidence is in `docs/verification/2026-11-09-model-comparison/` and `docs/verification/2026-11-10-spoken-edits-round2/`.

Home shows words per minute, lifetime words, fixes, an estimate of time saved against typing at 40 words per minute, a Sunday-to-Saturday activity grid with current and longest streak, and top apps. Words per minute uses up to the last 100 dictations under 400 seconds and leaves out quiet stretches where it can. Fixes count glossary replacements and filler words Syrup removes itself, not what a provider cleans up. Revisions, selected-text runs, retries, and failed or cancelled runs do not count. Stats hold numbers and app bundle identifiers, never transcript or result text. They stay in `Application Support/Syrup/usage-stats.json` at 0600, are never sent anywhere, and can be turned off or deleted under Privacy.

## Workflows

The primary shortcut uses the workflow assigned to the frontmost app, or the active workflow when there is no assignment. Dedicated workflow shortcuts and Revise ignore app routing. Configure assignments in Workflows, under When it runs. Adding an app already assigned elsewhere moves its assignment. App identity stays on this Mac and is excluded from requests, logs, notifications, and history. Usage stats keep a per-app word count locally and can be turned off.

Models lists every speech model with accuracy and speed bars, language and live-text badges, the workflows that use it, and Download and Delete. Nemotron Streaming 3.5 and Parakeet Unified EN show their own words as you speak; Apple runs alongside them as the fallback. The bars come from synthetic clips, and real voices may differ. On those clips Parakeet Unified EN was the most accurate English streaming option, Nemotron was weaker than Apple on short Portuguese clips and stronger on long ones, and Canary was small and quick but less accurate than Parakeet in English. Apple stays the default. Canary can translate into English, but Syrup uses it only to transcribe; translation stays with your provider.

Each Voice workflow, Transcribe included, chooses its speech model under Input > Speech model. Apple is the default and needs no download. Parakeet Ultra and Parakeet Redux run on this Mac for the 25 European languages they support, Portuguese and English among them, and need a Mac with Apple silicon. On 200 real Brazilian Portuguese recordings, Ultra got 4.2% of words wrong, Redux 5.3%, and Apple 6.8%. Redux is the smaller download, 220 MB against Ultra's 632 MB, but its first load takes several minutes and it finishes long dictations more slowly. A model downloads from Hugging Face only after you choose Download, and no audio or text is sent. Ultra replaced Parakeet v3, which 0.9 offered: workflows that chose v3 use Ultra, and Ultra downloads at the first launch. A v3 download is deleted only once Ultra is on disk; if Ultra's download fails, v3 stays and the next launch tries again. While you speak, Apple still shows the live transcript, and the delivered text comes from Parakeet. Parakeet transcribes a dictation of up to a minute in one pass after you release the key, and splits longer dictations only at pauses. Until the model is downloaded and loaded, the workflow uses Apple and says so once per launch. If Parakeet fails or hears nothing on a dictation, Syrup delivers Apple's transcript instead. If both fail, recording stops at once and shows Apple's error. A press with only room noise ends as "Nothing heard", as it does with Apple.

Choose + > Transcribe in Workflows, or select Transcribe under Output > Action. This voice-only workflow needs no API key or provider connection and always delivers the complete transcript atomically. Its single cleanup toggle removes English or Portuguese hesitations and expands spoken line breaks, paragraphs, and quotes with local rules. Other languages retain their text. It does not use an LLM or a glossary prompt. Opted-in glossary learning and Persist history still apply. Transcription results support Revise through the configured provider; Retry and transcript fallback do not apply.

## Context-aware workflows

- A Voice workflow can opt in to attach the text selected when its hotkey is pressed as reference context for that run.
- A Selected text workflow transforms the current selection directly, without recording or transcription. Built-in templates cover Summarize Selection and Translate Selection.

Selection access is opt-in per workflow, never global or default. Captured text is trimmed and capped, sent only to that run's provider, and never logged or stored in history or settings. Contextual history records exclude the selection and disable Retry because the original run cannot be reproduced faithfully. Selection capture uses macOS Accessibility directly; Syrup never synthesizes Command-C or temporarily replaces the clipboard. Changing the source app or field during selection capture aborts Selected text input or omits optional voice context with a notice. The workflow editor recommends Apple On-Device for context-bearing workflows but does not force a provider.

Dictation language is explicit, not auto-detected: on-device transcription runs one language model at a time, and a fixed locale is what makes recognition accurate. Selecting a new language triggers a one-time on-device model download (with progress shown in Settings); after that it works fully offline. The dictation language is also switchable from the menu bar dropdown for users who dictate in more than one language.

## User stories (v1)

- As a non-native English speaker, I dictate a Slack reply in Portuguese and paste it in English with a professional tone.
- As the same user, I switch tone to "Casual" from the menu bar dropdown without opening settings.
- As a privacy-conscious user, I point the LLM endpoint at my local Ollama/LM Studio server and nothing leaves my machine.
- As a privacy-conscious user, I choose Apple On-Device and keep both transcription and transformation offline. It rewrites my own words on sensitive topics instead of refusing them.
- As a ChatGPT/Codex subscriber, I switch translation to the local Codex CLI and avoid managing a separate API key.
- As a Claude subscriber with Claude Code installed, I pick it as the writing provider the same way, with no API key.
- As a power user, I bind a second hotkey to a Polish workflow that cleans my dictated Portuguese without translating it.
- As a user replying to an email, I attach the selected message to a Voice workflow and dictate the reply I want without storing the message in Syrup history.
- As a user working from existing text, I run Summarize Selection without activating the microphone.
- As a user recovering from a failed endpoint, I retry a recent dictation without speaking again and keep the original provider unless I explicitly choose another.
- As a user whose clipboard write failed, I choose Copy result again to recover the completed output without repeating dictation or generation.
- As a user mid-dictation, I can cancel (Esc) and nothing is written to the clipboard.
- As a user refining the latest output, I speak one adjustment and revise it without starting a conversation.

Auto-paste and direct typing default to the editor focused when the run began, including its field identity. Changing fields, tabs, or apps keeps the complete result on the clipboard. Disable "Keep delivery in the original editor" to deliberately move focus during a run.

Live transcript display is independent of recognition accuracy. The default uses accurate recognition; "Prefer faster recognition" explicitly trades context for speed. Learning runs yield to foreground work, and an empty learning queue never downloads a removed model. Clear History and persistence opt-out report deletion failures instead of claiming success. Turning Keep history across restarts on keeps results from that moment: results made while it was off stay in memory only, until Syrup quits.

Streaming delivery is the narrow exception to cancellation leaving no visible trace: cancel stops generation and typing immediately, writes no clipboard or history record, and leaves any already-typed prefix in the target app. Synthesizing deletes would be destructive and unreliable across arbitrary editors.

## Feedback & states

The menu bar icon reflects the pipeline state: idle → recording (filled/red tint) → processing (spinner/pulse) → success flash. Errors (no mic permission, endpoint unreachable, empty transcript) show a non-intrusive notification with the reason. While a run is in progress, the Mac does not idle-sleep and macOS does not nap Syrup.

## Menu bar dropdown (quick controls)

- Active workflow, with inline dictation language / target / tone quick controls for Translate workflows
- Add Glossary Term… quick capture, with eligible short single-line clipboard text pre-filled in the Glossary tab
- Last result with re-copy/revise actions, plus recent history (click to re-copy or retry failures)
- Pause/resume hotkey listening
- Open Syrup…, Quit

## Non-goals for v1 (candidates for later)

- Local LLM bundled in-app
- Multi-turn conversations or follow-up context between workflow runs

## Success criteria

- Cold start to ready < 1s; hotkey always responsive while app runs.
- Round-trip (release key → clipboard) < 3s for typical utterances on a good connection; opt-in streaming delivery should make first visible text arrive earlier for capable providers.
- Works fully offline for transcription; Apple On-Device can also transform offline when Apple Intelligence is available. Other provider failures degrade gracefully with clear errors, history, retry, and transcript fallback. Retry keeps the recorded provider; older records require an explicit provider choice. Known truncated or filtered responses are failures, even if some streamed text is already visible. Atomic-only endpoints can still complete when output preview is enabled.

## App updates

Updates are inactive in source builds until a publisher supplies both the update feed and public key. The update controls remain visible, but checking is unavailable without that configuration.

Choose **Check for Updates…** in the menu, or enable automatic checks in the General tab. Checks and installation wait for dictation to finish. Scheduled reminders temporarily show Syrup in the Dock with an Update badge. Update checks do not send system profiles.

## Workflow corrections

Voice workflows can replace misheard words or phrases before transformation or Transcribe cleanup. Add **Heard** and **Replace with** pairs in the workflow editor. Matching ignores case and respects word boundaries, including unspaced scripts. A hyphen is a boundary. An apostrophe is a boundary before a possessive `s`, so corrections can precede possessives while leaving contractions such as "don't" intact. Longer overlapping phrases win, with editor order breaking ties. Output is literal and cannot trigger another correction. Empty lists leave the transcript unchanged. Corrections stay in local workflow settings and are never logged.

## Paste last result

Use **Paste last result** beside **Copy last result**, or bind its shortcut in the Dictation tab. Both Copy Last and Paste Last prefer the newest successful result over a failed revision's preserved base. If history has evicted all successes, they retain the preserved revision fallback. With automatic paste on, Paste Last copies that result and delivers it through the same paste or direct-typing strategy as dictation; Accessibility remains required for delivery, and without trust the result still reaches the clipboard and the existing notice explains the permission. With no text field focused, the result is copied and Syrup says so. With automatic paste off, Paste Last only copies, like Copy Last, because Syrup uses Accessibility only for the opt-in delivery features. Active runs ignore the action.

## Spoken symbols in Transcribe

Transcribe offers a separate **Replace spoken symbols** toggle, off by default, including in the built-in template. The toggle lists the English and Portuguese words that it always replaces, even in ordinary sentences. Enable it only when that replacement is intended. **Clean up fillers and spoken formatting** retains its previous behavior and works independently of symbols. Translate and custom workflows have no symbols option.

## Smart spacing

The Delivery tab offers **Add a space after a word**, off by default and available with automatic paste. Delivery reads only the unit immediately before an insertion caret using existing Accessibility permission. A word character adds one space to pasted or typed output; the clipboard keeps the exact result. Selected ranges, unreadable fields, secure input, and timeouts deliver without a space. Emoji variation selectors, keycap marks, and decomposed accents use the same unspaced fallback because the one-unit read cannot identify their base character. Precomposed accented letters qualify for spacing. Streaming adds the prefix once, before its first text. No caret content is saved or logged.

## Bluetooth microphone avoidance

**Avoid Bluetooth microphones** is on by default. When System default selects Bluetooth or Bluetooth LE, Syrup uses the built-in microphone, then the first other real input, then the Bluetooth device if no alternative exists. The built-in microphone is excluded while the lid is closed. An explicitly saved Bluetooth microphone stays selected. Turn the option off to follow macOS's default unchanged.

## Match the sentence at the cursor

The Delivery tab offers **Match the sentence at the cursor**, off by default. When the cursor is in the middle of a sentence, the result starts with a lowercase word, and when text follows the cursor its final period is dropped. Names, glossary terms, acronyms, "I", and abbreviations keep their capitals and periods. The fitted text is what goes on the clipboard, so it applies whether Syrup pastes or you press Command-V yourself, and it works with automatic paste off. History keeps the original result; Copy Last copies it unchanged, and Paste Last fits it again for where you paste. Syrup reads up to 64 characters before the cursor and 16 after it, in the editor it pastes into or the app in front, using Accessibility; without Accessibility the option is turned off and can't be changed, and a note links to Privacy; your choice is kept for when Accessibility is allowed. It sits at the top of the result settings, apart from the paste options, because it doesn't depend on paste. With only smart spacing on, it still reads one character. Fields Syrup can't read get the result unchanged. No cursor content is saved or logged.

## Start writing during a pause

Models offers **Start writing during a pause**, off by default. When you go quiet for 300 ms while still recording, Syrup transcribes what it has heard so far and starts the transformation in the background. At release it uses that result only when the final transcript is identical; otherwise it runs as usual, so the delivered text never depends on the early start. It applies to voice dictation with Apple speech and a provider that keeps text on this Mac: Apple On-Device, or an OpenAI-compatible server on localhost or a loopback address. Cloud endpoints, Codex CLI, and Claude Code never start early, because that would send an unfinished transcript off the Mac. Revise, Transcribe, selected text, and downloaded speech models work as before. When no voice workflow can use it, the toggle is turned off and can't be changed, and a note says it only works with Apple On-Device models or a server on this Mac, and names a workflow whose speech model is in the way. Your choice is kept for when a workflow qualifies again. Otherwise a note names the workflows it reaches and says why the others don't. The audio copy it needs stays in memory, holds at most 90 seconds, and is discarded when recording ends.

## Check how dictation hears your terms

In Glossary, a term's check button or **Check All** has a system voice say each term in up to three of your workflows' dictation languages, and on-device dictation writes down what it hears. Each row shows the result, and suggestions appear under the table, where you can add one to the term's Sounds like list or dismiss it. Forms made only of everyday words ask first, because as hints they can make the AI rewrite ordinary sentences. A check needs an installed voice, the language's speech model, and Speech Recognition access, and says how to get whichever is missing; it never downloads or asks for permission on its own. Checks stop when a dictation starts. Results stay in memory, audio is never saved, nothing leaves the Mac, and nothing is kept until you add a suggestion. A system voice isn't your voice, so suggestions are hints to review.
