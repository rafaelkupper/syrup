#!/bin/sh
# Folder boundaries are conventions inside one target, so this check keeps them from eroding:
# engine SDKs stay behind their seams, model code never imports UI frameworks, Core uses no type
# from another folder, and only App/ composition code sees App/ types.
# It is grep-based: comments and string literals are stripped first, so it can still miss a
# reference built some other way. SYRUP_BOUNDARY_ROOT points it at another tree for its own tests.
set -eu
cd "${SYRUP_BOUNDARY_ROOT:-$(dirname "$0")/..}"
status=0

# Any import form: plain, `@_exported`, `@testable`, and `import struct/class/enum/func/... Module.Symbol`.
import_pattern() {
    printf '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|typealias|func|var|let)[[:space:]]+)?%s([.[:space:]]|$)' "$1"
}

# only_in <module> <allowed path pattern...>: fail if <module> is imported anywhere else.
only_in() {
    module=$1
    shift
    found=$(grep -rlE "$(import_pattern "$module")" Sources --include='*.swift' || true)
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
        found=$(grep -rlE "$(import_pattern "$module")" "$prefix" --include='*.swift' || true)
        for file in $found; do
            echo "boundary: $file must not import $module" >&2
            status=1
        done
    done
}

# Swift source with line comments, block comments on one line, and string literals removed.
code_only() {
    sed -E -e 's#//.*$##' -e 's#/\*.*\*/##g' -e 's/"([^"\\]|\\.)*"//g' "$1"
}

# Top-level type and free-function names declared under a folder.
declared_names() {
    grep -rhE '^(public |internal |private |fileprivate |nonisolated |final |@MainActor )*(enum|struct|class|actor|protocol|typealias|func) [A-Za-z_][A-Za-z0-9_]*' "$1" --include='*.swift' |
        sed -E 's/^.*(enum|struct|class|actor|protocol|typealias|func) ([A-Za-z_][A-Za-z0-9_]*).*/\2/' | sort -u
}

# no_names_from <consumer folder> <provider folder> [allowed name...]: fail if a file in the consumer
# folder names a type or free function declared in the provider folder.
no_names_from() {
    consumer=$1
    provider=$2
    shift 2
    names=$(declared_names "$provider")
    for allowed in "$@"; do
        names=$(printf '%s\n' "$names" | grep -vx "$allowed" || true)
    done
    pattern=$(printf '%s\n' "$names" | grep . | paste -sd'|' - || true)
    [ -n "$pattern" ] || return 0
    for file in $(find "$consumer" -name '*.swift' | sort); do
        hits=$(code_only "$file" | grep -owE "$pattern" | sort -u | paste -sd' ' - || true)
        if [ -n "$hits" ]; then
            echo "boundary: $file uses $hits from $provider" >&2
            status=1
        fi
    done
}

only_in FluidAudio 'Sources/Transcription/*'
only_in WhisperKit 'Sources/Learning/*'
only_in Sparkle 'Sources/App/UpdateController.swift'
only_in FoundationModels 'Sources/Translation/AppleOnDeviceTransformer.swift'
only_in KeyboardShortcuts 'Sources/Hotkey/*' 'Sources/Settings/*' 'Sources/Onboarding/*' 'Sources/App/MenuBarView.swift'
only_in Speech 'Sources/Transcription/*' 'Sources/Learning/SystemMishearingSpeech.swift' \
    'Sources/Settings/PermissionStatusModel.swift'
only_in AVFoundation 'Sources/Audio/*' 'Sources/Transcription/*' 'Sources/App/AppState+VoiceRun.swift' \
    'Sources/App/PauseTransformation.swift' 'Sources/RecordingCue/AudioLevelMeter.swift' \
    'Sources/Learning/MishearingProbe.swift' 'Sources/Learning/RecordingTee.swift' \
    'Sources/Learning/SystemMishearingSpeech.swift' 'Sources/Settings/PermissionStatusModel.swift' \
    'Sources/Settings/PrivacySettingsPane.swift'
never_in Sources/Core SwiftUI AppKit
never_in Sources/Translation SwiftUI AppKit
never_in Sources/Transcription SwiftUI AppKit

# Core is the bottom layer: its domain types use nothing declared in another folder.
for folder in Sources/*/; do
    folder=${folder%/}
    case $folder in Sources/Core | Sources/Assets.xcassets) continue ;; esac
    no_names_from Sources/Core "$folder"
done

# App/ is the composition root. Only UI and the hotkey bridge may reach into it, and only for the
# app state, update controller, and user-facing error text they present.
for folder in Sources/*/; do
    folder=${folder%/}
    case $folder in
        Sources/App | Sources/Assets.xcassets) continue ;;
        Sources/Settings | Sources/Onboarding | Sources/Hotkey)
            no_names_from "$folder" Sources/App AppState UpdateController userMessage ;;
        *) no_names_from "$folder" Sources/App ;;
    esac
done

# Every RunConfiguration is assembled by RunConfigurationBuilder.
for file in $(grep -rlw 'RunConfiguration(' Sources --include='*.swift' || true); do
    case $file in Sources/Translation/RunConfigurationBuilder.swift) ;; *)
        echo "boundary: $file builds a RunConfiguration outside RunConfigurationBuilder" >&2
        status=1 ;;
    esac
done

exit $status
