#!/bin/sh
# Runs the suite from a temporary copy under its own bundle ID, so test preference domains and
# build products never mix with the developer's installed Syrup. The app's entry point already
# starts an inert host under XCTest (see SyrupMain), so no production service runs either way.
#
# Each run gets a token, used in its bundle ID (org.syrup.SyrupIsolatedTests.<token>) and in every
# preference domain its tests create (testDomainName: <prefix>.<token>.<UUID>). Cleanup removes only
# this run's files and those of earlier runs whose script has exited, so concurrent runs never delete
# each other's preferences.
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=${SYRUP_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/syrup-tests.XXXXXX")}
runs_dir="${TMPDIR:-/tmp}/syrup-test-runs"
run_token=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
preferences="$HOME/Library/Preferences"
uuid_glob='????????-????-????-????-????????????'

# Preference prefixes the tests name through testDomainName("<prefix>").
test_prefixes() {
    grep -rhoE 'testDomainName\("[A-Za-z][A-Za-z0-9.-]*"\)' "$source_root/Tests" |
        sed -E 's/^testDomainName\("//; s/"\)$//' | sort -u
}

# remove_run_prefs <token>: removes one run's preference files. Removing a domain leaves its file,
# and cfprefsd can write one after its test exits, so a later run removes those stragglers too.
remove_run_prefs() {
    for prefix in $(test_prefixes); do
        find "$preferences" -maxdepth 1 -type f -name "$prefix.$1.$uuid_glob.plist" -delete
    done
}

# Earlier runs leave a marker holding their script's PID. Once that process is gone, nothing can
# be using their files. Files from before run tokens existed are removed once they are 10 minutes old.
remove_finished_runs() {
    for marker in "$runs_dir"/*; do
        [ -f "$marker" ] || continue
        if ! kill -0 "$(cat "$marker")" 2>/dev/null; then
            remove_run_prefs "$(basename "$marker")"
            rm -f "$marker"
        fi
    done
    for prefix in $(test_prefixes); do
        find "$preferences" -maxdepth 1 -type f -mmin +10 -name "$prefix.$uuid_glob.plist" -delete
    done
}

finish_test_run() {
    remove_run_prefs "$run_token"
    if [ -z "${SYRUP_TEST_ROOT:-}" ]; then rm -rf "$test_root"; fi
}

mkdir -p "$runs_dir"
remove_finished_runs
echo $$ > "$runs_dir/$run_token"
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
sed -i '' "s/org\.syrup\.SyrupApp/org.syrup.SyrupIsolatedTests.$run_token/" "$test_root/project.yml"
cd "$test_root"
xcodegen
resolved_path=Syrup.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
if [ -f "$source_root/$resolved_path/Package.resolved" ]; then
    mkdir -p "$resolved_path"
    cp "$source_root/$resolved_path/Package.resolved" "$resolved_path/Package.resolved"
fi
xcodebuild -scheme Syrup -configuration Debug -destination 'platform=macOS' -derivedDataPath "$test_root/build" test "$@"
