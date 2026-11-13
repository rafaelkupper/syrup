#!/bin/sh
# Hosted tests must not start production hotkeys, retention cleanup, or downloads.
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=${SYRUP_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/syrup-tests.XXXXXX")}
remove_test_prefs() {
    # Each test uses a UUID-named preference domain, and removing a domain leaves its file.
    # Only prefixes named by these tests are removed, because other tools use UUID domains too.
    # cfprefsd can write a file after its test exits, so the next run removes those stragglers.
    grep -rhoE '"[A-Za-z][A-Za-z0-9.-]*\.\\\(UUID' "$source_root/Tests" | sed -E 's/^"//; s/\.\\\(UUID$//' | sort -u |
        while IFS= read -r prefix; do
            find "$HOME/Library/Preferences" -maxdepth 1 -type f \
                -name "$prefix.????????-????-????-????-????????????.plist" -delete
        done
}
finish_test_run() {
    remove_test_prefs
    if [ -z "${SYRUP_TEST_ROOT:-}" ]; then rm -rf "$test_root"; fi
}
remove_test_prefs
trap finish_test_run EXIT
mkdir -p "$test_root"
test_root=$(CDPATH= cd -- "$test_root" && pwd)
if [ "$test_root" = "$source_root" ]; then
    echo "Test copy must be separate from the project checkout." >&2
    exit 1
fi
rsync -a --delete "$source_root/Sources/" "$test_root/Sources/"
rsync -a --delete "$source_root/Tests/" "$test_root/Tests/"
cp "$source_root/project.yml" "$source_root/Syrup.entitlements" "$test_root/"
cat > "$test_root/Sources/App/SyrupApp.swift" <<'SWIFT'
import SwiftUI
@main struct SyrupApp: App {
    var body: some Scene { Settings { EmptyView() } }
}
SWIFT
sed -i '' 's/org.syrup.SyrupApp/org.syrup.SyrupIsolatedTests/' "$test_root/project.yml"
cd "$test_root"
xcodegen
resolved_path=Syrup.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
if [ -f "$source_root/$resolved_path/Package.resolved" ]; then
    mkdir -p "$resolved_path"
    cp "$source_root/$resolved_path/Package.resolved" "$resolved_path/Package.resolved"
fi
xcodebuild -scheme Syrup -configuration Debug -destination 'platform=macOS' -derivedDataPath "$test_root/build" test "$@"
