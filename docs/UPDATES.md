# Prepare an in-app update

Syrup embeds Sparkle 2.10.1. Local builds have no update feed or public key and do not start the updater. Distribution builds receive both values from the release command.

Releases and the update feed live in the source repository: each version is a GitHub release, and `appcast.xml` sits at the repository root on the default branch. Supply your own GitHub repository, its HTTPS appcast URL, Apple Developer team, and local notarization profile. A separate release repository also works, as long as it has `appcast.xml` at its root. The `appcast.xml` in this repository starts empty; a fork publishes to its own repository and feed. Keep the matching Sparkle private key in the login Keychain under Sparkle's default `ed25519` account. Never export it into the repository.

## Prepare for review

1. Set the marketing version and a strictly increasing integer build number in `project.yml`.
2. Run `script/test-isolated.sh`.
3. Download the Sparkle 2.10.1 distribution and unpack it outside the tracked source.
4. Run the command below with your publisher settings. The values are examples.
5. Inspect `appcast.xml`, `review.json`, the notarization log, and the final ZIP under `dist/updates/<version>-<build>`.

```sh
script/release.sh \
  --sparkle-tools /path/to/Sparkle/bin \
  --feed-url https://raw.githubusercontent.com/example/syrup/main/appcast.xml \
  --release-repo example/syrup \
  --team-id TEAMID1234 \
  --public-key "$SPARKLE_PUBLIC_KEY" \
  --notary-profile syrup-notary
```

The feed must already exist, even if it has no releases. Preparation archives a universal Developer ID build, submits it for notarization, requires Accepted, staples the app, and verifies the extracted ZIP. It checks nested signatures against the supplied team and validates the appcast signature against the supplied public key. It refuses an existing output directory or a build number already in the live feed. Nothing is published.

The command passes `SYRUP_UPDATE_FEED_URL`, `SYRUP_UPDATE_PUBLIC_KEY`, `SYRUP_DEVELOPMENT_TEAM`, and `SYRUP_CODE_SIGN_IDENTITY` to `xcodebuild`. The two signing variables apply to the app target only; overriding `CODE_SIGN_IDENTITY` directly also reaches Swift package resource bundles and fails the archive. These values are not stored in the source manifest. The review receipt records the publisher configuration and artifact hashes.

## Publish the reviewed artifacts

Run this only with authorization to publish the version and target repository. Repeat the same publisher arguments and add `--publish dist/updates/<version>-<build>`. The notarization profile is not needed at this stage.

Configure your Git commit name and email before publishing. The temporary clone uses your Git configuration; the script supplies no author identity.

Publishing verifies the manifest, publisher configuration, and reviewed artifact hashes again. It uploads the ZIP to a GitHub release and pushes the feed from a temporary clone. The release tag is created at the tip of the default branch, and the feed commit lands on that branch, so push the commit you built from before publishing. If the upload succeeds but the feed push fails, retain the review directory and inspect the release and repository before retrying.

## Verify an installed update

Install an authorized signed, notarized build containing the public key. Publish a higher authorized build through the reviewed flow. Choose **Check for Updates…**, install, and confirm the installed version, signature, and running app. Repeat with automatic checks enabled, during an active dictation, and after it finishes. Checks and relaunch defer during active runs. Automatic downloads and system profiling are disabled.

## Local signing checks

Use Archive and Export for distributables. `zip_app` in `script/release.py` excludes AppleDouble entries that can break the signed bundle after extraction. Do not add `--deep` when signing: it can copy the app's entitlements into Sparkle helpers. Recursive signature verification is intentional.

The verifier rejects audio-input, network-client, and debug entitlements on nested code. It checks the supplied team identity, timestamps, hardened runtime, both architectures, notarization tickets, and Gatekeeper acceptance.

An ordinary Release build is not a size estimate for an Archive export. Historical measurements and local acceptance limits are recorded in [the follow-up verification report](verification/2026-11-01-follow-ups.md).
