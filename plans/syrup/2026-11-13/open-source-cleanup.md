# Open-source cleanup

## Goal

Remove personal identifiers and developer-machine assumptions from the publishable project without adding product features.

## Context

The tracked project includes app source, tests, build and release scripts, evaluation fixtures, screenshots, and historical documentation. Generated builds, private environment files, and Git metadata are outside the publishable source tree.

## Constraints

- Preserve dictation, transformation, clipboard, and privacy behavior.
- Use neutral application identifiers and explicit maintainer-supplied distribution settings.
- Keep credentials and private runtime data untouched and out of tracked files.
- Sanitize historical documentation without presenting placeholder identities as verified release facts.
- The original cleanup did not rewrite history. A subsequent request authorizes a local history reset after a verified backup. Do not publish, deploy, or change the running app.
- Use independent fresh-context reviews. Resolve findings and repeat until no changes are requested.

## Done-when

- Source, tests, scripts, and configuration contain no personal identity or machine-specific values.
- Documentation uses generic examples where local setup is useful.
- The project generates, builds, and passes relevant isolated tests.
- Release configuration and validation are checked without signing, publishing, or contacting personal infrastructure.
- The final independent review finds nothing else to change.

## Progress

- Initial inventory: 351 tracked files; working tree clean before cleanup.
- Found personal bundle namespaces, signing team, update feed and public key, release repository and commit identity, notarization profile, and test names.
- Production Debug build passed; built app has the neutral ID, an ad-hoc signature, and no update configuration.
- Full isolated suite passed after correcting the split-name fixture. Release and recognition-evaluation unit tests passed.
- OCR covered all 48 tracked images. The first review found device identity in ICC chunks that the initial metadata pass missed; the follow-up removed those chunks from 37 screenshots and verified unchanged pixel data.
- Verification receipt: `docs/verification/2026-11-13-open-source-cleanup.md`.
- Addressed every first-round review item, including optional release identifier redactions. A second independent review is required before completion.
- Addressed the second review: documented inactive source-build updates, replaced the remaining checkout path, removed local archive assumptions and release fingerprints, added empty-key environment examples, confirmed synthetic fixture provenance, and explicitly retained public image-generation provenance. A third independent review is required.
- Addressed the third review by removing historical process vocabulary, personal pronouns and desk/activity details, plus the remaining numeric-only release commit ID. Added shared cache/bytecode ignores. A fourth independent review is required.
- Addressed the fourth review by generalizing remaining host activity and installed-browser details and removing references to private plans and working-tree state. A fifth independent review is required.
- Complete: the fifth independent fresh-context review returned NO CHANGES NEEDED. Validation and scope are recorded in the verification receipt. The cleaned source snapshot is packaged separately from Git history and ignored local state.
- Subsequent authorized action: back up existing history and local Git metadata outside tracking, then create one initial commit from the cleaned snapshot with neutral authorship. Verify the backup, new ancestry, and file contents; leave remote history unchanged.
