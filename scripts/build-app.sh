#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DATE="$(/bin/date +%F)"
SIGNING_IDENTITY_NAME="会议录音 Local Signing 2026-08-18"
PRODUCTION_SIGNING_KEYCHAIN="/Users/alan/Library/Keychains/login.keychain-db"
PRODUCTION_RECEIPT_PATH="/Users/alan/Library/Application Support/MeetingRecorder/local-signing-receipt-v1"
TESTING_MODE="${MEETING_RECORDER_BUILD_TESTING:-}"
TEST_ROOT="${MEETING_RECORDER_BUILD_TEST_ROOT:-}"
TEST_BUILD_PATH="${MEETING_RECORDER_BUILD_PATH:-}"
TEST_APP_BUNDLE_PATH="${MEETING_RECORDER_APP_BUNDLE_PATH:-}"
TEST_SIGNING_MODE="${MEETING_RECORDER_BUILD_TEST_SIGNING_MODE:-}"
TEST_SIGNING_KEYCHAIN="${MEETING_RECORDER_BUILD_TEST_SIGNING_KEYCHAIN:-}"
TEST_SECURITY_TOOL="${MEETING_RECORDER_BUILD_TEST_SECURITY_TOOL:-}"
TEST_RECEIPT_PATH="${MEETING_RECORDER_BUILD_TEST_RECEIPT_PATH:-}"
TEST_VALIDATE_PRODUCTION_DIST="${MEETING_RECORDER_BUILD_TEST_VALIDATE_PRODUCTION_DIST:-}"
TEST_PROJECT_DIR="${MEETING_RECORDER_BUILD_TEST_PROJECT_DIR:-}"
CURRENT_UID="$(/usr/bin/id -u)" || exit 66

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

load_pinned_receipt() {
    local path="$1" key value mode owner links
    local version_seen=0 identity_seen=0 root_seen=0 leaf_seen=0
    PINNED_LEAF_SHA1=""
    [[ -f "$path" && ! -L "$path" ]] || {
        echo "build-app.sh: pinned signing receipt is missing or unsafe: $path" >&2
        echo "build-app.sh: run ./scripts/setup-local-signing.sh once, then retry" >&2
        return 66
    }
    mode="$(/usr/bin/stat -f '%Lp' "$path")" || return 66
    owner="$(/usr/bin/stat -f '%u' "$path")" || return 66
    links="$(/usr/bin/stat -f '%l' "$path")" || return 66
    if [[ "$mode" != "600" || "$owner" != "$CURRENT_UID" || "$links" != "1" ]]; then
        echo "build-app.sh: pinned signing receipt must be owned by the current user, mode 600, with one link" >&2
        return 66
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            version) (( version_seen += 1 )) ;;
            identity_name)
                (( identity_seen += 1 ))
                [[ "$value" == "$SIGNING_IDENTITY_NAME" ]] || {
                    echo "build-app.sh: pinned signing receipt names a different identity" >&2; return 66; }
                ;;
            root_sha1) (( root_seen += 1 )) ;;
            leaf_sha1)
                (( leaf_seen += 1 ))
                PINNED_LEAF_SHA1="$(printf '%s' "$value" | /usr/bin/tr '[:lower:]' '[:upper:]')"
                ;;
            *)
                echo "build-app.sh: pinned signing receipt contains an unexpected field" >&2
                return 66
                ;;
        esac
    done < "$path"
    if (( version_seen != 1 || identity_seen != 1 || root_seen != 1 || leaf_seen != 1 )) ||
       [[ ! "$PINNED_LEAF_SHA1" =~ ^[0-9A-F]{40}$ ]]; then
        echo "build-app.sh: pinned signing receipt is malformed" >&2
        return 66
    fi
}

verify_pinned_fingerprint() {
    [[ "$SIGNING_SELECTOR" == "$PINNED_LEAF_SHA1" ]] || {
        echo "build-app.sh: signing identity fingerprint does not match the pinned receipt" >&2
        exit 66
    }
}

