#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DATE="$(/bin/date +%F)"
TESTING_MODE="${MEETING_RECORDER_BUILD_TESTING:-}"
TEST_ROOT="${MEETING_RECORDER_BUILD_TEST_ROOT:-}"
TEST_BUILD_PATH="${MEETING_RECORDER_BUILD_PATH:-}"
TEST_APP_BUNDLE_PATH="${MEETING_RECORDER_APP_BUNDLE_PATH:-}"

fail_test_override() {
    echo "build-app.sh: $1" >&2
    exit 64
}

canonical_directory() {
    (cd -P "$1" && pwd -P)
}

if [[ "$TESTING_MODE" == "1" ]]; then
    [[ -n "$TEST_ROOT" && -n "$TEST_BUILD_PATH" && -n "$TEST_APP_BUNDLE_PATH" ]] \
        || fail_test_override "testing mode requires root, scratch path, and app bundle path"
    [[ -d "$TEST_ROOT" && ! -L "$TEST_ROOT" && -d "$TEST_BUILD_PATH" && ! -L "$TEST_BUILD_PATH" ]] \
        || fail_test_override "testing root and scratch path must be existing directories"

    CANONICAL_TMPDIR="$(canonical_directory "${TMPDIR:?TMPDIR is required for testing mode}")" \
        || fail_test_override "TMPDIR must be an existing directory"
    CANONICAL_TEST_ROOT="$(canonical_directory "$TEST_ROOT")" \
        || fail_test_override "testing root must be an existing directory"
    [[ "$(dirname "$CANONICAL_TEST_ROOT")" == "$CANONICAL_TMPDIR" ]] \
        && [[ "$(basename "$CANONICAL_TEST_ROOT")" == meeting-recorder-build-test.* ]] \
        || fail_test_override "testing root must be a direct meeting-recorder-build-test.* child of TMPDIR"

    BUILD_PATH="$(canonical_directory "$TEST_BUILD_PATH")" \
        || fail_test_override "scratch path must be an existing directory"
    case "$BUILD_PATH" in
        "$CANONICAL_TEST_ROOT"/*) ;;
        *) fail_test_override "scratch path must stay inside the testing root" ;;
    esac

    APP_PARENT="$(canonical_directory "$(dirname "$TEST_APP_BUNDLE_PATH")")" \
        || fail_test_override "app bundle parent must be an existing directory"
    case "$APP_PARENT" in
        "$CANONICAL_TEST_ROOT"|"$CANONICAL_TEST_ROOT"/*) ;;
        *) fail_test_override "app bundle path must stay inside the testing root" ;;
    esac
    APP_BUNDLE="$APP_PARENT/$(basename "$TEST_APP_BUNDLE_PATH")"
    [[ "$APP_BUNDLE" != "$APP_PARENT/." && "$APP_BUNDLE" != "$APP_PARENT/.." ]] \
        || fail_test_override "app bundle path must name a bundle"
    SWIFT_BUILD_ARGUMENTS=(build -c release --product MeetingRecorderApp --scratch-path "$BUILD_PATH")
    SWIFT_BIN_PATH_ARGUMENTS=(build -c release --show-bin-path --scratch-path "$BUILD_PATH")
elif [[ -n "$TESTING_MODE" || -n "$TEST_ROOT" || -n "$TEST_BUILD_PATH" || -n "$TEST_APP_BUNDLE_PATH" ]]; then
    fail_test_override "test-only output overrides require MEETING_RECORDER_BUILD_TESTING=1"
else
    BUILD_PATH="$PROJECT_DIR/.build"
    APP_BUNDLE="$PROJECT_DIR/dist/会议录音-${BUILD_DATE}.app"
    SWIFT_BUILD_ARGUMENTS=(build -c release --product MeetingRecorderApp)
    SWIFT_BIN_PATH_ARGUMENTS=(build -c release --show-bin-path)
fi

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift "${SWIFT_BUILD_ARGUMENTS[@]}"
BUILD_PRODUCTS_DIR="$(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift "${SWIFT_BIN_PATH_ARGUMENTS[@]}")"

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/bin/cp "$BUILD_PRODUCTS_DIR/MeetingRecorderApp" "$APP_BUNDLE/Contents/MacOS/MeetingRecorderApp"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/AppIcon-2026-08-18.icns" "$APP_BUNDLE/Contents/Resources/AppIcon-2026-08-18.icns"

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
