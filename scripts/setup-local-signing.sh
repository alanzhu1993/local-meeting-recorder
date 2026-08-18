#!/bin/bash
set -euo pipefail

umask 077

IDENTITY_NAME="会议录音 Local Signing 2026-08-18"
PRODUCTION_KEYCHAIN="/Users/alan/Library/Keychains/login.keychain-db"
TESTING_MODE="${MEETING_RECORDER_SIGNING_SETUP_TESTING:-0}"
TEST_ROOT="${MEETING_RECORDER_SIGNING_TEST_ROOT:-}"
TEST_KEYCHAIN="${MEETING_RECORDER_SIGNING_TEST_KEYCHAIN:-}"
TEST_SECURITY_TOOL="${MEETING_RECORDER_SIGNING_TEST_SECURITY_TOOL:-}"

fail_usage() {
    echo "setup-local-signing.sh: $1" >&2
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

case "$TESTING_MODE" in
    1)
        [[ -n "$TEST_ROOT" && -n "$TEST_KEYCHAIN" && -n "$TEST_SECURITY_TOOL" ]] \
            || fail_usage "testing mode requires a root, keychain, and security tool"
        [[ -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]] \
            || fail_usage "testing root must be an existing non-symlink directory"
        CANONICAL_TEST_ROOT="$(canonical_directory "$TEST_ROOT")" \
            || fail_usage "testing root could not be resolved"
        CANONICAL_TMPDIR="$(canonical_directory "${TMPDIR:?TMPDIR is required in testing mode}")" \
            || fail_usage "TMPDIR must be an existing directory"
        [[ "$CANONICAL_TEST_ROOT" == "$CANONICAL_TMPDIR" ]] \
            || fail_usage "testing root must be the isolated TMPDIR"
        [[ "$(basename "$CANONICAL_TEST_ROOT")" == meeting-recorder-signing-test.* ]] \
            || fail_usage "testing root must use the meeting-recorder-signing-test.* prefix"

        [[ -f "$TEST_KEYCHAIN" && ! -L "$TEST_KEYCHAIN" ]] \
            || fail_usage "testing keychain must be an existing non-symlink file"
        KEYCHAIN="$(canonical_file "$TEST_KEYCHAIN")" \
            || fail_usage "testing keychain could not be resolved"
        case "$KEYCHAIN" in
            "$CANONICAL_TEST_ROOT"/*) ;;
            *) fail_usage "testing keychain must stay inside the testing root" ;;
        esac

        [[ -f "$TEST_SECURITY_TOOL" && -x "$TEST_SECURITY_TOOL" && ! -L "$TEST_SECURITY_TOOL" ]] \
            || fail_usage "testing security tool must be an existing executable non-symlink file"
        SECURITY_TOOL="$(canonical_file "$TEST_SECURITY_TOOL")" \
            || fail_usage "testing security tool could not be resolved"
        case "$SECURITY_TOOL" in
            "$CANONICAL_TEST_ROOT"/*) ;;
            *) fail_usage "testing security tool must stay inside the testing root" ;;
        esac
        ;;
    0)
        if [[ -n "$TEST_ROOT" || -n "$TEST_KEYCHAIN" || -n "$TEST_SECURITY_TOOL" ]]; then
            fail_usage "test-only overrides require MEETING_RECORDER_SIGNING_SETUP_TESTING=1"
        fi
        KEYCHAIN="$PRODUCTION_KEYCHAIN"
        SECURITY_TOOL="/usr/bin/security"
        ;;
    *)
        fail_usage "MEETING_RECORDER_SIGNING_SETUP_TESTING must be 0 or 1"
        ;;
esac

[[ -f "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] || {
    echo "setup-local-signing.sh: keychain does not exist: $KEYCHAIN" >&2
    exit 66
}

identity_hashes() {
    local valid_only="$1"
    local output
    local arguments=(find-identity -p codesigning)
    if [[ "$valid_only" == "1" ]]; then
        arguments+=( -v )
    fi
    arguments+=( "$KEYCHAIN" )
    if ! output="$(LC_ALL=en_US.UTF-8 "$SECURITY_TOOL" "${arguments[@]}" 2>&1)"; then
        echo "setup-local-signing.sh: could not inspect signing identities" >&2
        return 66
    fi
    printf '%s\n' "$output" | /usr/bin/awk -F'"' -v expected="$IDENTITY_NAME" '
        $2 == expected {
            count = split($1, fields, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                hash = toupper(fields[i])
                if (hash ~ /^[0-9A-F]+$/ && length(hash) == 40 && !seen[hash]++) {
                    print hash
                }
            }
        }
    '
}

read_identity_hashes() {
    local valid_only="$1"
    local hashes_text
    hashes_text="$(identity_hashes "$valid_only")" || exit $?
    IDENTITY_HASHES=()
    while IFS= read -r hash; do
        if [[ -n "$hash" ]]; then
            IDENTITY_HASHES+=("$hash")
        fi
    done <<< "$hashes_text"
    return 0
}

read_identity_hashes 0
if (( ${#IDENTITY_HASHES[@]} > 1 )); then
    echo "setup-local-signing.sh: multiple exact signing identities named '$IDENTITY_NAME' exist in $KEYCHAIN" >&2
    exit 65
fi
if (( ${#IDENTITY_HASHES[@]} == 1 )); then
    read_identity_hashes 1
    if (( ${#IDENTITY_HASHES[@]} != 1 )); then
        echo "setup-local-signing.sh: '$IDENTITY_NAME' exists but is not trusted for code signing" >&2
        exit 66
    fi
    echo "Local signing identity already exists: $IDENTITY_NAME"
    exit 0
fi

TEMP_PARENT="$(canonical_directory "${TMPDIR:-/tmp}")" || {
    echo "setup-local-signing.sh: temporary directory is unavailable" >&2
    exit 66
}
MATERIAL_ROOT="$(/usr/bin/mktemp -d "$TEMP_PARENT/meeting-recorder-signing-setup.XXXXXX")" || {
    echo "setup-local-signing.sh: could not create temporary material directory" >&2
    exit 66
}
/bin/chmod 700 "$MATERIAL_ROOT"

cleanup_materials() {
    local original_status=$?
    trap - EXIT
    case "$MATERIAL_ROOT" in
        "$TEMP_PARENT"/meeting-recorder-signing-setup.*)
            /usr/bin/find "$MATERIAL_ROOT" -depth -delete >/dev/null 2>&1 || true
            ;;
        *)
            echo "setup-local-signing.sh: refused unsafe temporary cleanup path" >&2
            original_status=70
            ;;
    esac
    exit "$original_status"
}
trap cleanup_materials EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

PRIVATE_KEY="$MATERIAL_ROOT/private-key.pem"
CERTIFICATE="$MATERIAL_ROOT/certificate.pem"
IDENTITY_ARCHIVE="$MATERIAL_ROOT/identity.p12"
OPENSSL_LOG="$MATERIAL_ROOT/openssl.log"
SERIAL_HEX="$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
ARCHIVE_PASSWORD="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"

if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 \
    -nodes -batch -utf8 -set_serial "0x$SERIAL_HEX" \
    -subj "/CN=$IDENTITY_NAME/O=Meeting Recorder Local/OU=Code Signing/" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$PRIVATE_KEY" -out "$CERTIFICATE" >"$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: certificate generation failed" >&2
    exit 67
fi
/bin/chmod 600 "$PRIVATE_KEY" "$CERTIFICATE"

CERTIFICATE_TEXT="$(/usr/bin/openssl x509 -in "$CERTIFICATE" -noout -text 2>>"$OPENSSL_LOG")" || {
    echo "setup-local-signing.sh: generated certificate could not be inspected" >&2
    exit 67
}
[[ "$CERTIFICATE_TEXT" == *"X509v3 Extended Key Usage: critical"* &&
   "$CERTIFICATE_TEXT" == *"Code Signing"* &&
   "$CERTIFICATE_TEXT" == *"X509v3 Key Usage: critical"* &&
   "$CERTIFICATE_TEXT" == *"Digital Signature"* ]] || {
    echo "setup-local-signing.sh: generated certificate lacks code-signing restrictions" >&2
    exit 67
}

if ! /usr/bin/openssl pkcs12 -export -name "$IDENTITY_NAME" \
    -inkey "$PRIVATE_KEY" -in "$CERTIFICATE" -out "$IDENTITY_ARCHIVE" \
    -passout "pass:$ARCHIVE_PASSWORD" >>"$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: identity archive generation failed" >&2
    exit 67
fi
/bin/chmod 600 "$IDENTITY_ARCHIVE"

# User-domain trust requires one macOS authentication dialog. Trust is granted
# only for code signing, and the private key is imported only after acceptance.
if ! "$SECURITY_TOOL" add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN" "$CERTIFICATE" >/dev/null; then
    echo "setup-local-signing.sh: code-signing trust was not granted; no private key was imported" >&2
    exit 68
fi

if ! "$SECURITY_TOOL" import "$IDENTITY_ARCHIVE" -k "$KEYCHAIN" -f pkcs12 \
    -P "$ARCHIVE_PASSWORD" -x -T /usr/bin/codesign >/dev/null; then
    echo "setup-local-signing.sh: identity import failed" >&2
    exit 68
fi

read_identity_hashes 0
if (( ${#IDENTITY_HASHES[@]} != 1 )); then
    echo "setup-local-signing.sh: identity import did not produce exactly one match" >&2
    exit 68
fi
read_identity_hashes 1
if (( ${#IDENTITY_HASHES[@]} != 1 )); then
    echo "setup-local-signing.sh: imported identity is not valid for code signing" >&2
    exit 68
fi

echo "Created local signing identity: $IDENTITY_NAME"
