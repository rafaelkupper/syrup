# Review corrections

## Goal

Fix the five correctness findings and the learning-count and endpoint-status improvements from the project review.

## Context

The review reproduced CRLF parsing, late audio overflow, and false credential-deletion success. Source inspection found persistent Codex sessions, registered shortcuts while paused, stale learning counts, and stale connection-test results. The checkout already contains unrelated cleanup changes.

## Constraints

- Preserve existing cleanup changes and durable instructions.
- Keep user content and credentials out of logs and fixtures; use synthetic test data.
- Use the isolated test host. Do not initialize production services in unit tests.
- Keep changes local; no release, deployment, push, or PR.

## Done-when

- Codex execution cannot persist sessions, independently of history settings.
- Audio errors survive every forwarding stage and prevent successful delivery.
- SSE accepts LF and CRLF, including split chunk boundaries.
- Missing credentials and failed credential reads/deletes are distinguishable.
- Pause unregisters shortcuts and resume restores the current workflow set.
- Learning counts update after archive changes and background processing.
- Connection status only describes the configuration that was tested.
- Focused regression tests, the full isolated suite, and the production build pass; remaining live checks are recorded.


## Delivery follow-up

After verification, the user authorized committing and pushing all pending changes to main. This replaces the earlier local-only delivery constraint. No release or production-app restart was requested.
