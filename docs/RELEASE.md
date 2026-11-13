# Release packaging

Syrup releases are built from `project.yml`. Regenerate the Xcode project rather than editing `Syrup.xcodeproj` directly.

The source version is 1.0/build 14. The source tree does not select a publisher, signing team, or update server. Follow [UPDATES.md](UPDATES.md) to supply your own distribution settings, prepare a notarized release, review the artifacts, and publish an authorized update.

## Verification and records

Verify version/build, bundle identity, arm64 and x86_64 architectures, strict recursive code signatures, hardened runtime, timestamp, and entitlements. Do not ship `get-task-allow`. The release script repeats signature, notarization-ticket, and Gatekeeper checks on the final ZIP extracted with both `ditto` and `unzip`.

Record the source commit, test/build results, signing identity, notarization status, checksum, and extracted-ZIP verification in a dated `docs/logs/` file. A running build or a successful upload does not establish a finished release. Omit personal paths and use placeholders for account identifiers in public records.

Historical distribution evidence is retained in the [1.0 log](logs/2026-11-11-syrup-1.0.md) and earlier dated logs. Identifying details in those records have been replaced with illustrative placeholders; they are not distribution configuration for a new checkout.

## Keep and discard

Keep the latest final ZIP, checksum, compact verification evidence, and complete `.xcarchive` with its dSYMs for crash symbolication. Keep credentials outside the repository.

After final verification, discard task-owned duplicate ZIPs, exported app copies, and build intermediates that are no longer needed. Do not prune shared caches or erase history as part of project-folder cleanup.
