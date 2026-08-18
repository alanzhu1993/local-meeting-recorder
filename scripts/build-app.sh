#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DATE="$(/bin/date +%F)"
SIGNING_IDENTITY_NAME="会议录音 Local Signing 2026-08-18"
PRODUCTION_SIGNING_KEYCHAIN="/Users/alan/Library/Keychains/login.keychain-db"
TESTING_MODE="${MEETING_RECORDER_BUILD_TESTING:-}"
TEST_ROOT="${MEETING_RECORDER_BUILD_TEST_ROOT:-}"
TEST_BUILD_PATH="${MEETING_RECORDER_BUILD_PATH:-}"
TEST_APP_BUNDLE_PATH="${MEETING_RECORDER_APP_BUNDLE_PATH:-}"
TEST_SIGNING_MODE="${MEETING_RECORDER_BUILD_TEST_SIGNING_MODE:-}"
TEST_SIGNING_KEYCHAIN="${MEETING_RECORDER_BUILD_TEST_SIGNING_KEYCHAIN:-}"
TEST_SECURITY_TOOL="${MEETING_RECORDER_BUILD_TEST_SECURITY_TOOL:-}"

fail_test_override() {
    echo "build-app.sh: $1" >&2
    exit 64
}

canonical_directory() {
    (cd -P "$1" && pwd -P)
}

canonical_file() {
    local parent
    parent="$(canonical_directory "$(dirname "$1")")" || return 1
    printf '%s/%s\n' "$parent" "$(basename "$1")"
}

resolve_exact_signing_identity() {
    local output
    local hashes_text
    local hash
    local hashes=()
    if ! output="$(LC_ALL=en_US.UTF-8 "$SECURITY_TOOL" find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>&1)"; then
        echo "build-app.sh: could not inspect code-signing identities in $SIGNING_KEYCHAIN" >&2
        exit 66
    fi
    hashes_text="$(printf '%s\n' "$output" | /usr/bin/awk -F'"' -v expected="$SIGNING_IDENTITY_NAME" '
        $2 == expected {
            count = split($1, fields, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                hash = toupper(fields[i])
                if (hash ~ /^[0-9A-F]+$/ && length(hash) == 40 && !seen[hash]++) {
                    print hash
                }
            }
        }
    ')"
    while IFS= read -r hash; do
        if [[ -n "$hash" ]]; then
            hashes+=("$hash")
        fi
    done <<< "$hashes_text"
    if (( ${#hashes[@]} == 0 )); then
        echo "build-app.sh: signing identity '$SIGNING_IDENTITY_NAME' not found in $SIGNING_KEYCHAIN" >&2
        echo "build-app.sh: run ./scripts/setup-local-signing.sh once, then retry" >&2
        exit 66
    fi
    if (( ${#hashes[@]} > 1 )); then
        echo "build-app.sh: multiple exact signing identities named '$SIGNING_IDENTITY_NAME' found in $SIGNING_KEYCHAIN" >&2
        exit 65
    fi
    SIGNING_SELECTOR="${hashes[0]}"
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
    [[ "$APP_BUNDLE" != "$APP_PARENT/." && "$APP_BUNDLE" != "$APP_PARENT/.." \
        && "$(basename "$APP_BUNDLE")" == *.app ]] \
        || fail_test_override "app bundle path must name an .app bundle"

    case "$TEST_SIGNING_MODE" in
        adhoc)
            [[ -z "$TEST_SIGNING_KEYCHAIN" && -z "$TEST_SECURITY_TOOL" ]] \
                || fail_test_override "ad-hoc testing must not provide identity overrides"
            SIGNING_SELECTOR="-"
            ;;
        identity)
            [[ -n "$TEST_SIGNING_KEYCHAIN" ]] \
                || fail_test_override "identity testing requires a temporary keychain"
            [[ -f "$TEST_SIGNING_KEYCHAIN" && ! -L "$TEST_SIGNING_KEYCHAIN" ]] \
                || fail_test_override "testing keychain must be an existing non-symlink file"
            SIGNING_KEYCHAIN="$(canonical_file "$TEST_SIGNING_KEYCHAIN")" \
                || fail_test_override "testing keychain could not be resolved"
            case "$SIGNING_KEYCHAIN" in
                "$CANONICAL_TEST_ROOT"/*) ;;
                *) fail_test_override "testing keychain must stay inside the testing root" ;;
            esac

            if [[ -n "$TEST_SECURITY_TOOL" ]]; then
                [[ -f "$TEST_SECURITY_TOOL" && -x "$TEST_SECURITY_TOOL" && ! -L "$TEST_SECURITY_TOOL" ]] \
                    || fail_test_override "testing security tool must be an executable non-symlink file"
                SECURITY_TOOL="$(canonical_file "$TEST_SECURITY_TOOL")" \
                    || fail_test_override "testing security tool could not be resolved"
                case "$SECURITY_TOOL" in
                    "$CANONICAL_TEST_ROOT"/*) ;;
                    *) fail_test_override "testing security tool must stay inside the testing root" ;;
                esac
            else
                SECURITY_TOOL="/usr/bin/security"
            fi
            resolve_exact_signing_identity
            ;;
        "")
            fail_test_override "testing mode requires an explicit signing mode: adhoc or identity"
            ;;
        *)
            fail_test_override "unsupported testing signing mode: $TEST_SIGNING_MODE"
            ;;
    esac
    SWIFT_BUILD_ARGUMENTS=(build -c release --product MeetingRecorderApp --scratch-path "$BUILD_PATH")
    SWIFT_BIN_PATH_ARGUMENTS=(build -c release --show-bin-path --scratch-path "$BUILD_PATH")
elif [[ -n "$TESTING_MODE" || -n "$TEST_ROOT" || -n "$TEST_BUILD_PATH" || \
        -n "$TEST_APP_BUNDLE_PATH" || -n "$TEST_SIGNING_MODE" || \
        -n "$TEST_SIGNING_KEYCHAIN" || -n "$TEST_SECURITY_TOOL" ]]; then
    fail_test_override "test-only output overrides require MEETING_RECORDER_BUILD_TESTING=1"
else
    BUILD_PATH="$PROJECT_DIR/.build"
    APP_BUNDLE="$PROJECT_DIR/dist/会议录音-${BUILD_DATE}.app"
    SIGNING_KEYCHAIN="$PRODUCTION_SIGNING_KEYCHAIN"
    SECURITY_TOOL="/usr/bin/security"
    resolve_exact_signing_identity
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

if [[ "$SIGNING_SELECTOR" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
else
    /usr/bin/codesign --force --deep --keychain "$SIGNING_KEYCHAIN" \
        --sign "$SIGNING_SELECTOR" "$APP_BUNDLE"
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
