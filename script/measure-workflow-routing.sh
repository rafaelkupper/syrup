#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/syrup-routing.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
python3 - "$root" "$scratch" <<'PY'
import pathlib
import sys
root, scratch = map(pathlib.Path, sys.argv[1:])
source = (root / 'Sources/Settings/AppSettings.swift').read_text()
enum = source[source.index('enum TranslationProvider:'):source.index('@MainActor')]
(scratch / 'TranslationProvider.swift').write_text('import Foundation\n' + enum)
PY
swiftc -O -whole-module-optimization -o "$scratch/measure" \
    "$root/Sources/Settings/Workflow.swift" \
    "$root/Sources/Transcription/SpeechEngine.swift" \
    "$root/Sources/Settings/Glossary.swift" \
    "$root/Sources/Translation/PromptBuilder.swift" \
    "$root/Sources/History/DictationRecord.swift" \
    "$scratch/TranslationProvider.swift" \
    "$root/script/workflow-routing/main.swift"
/usr/bin/time -l "$scratch/measure"