validate_production_dist() {
    local canonical_project="$1" dist
    dist="$canonical_project/dist"
    if [[ -e "$dist" || -L "$dist" ]]; then
        if [[ ! -d "$dist" || -L "$dist" ]]; then
            echo "build-app.sh: dist must be a real non-symlink project directory: $dist" >&2
            exit 64
        fi
        if [[ "$(canonical_directory "$dist")" != "$dist" ]]; then
            echo "build-app.sh: dist canonical path must stay inside the project directory: $dist" >&2
            exit 64
        fi
    fi
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

    if [[ "$TEST_VALIDATE_PRODUCTION_DIST" == "1" ]]; then
        [[ -n "$TEST_PROJECT_DIR" ]] \
            || fail_test_override "production dist validation requires a project directory"
        [[ -d "$TEST_PROJECT_DIR" && ! -L "$TEST_PROJECT_DIR" ]] \
            || fail_test_override "production layout project must be an existing non-symlink directory"
        CANONICAL_LAYOUT_PROJECT="$(canonical_directory "$TEST_PROJECT_DIR")" \
            || fail_test_override "production layout project could not be resolved"
        case "$CANONICAL_LAYOUT_PROJECT" in
            "$CANONICAL_TEST_ROOT"|"$CANONICAL_TEST_ROOT"/*) ;;
            *) fail_test_override "production layout project must stay inside the testing root" ;;
        esac
        validate_production_dist "$CANONICAL_LAYOUT_PROJECT"
        exit 0
    fi
    [[ -z "$TEST_PROJECT_DIR" ]] \
        || fail_test_override "production layout project override requires MEETING_RECORDER_BUILD_TEST_VALIDATE_PRODUCTION_DIST=1"

    case "$TEST_SIGNING_MODE" in
        adhoc)
            [[ -z "$TEST_SIGNING_KEYCHAIN" && -z "$TEST_SECURITY_TOOL" && -z "$TEST_RECEIPT_PATH" ]] \
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

            [[ -n "$TEST_RECEIPT_PATH" ]] \
                || fail_test_override "identity testing requires the pinned signing receipt"
            [[ -f "$TEST_RECEIPT_PATH" && ! -L "$TEST_RECEIPT_PATH" ]] \
                || fail_test_override "testing receipt must be an existing non-symlink file"
            SIGNING_RECEIPT_PATH="$(canonical_file "$TEST_RECEIPT_PATH")" \
                || fail_test_override "testing receipt could not be resolved"
            case "$SIGNING_RECEIPT_PATH" in
                "$CANONICAL_TEST_ROOT"/*) ;;
                *) fail_test_override "testing receipt must stay inside the testing root" ;;
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
            load_pinned_receipt "$SIGNING_RECEIPT_PATH" \
                || { echo "build-app.sh: testing receipt rejected" >&2; exit 66; }
            resolve_exact_signing_identity
            verify_pinned_fingerprint
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
        -n "$TEST_SIGNING_KEYCHAIN" || -n "$TEST_SECURITY_TOOL" || \
        -n "$TEST_RECEIPT_PATH" || -n "$TEST_VALIDATE_PRODUCTION_DIST" || \
        -n "$TEST_PROJECT_DIR" ]]; then
    fail_test_override "test-only output overrides require MEETING_RECORDER_BUILD_TESTING=1"
else
    CANONICAL_PROJECT_DIR="$(canonical_directory "$PROJECT_DIR")" \
        || { echo "build-app.sh: project directory could not be resolved" >&2; exit 66; }
    validate_production_dist "$CANONICAL_PROJECT_DIR"
    BUILD_PATH="$PROJECT_DIR/.build"
    APP_BUNDLE="$CANONICAL_PROJECT_DIR/dist/会议录音-${BUILD_DATE}.app"
    SIGNING_KEYCHAIN="$PRODUCTION_SIGNING_KEYCHAIN"
    SECURITY_TOOL="/usr/bin/security"
    load_pinned_receipt "$PRODUCTION_RECEIPT_PATH" || exit $?
    resolve_exact_signing_identity
    verify_pinned_fingerprint
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
