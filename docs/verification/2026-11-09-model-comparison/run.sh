#!/bin/sh
# Usage:
#   run.sh cerebras MODEL [REPEATS]   e.g. run.sh cerebras qwen-3.8-27b 3
# The Cerebras key is read from CEREBRAS_API_KEY in the repository's git-ignored .env.
#   run.sh apple [REPEATS]
# Results append to results.jsonl; completed case keys are skipped on rerun.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
artifacts="$root/docs/verification/2026-11-09-model-comparison"
# ARTIFACTS overrides where fixtures.json is read and results.jsonl is written.
out="${ARTIFACTS:-$artifacts}"
build=$(mktemp -d /private/tmp/syrup-model-comparison.XXXXXX)
trap 'rm -f "$build/harness"; rmdir "$build"' EXIT
case "$1" in
cerebras)
  xcrun swiftc -swift-version 6 -parse-as-library \
    "$artifacts/Support.swift" "$artifacts/CerebrasHarness.swift" \
    "$root/Sources/Translation/PromptBuilder.swift" "$root/Sources/Settings/Glossary.swift" \
    "$root/Sources/Translation/OpenAICompatibleTransformer.swift" "$root/Sources/Translation/OpenAISSEParser.swift" \
    "$root/Sources/Translation/ModelOutputNormalizer.swift" "$root/Sources/Translation/StreamingInactivityTracker.swift" \
    "$root/Sources/App/OperationTimeout.swift" -o "$build/harness"
  if [ -z "${CEREBRAS_API_KEY:-}" ]; then
    CEREBRAS_API_KEY=$(sed -n 's/^CEREBRAS_API_KEY=//p' "$root/.env" 2>/dev/null | tail -n 1)
  fi
  [ -n "$CEREBRAS_API_KEY" ] || { echo "Set CEREBRAS_API_KEY in $root/.env"; exit 2; }
  CEREBRAS_API_KEY="$CEREBRAS_API_KEY" "$build/harness" "$out" "$2" "${3:-3}" ;;
apple)
  xcrun swiftc -swift-version 6 -parse-as-library \
    "$artifacts/AppleSupport.swift" "$artifacts/AppleHarness.swift" \
    "$root/Sources/Translation/PromptBuilder.swift" "$root/Sources/Settings/Glossary.swift" \
    "$root/Sources/Translation/AppleOnDeviceTransformer.swift" "$root/Sources/Translation/CumulativeSnapshotDeltaAdapter.swift" \
    "$root/Sources/Translation/ModelOutputNormalizer.swift" "$root/Sources/Translation/StreamingInactivityTracker.swift" \
    -o "$build/harness" 2>&1 | grep -v "deprecated" || true
  "$build/harness" "$out" "${2:-3}" ;;
*) echo "usage: run.sh cerebras MODEL [REPEATS] | run.sh apple [REPEATS]"; exit 2 ;;
esac
