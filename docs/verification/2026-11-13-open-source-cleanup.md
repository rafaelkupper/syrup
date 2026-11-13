# Open-source cleanup verification

## Scope

The publishable working tree was audited across source, tests, build settings, release scripts, evaluation fixtures, historical documentation, and all 48 tracked PNG images. Git metadata, ignored private environment files, and old local build outputs are excluded. No Git history was rewritten and nothing was published.

## Changes

- Replaced the personal application namespace with `org.syrup` throughout the app, tests, and generated-project inputs.
- Removed embedded publisher identity, signing team, update feed, public key, notarization profile, and release commit author overrides. Local builds use ad-hoc signing. Releases require explicit publisher arguments.
- Replaced personal names in fixtures and removed personal references from documentation. Historical records label identifying values as placeholders.
- Kept generic platform paths, loopback endpoints, third-party package URLs, public service endpoints, and reserved example addresses where needed.
- Added repository ignore rules for private environment variants and local agent settings.

The namespace change gives this source build a separate preferences and API-key namespace from previous private builds. No user data was migrated or deleted. No dictation or transformation behavior was changed.

## Checks

- XcodeGen generation and production Debug build passed without a distribution identity.
- Built app inspected: `CFBundleIdentifier=org.syrup.SyrupApp`, empty feed and public key, ad-hoc signature, no signing team.
- Full isolated suite passed: Swift Testing reports 704 tests across 90 suites. Four opt-in speech/timing checks were skipped.
- Release configuration tests passed: 3 tests, with mocked network, signing, and publishing tools. They cover explicit publisher propagation, early rejection of invalid configuration, and publisher mismatch on publication.
- Recognition evaluation unit tests passed: 18 tests.
- Python, shell, plist syntax, and `git diff --check` passed.
- Known identity, machine-path, email/credential-pattern, and endpoint scans found no remaining personal values in publishable text. Generic fixture values and third-party package identities were retained.
- OCR inspected all 48 tracked PNGs and found no personal identity or private endpoint in their visible text. The first metadata check covered text, XMP, and EXIF but missed embedded ICC profiles. The independent reviewer caught that omission. All 37 device-specific ICC chunks were removed; every compressed pixel-data chunk and every other PNG chunk is byte-for-byte unchanged. The app icon's public C2PA provenance is listed below. A second full chunk inventory and CRC check passed for all 48 images.
- Real release signing, notarization, publication, installed updates, microphone capture, and live clipboard interactions were not run.

Initial test failures exposed an incomplete replacement of a split-name fixture and name-classifier differences between candidate fixtures. The final generic fixture passes both streaming thresholds; production name-handling logic is unchanged.

## Independent review

The first fresh-context reviewer found six cleanup items: device identity in screenshot ICC profiles, named desk peripherals, personal agent/tooling records, an account label in this receipt and the plan, stale signing instructions, and account-linked release run/submission IDs. All six were addressed, including the optional ID redactions. The two agent-operation TSV logs were removed; product verification reports remain.

The second independent reviewer found four remaining documentation/metadata items and three optional items. The build guide now describes generated artifacts as local outputs, product and architecture docs explain inactive source-build update controls, and the last checkout-derived package path is an explicit example. Release log hashes, account run IDs, and exact artifact sizes were redacted. The optional environment inputs now have a placeholder-only `.env.example`.

The unusual recognition-fixture names are synthetic: the original recognition report describes its manifest as 24 invented sentences, and the evaluation command calls it the committed invented/synthetic manifest. The usage guide now states this explicitly.

The 1024-pixel app icon deliberately retains its `caBX` C2PA provenance. It identifies the image generator and signer, with asset-specific manifest IDs; it contains no personal account name, private endpoint, or local machine path. This is public asset provenance, not developer configuration. The chunk is documented rather than removed.

The third reviewer found remaining named process vocabulary, a numeric-only feed commit ID, gendered references, and incidental host-activity descriptions. These were removed or generalized. Shared ignore rules now exclude Python bytecode and all task caches.

The fourth reviewer requested generalizing the remaining background-activity and installed-browser details and removing references to unrelated private plans. Those descriptions now retain only relevant workload, version-family, and preservation facts.

The fifth independent fresh-context review returned **NO CHANGES NEEDED**. It checked the publishable working tree, all 48 PNG chunk inventories, identity and endpoint patterns, fixtures, build/release configuration, shell/plist syntax, and both Python test groups (3 release tests and 18 evaluation tests). It did not rerun the production build or the full Swift suite; those passed earlier against the same application and test code.

Acceptance is complete for the cleaned source snapshot. Git history, ignored credentials, installed application state, old release artifacts, and local caches remain outside this cleanup. The source ZIP under `dist/open-source/` includes only current publishable files and excludes those local/history artifacts. No application code changed after the passing full Swift suite; the follow-up rounds change documentation, example environment inputs, and screenshot color-profile metadata.

## Subsequent local history reset

A later request authorized replacing local Git history with one initial commit of the cleaned source. The original history is preserved in a verified bundle and the full original Git directory under the ignored `.git-history-backup/` folder. The backup includes old refs, reflogs, and local repository configuration. The new initial commit uses a neutral contributor identity. No remote history is changed or force-pushed.
