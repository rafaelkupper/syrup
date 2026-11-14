#!/bin/sh
# Runs the suite from a temporary copy under its own bundle ID, so test preference domains and
# build products never mix with the developer's installed Syrup. The app's entry point already
# starts an inert host under XCTest (see SyrupMain), so no production service runs either way.
#
# Each run gets a token, used in its bundle ID (org.syrup.SyrupIsolatedTests.<token>) and in every
# preference domain its tests create (testDomainName: org.syrup.tests.<token>.<name>.<UUID>). Only
# names under those two prefixes are ever deleted, so no other app's preferences can match. In the
# temporary folder it deletes only its own copies (syrup-tests.XXXXXX), the host's temporary folder
# (org.syrup.SyrupIsolatedTests.<token>), and the SwiftPM lock files named after a copy.
#
# Tests keep their preferences in memory (TestDefaults in TestSupport.swift), so they write no
# preference files. The one file a run writes is its host's own domain, where KeyboardShortcuts
# saves the default shortcuts. cfprefsd can save it up to about 10 seconds after the test process
# ends, so on exit this script deletes it if it is there, and the next run deletes it otherwise.
# A run that was killed leaves its files behind, so each run also cleans up after earlier runs that
# are over: every run leaves a marker in a fixed folder (whatever its TMPDIR) holding its script's
# PID and temporary copy, and a run counts as over once that PID no longer runs this script. A run
# paused in a debugger is still running, so it keeps its files.
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=${SYRUP_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/syrup-tests.XXXXXX")}
run_token=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
preferences="$HOME/Library/Preferences"
host_prefix=org.syrup.SyrupIsolatedTests
domain_prefix=org.syrup.tests
runs_dir="$HOME/Library/Caches/$domain_prefix/runs"

tmp_root=${TMPDIR:-/tmp}
tmp_root=${tmp_root%/}

# remove_run_temp <token> <temporary copy>: the host's temporary folder, and the lock file SwiftPM
# leaves beside it, named after the temporary copy.
remove_run_temp() {
    rm -rf "$tmp_root/$host_prefix.$1"
    case $2 in */syrup-tests.??????)
        find "$tmp_root" -maxdepth 1 -type f -name "*_$(basename "$2")_build_SourcePackages_Package.resolved.lock" -delete ;;
    esac
}

# remove_run_prefs <token>: one run's test preference files and its host's domain.
remove_run_prefs() {
    find "$preferences" -maxdepth 1 -type f \
        \( -name "$domain_prefix.$1.*.plist" -o -name "$host_prefix.$1.plist" \) -delete
}

# run_is_live <token>: the PID in the run's marker is still running this script.
run_is_live() {
    pid=$(sed -n 1p "$runs_dir/$1" 2>/dev/null) || return 1
    [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'test-isolated\.sh'
}

# Earlier runs that are over: their preference files, their temporary copy, and their marker. A
# plain `xcodebuild test` has no marker and uses the token "local"; its files go once an hour old.
remove_finished_runs() {
    for marker in "$runs_dir"/*; do
        [ -f "$marker" ] || continue
        token=$(basename "$marker")
        run_is_live "$token" && continue
        remove_run_prefs "$token"
        root=$(sed -n 2p "$marker")
        remove_run_temp "$token" "$root"
        case $root in */syrup-tests.??????) rm -rf "$root" ;; esac
        rm -f "$marker"
    done
    find "$preferences" -maxdepth 1 -type f -mmin +60 -name "$domain_prefix.local.*.plist" -delete
    # Left by runs from before markers covered them: host folders of runs no longer going, and
    # SwiftPM lock files whose temporary copy is gone.
    for folder in "$tmp_root/$host_prefix".*; do
        [ -d "$folder" ] || continue
        run_is_live "${folder##*.}" || rm -rf "$folder"
    done
    for lock in "$tmp_root"/*syrup-tests.??????_build_SourcePackages_Package.resolved.lock; do
        [ -f "$lock" ] || continue
        copy=$(printf '%s' "$lock" | sed -E 's/.*(syrup-tests\.[A-Za-z0-9]{6})_build_SourcePackages_Package\.resolved\.lock$/\1/')
        [ -d "$tmp_root/$copy" ] || rm -f "$lock"
    done
}

# The marker stays, so the next run checks once more.
finish_test_run() {
    remove_run_prefs "$run_token"
    if [ -z "${SYRUP_TEST_ROOT:-}" ]; then
        remove_run_temp "$run_token" "$test_root"
        rm -rf "$test_root"
    fi
}

mkdir -p "$runs_dir"
remove_finished_runs
owned_root=
if [ -z "${SYRUP_TEST_ROOT:-}" ]; then owned_root=$test_root; fi
printf '%s\n%s\n' "$$" "$owned_root" > "$runs_dir/$run_token"
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
