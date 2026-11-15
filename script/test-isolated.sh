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

# physical_name <folder>: the folder's physical path with slashes made underscores, as SwiftPM names
# its lock files. The folder itself may be gone; its parent must exist.
physical_name() {
    parent=$(CDPATH= cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s' "$parent" "$(basename -- "$1")" | tr '/' '_'
}

# remove_run_temp <token> <temporary copy>: the host's temporary folder, and the lock files SwiftPM
# leaves beside it, named after the temporary copy's full path (Package.resolved, workspace state,
# and one per binary artifact), so a copy elsewhere with the same name keeps its own. Under a
# symlinked folder, such as /tmp, SwiftPM names some locks by the path as given and some by the
# physical one, so both are matched.
remove_run_temp() {
    rm -rf "$tmp_root/$host_prefix.$1"
    case $2 in */syrup-tests.??????)
        logical=$(printf '%s' "$2" | tr -s '/' | tr '/' '_')
        physical=$(physical_name "$2") || physical=$logical
        # Compared literally: a path may hold characters find -name would read as a pattern.
        for lock in "$tmp_root"/*_build_SourcePackages_*.lock; do
            [ -f "$lock" ] || continue
            case ${lock##*/} in
                "${physical}_build_SourcePackages_"*|"${logical}_build_SourcePackages_"*) rm -f "$lock" ;;
            esac
        done ;;
    esac
}

# live_copy <folder name>: a live run's marker names a copy with this name.
live_copy() {
    for marker in "$runs_dir"/*; do
        [ -f "$marker" ] || continue
        [ "$(basename -- "$(sed -n 2p "$marker" 2>/dev/null)")" = "$1" ] && run_is_live "$(basename "$marker")" && return 0
    done
    return 1
}

# remove_run_prefs <token>: one run's test preference files and its host's domain.
remove_run_prefs() {
    find "$preferences" -maxdepth 1 -type f \
        \( -name "$domain_prefix.$1.*.plist" -o -name "$host_prefix.$1.plist" \) -delete 2>/dev/null || :
}

# run_is_live <token>: the PID in the run's marker is still running this script.
run_is_live() {
    pid=$(sed -n 1p "$runs_dir/$1" 2>/dev/null) || return 1
    [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'test-isolated\.sh'
}

# Earlier runs that are over: their preference files, their temporary copy, and their marker. A
# plain `xcodebuild test` has no marker and uses the token "local"; its files go once an hour old.
# Two runs starting together clean up the same earlier runs, so a file the other one removed first
# is not an error: each step tolerates it rather than stop this run under `set -e`.
remove_finished_runs() {
    for marker in "$runs_dir"/*; do
        [ -f "$marker" ] || continue
        token=$(basename "$marker")
        run_is_live "$token" && continue
        remove_run_prefs "$token"
        root=$(sed -n 2p "$marker" 2>/dev/null) || continue
        remove_run_temp "$token" "$root"
        case $root in */syrup-tests.??????) rm -rf "$root" ;; esac
        rm -f "$marker"
    done
    find "$preferences" -maxdepth 1 -type f -mmin +60 -name "$domain_prefix.local.*.plist" -delete 2>/dev/null || :
    # A host domain cfprefsd saved after the next run had already removed its run's marker, as
    # back-to-back runs do: gone once ten minutes old, far past cfprefsd's delay, unless its run is live.
    for plist in "$preferences/$host_prefix".*.plist; do
        [ -f "$plist" ] || continue
        token=${plist##*/"$host_prefix".}
        token=${token%.plist}
        run_is_live "$token" || find "$plist" -mmin +10 -delete 2>/dev/null || :
    done
    # A copy left empty by a run that stopped before writing its marker. A live run fills its copy
    # within seconds of making it, so one still empty after ten minutes is abandoned, unless a live
    # run's marker names it, as for a run paused in a debugger.
    for copy in "$tmp_root"/syrup-tests.??????; do
        [ -d "$copy" ] || continue
        [ -n "$(find "$copy" -maxdepth 0 -empty -mmin +10 2>/dev/null)" ] || continue
        live_copy "$(basename -- "$copy")" || rmdir "$copy" 2>/dev/null || :
    done
    # Left by runs from before markers covered them: host folders of runs no longer going, and
    # SwiftPM lock files whose temporary copy is gone.
    for folder in "$tmp_root/$host_prefix".*; do
        [ -d "$folder" ] || continue
        run_is_live "${folder##*.}" || rm -rf "$folder"
    done
    # SwiftPM names a lock after the build folder's path, slashes made underscores: the physical
    # path, or under a symlinked folder such as /tmp sometimes the path as given. Only locks of
    # copies directly in this temporary folder are checked here; a copy elsewhere, given as
    # SYRUP_TEST_ROOT, may still be running, and its locks are not this check's to judge.
    physical_tmp=$(CDPATH= cd -- "$tmp_root" && pwd -P | tr '/' '_')
    logical_tmp=$(printf '%s' "$tmp_root" | tr -s '/' | tr '/' '_')
    for prefix in "$physical_tmp" "$logical_tmp"; do
        for lock in "$tmp_root/${prefix}_syrup-tests."??????"_build_SourcePackages_"*.lock; do
            [ -f "$lock" ] || continue
            copy=$(printf '%s' "${lock#"$tmp_root/${prefix}_"}" | cut -c1-18)
            [ -d "$tmp_root/$copy" ] || rm -f "$lock"
        done
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
