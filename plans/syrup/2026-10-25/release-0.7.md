# Package Syrup 0.7

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

Build, sign, notarize, and verify the Syrup 0.7 distribution ZIP.

## Context

The user requested a distribution after the correctness fixes were pushed as `e2a9a09bfcd3284d0b4ab136756ad601d2b8b79e`. The previous distribution is 0.6, build 6. This release increments the manifest to 0.7, build 7.

## Constraints

- Generate the Xcode project from `project.yml`.
- Use the existing Developer ID identity for team `TEAMID1234` and the `syrup-notary` notarization profile.
- Build both arm64 and x86_64 with hardened runtime, a secure timestamp, and no debug entitlement.
- Preserve the current distribution until the new ZIP passes verification.
- Retain the complete 0.7 archive and verify its dSYM UUIDs against the distributed binary.
- Do not launch or replace the installed app, modify credentials, or publish a GitHub release.

## Done-when

- The isolated test suite passes.
- The universal Release archive and Developer ID export succeed.
- Apple accepts notarization and the app has a valid stapled ticket.
- An extracted copy of the final ZIP passes signature, ticket, and Gatekeeper checks.
- Version, bundle identity, architectures, dSYM UUIDs, checksum, and results are recorded in `docs/logs/2026-10-25-syrup-0.7.md`.

## Result

Completed. All 372 tests passed. Apple accepted notarization, and the extracted final ZIP passed every packaging check. The distribution, checksum, complete archive, matching dSYMs, and verification evidence are retained.
