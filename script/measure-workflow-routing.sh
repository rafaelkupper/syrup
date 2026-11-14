#!/bin/sh
# Times WorkflowList.routedWorkflowID. Core depends on no other folder, so it compiles on its own.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/syrup-routing.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
swiftc -O -whole-module-optimization -o "$scratch/measure" \
    "$root"/Sources/Core/*.swift \
    "$root/script/workflow-routing/main.swift"
/usr/bin/time -l "$scratch/measure"
