#!/bin/sh
# Folder boundaries are conventions inside one target, so this check keeps them from eroding:
# engine SDKs stay behind their seams, and model code never imports UI frameworks.
set -eu
cd "$(dirname "$0")/.."
status=0

# only_in <module> <allowed path pattern...>: fail if <module> is imported anywhere else.
only_in() {
    module=$1
    shift
    found=$(grep -rl "^import $module\$" Sources --include='*.swift' || true)
    for file in $found; do
        allowed=false
        for pattern in "$@"; do
            case $file in $pattern) allowed=true ;; esac
        done
        if [ "$allowed" = false ]; then
            echo "boundary: $file imports $module" >&2
            status=1
        fi
    done
}

# never_in <path prefix> <module...>: fail if a file under the prefix imports any listed module.
never_in() {
    prefix=$1
    shift
    for module in "$@"; do
        found=$(grep -rl "^import $module\$" "$prefix" --include='*.swift' || true)
        for file in $found; do
            echo "boundary: $file must not import $module" >&2
            status=1
        done
    done
}

only_in FluidAudio 'Sources/Transcription/*'
only_in WhisperKit 'Sources/Learning/*'
only_in Sparkle 'Sources/App/UpdateController.swift'
only_in FoundationModels 'Sources/Translation/AppleOnDeviceTransformer.swift'
only_in KeyboardShortcuts 'Sources/Hotkey/*' 'Sources/Settings/*' 'Sources/Onboarding/*' 'Sources/App/MenuBarView.swift'
never_in Sources/Core SwiftUI AppKit
never_in Sources/Translation SwiftUI AppKit
never_in Sources/Transcription SwiftUI AppKit

exit $status
