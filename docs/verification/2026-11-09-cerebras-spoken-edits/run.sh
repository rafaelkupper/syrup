#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
artifacts="$root/docs/verification/2026-11-09-cerebras-spoken-edits"
build=$(mktemp -d /private/tmp/syrup-cerebras-build.XXXXXX)
trap 'rm -f "$build/harness"; rmdir "$build"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
 "$artifacts/Support.swift" "$artifacts/Harness.swift" \
 "$root/Sources/Translation/PromptBuilder.swift" "$root/Sources/Settings/Glossary.swift" \
 "$root/Sources/Translation/OpenAICompatibleTransformer.swift" "$root/Sources/Translation/OpenAISSEParser.swift" \
 "$root/Sources/Translation/ModelOutputNormalizer.swift" "$root/Sources/Translation/StreamingInactivityTracker.swift" \
 "$root/Sources/App/OperationTimeout.swift" -o "$build/harness"
"$build/harness" "$1" "$artifacts" "${2:-baseline}"
