#!/bin/bash
set -euo pipefail

umask 077

IDENTITY_NAME="会议录音 Local Signing 2026-08-18"
ROOT_NAME="会议录音 Local Signing Root 2026-08-18"
PRODUCTION_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PRODUCTION_RECEIPT_DIRECTORY="$HOME/Library/Application Support/MeetingRecorder"
PRODUCTION_RECEIPT_PATH="$PRODUCTION_RECEIPT_DIRECTORY/local-signing-receipt-v1"
TESTING_MODE="${MEETING_RECORDER_SIGNING_SETUP_TESTING:-0}"
TEST_ROOT="${MEETING_RECORDER_SIGNING_TEST_ROOT:-}"
TEST_KEYCHAIN="${MEETING_RECORDER_SIGNING_TEST_KEYCHAIN:-}"
TEST_SECURITY_TOOL="${MEETING_RECORDER_SIGNING_TEST_SECURITY_TOOL:-}"
TEST_RECEIPT_PATH="${MEETING_RECORDER_SIGNING_TEST_RECEIPT_PATH:-}"

fail_usage() {
    echo "setup-local-signing.sh: $1" >&2
    exit 64
}

fail_state() {
    echo "setup-local-signing.sh: $1" >&2
    exit 66
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
        [[ -n "$TEST_ROOT" && -n "$TEST_KEYCHAIN" && -n "$TEST_SECURITY_TOOL" &&
           -n "$TEST_RECEIPT_PATH" ]] \
            || fail_usage "testing mode requires a root, keychain, security tool, and receipt path"
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

        [[ ! -L "$TEST_RECEIPT_PATH" ]] \
            || fail_usage "testing receipt path must not be a symbolic link"
        [[ -d "$(dirname "$TEST_RECEIPT_PATH")" && ! -L "$(dirname "$TEST_RECEIPT_PATH")" ]] \
            || fail_usage "testing receipt directory must be an existing non-symlink directory"
        RECEIPT_PATH="$(canonical_file "$TEST_RECEIPT_PATH")" \
            || fail_usage "testing receipt path could not be resolved"
        RECEIPT_DIRECTORY="$(dirname "$RECEIPT_PATH")"
        case "$RECEIPT_DIRECTORY" in
            "$CANONICAL_TEST_ROOT"/*) ;;
            *) fail_usage "testing receipt path must stay inside the testing root" ;;
        esac
        ;;
    0)
        if [[ -n "$TEST_ROOT" || -n "$TEST_KEYCHAIN" || -n "$TEST_SECURITY_TOOL" ||
              -n "$TEST_RECEIPT_PATH" ]]; then
            fail_usage "test-only overrides require MEETING_RECORDER_SIGNING_SETUP_TESTING=1"
        fi
        KEYCHAIN="$PRODUCTION_KEYCHAIN"
        SECURITY_TOOL="/usr/bin/security"
        RECEIPT_DIRECTORY="$PRODUCTION_RECEIPT_DIRECTORY"
        RECEIPT_PATH="$PRODUCTION_RECEIPT_PATH"
        [[ ! -L "$RECEIPT_DIRECTORY" && ! -L "$RECEIPT_PATH" ]] \
            || fail_state "production receipt path must not contain symbolic links"
        ;;
    *)
        fail_usage "MEETING_RECORDER_SIGNING_SETUP_TESTING must be 0 or 1"
        ;;
esac

[[ -f "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] \
    || fail_state "keychain does not exist or is a symbolic link: $KEYCHAIN"

CURRENT_UID="$(/usr/bin/id -u)" || fail_state "could not determine the current user"
IDENTITY_HASHES=()
CERTIFICATE_HASHES=()
RECEIPT_VERSION=""
RECEIPT_IDENTITY_NAME=""
RECEIPT_ROOT_SHA1=""
RECEIPT_LEAF_SHA1=""

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
                if (hash ~ /^[0-9A-F]+$/ && length(hash) == 40 && !seen[hash]++) print hash
            }
        }
    '
}

read_identity_hashes() {
    local valid_only="$1"
    local hashes_text
    hashes_text="$(identity_hashes "$valid_only")" || return $?
    IDENTITY_HASHES=()
    while IFS= read -r hash; do
        if [[ -n "$hash" ]]; then
            IDENTITY_HASHES+=("$hash")
        fi
    done <<< "$hashes_text"
}

certificate_hashes() {
    local certificate_name="$1"
    local output
    if ! output="$(LC_ALL=en_US.UTF-8 "$SECURITY_TOOL" find-certificate -a \
        -c "$certificate_name" -Z "$KEYCHAIN" 2>&1)"; then
        [[ "$output" == *"could not be found"* ]] && return 0
        echo "setup-local-signing.sh: could not inspect certificate '$certificate_name'" >&2
        return 66
    fi
    printf '%s\n' "$output" | /usr/bin/awk '
        /^SHA-1 hash: / {
            hash = toupper($3)
            if (hash ~ /^[0-9A-F]+$/ && length(hash) == 40 && !seen[hash]++) print hash
        }
    '
}

read_certificate_hashes() {
    local certificate_name="$1"
    local hashes_text
    hashes_text="$(certificate_hashes "$certificate_name")" || return $?
    CERTIFICATE_HASHES=()
    while IFS= read -r hash; do
        if [[ -n "$hash" ]]; then
            CERTIFICATE_HASHES+=("$hash")
        fi
    done <<< "$hashes_text"
}

certificate_list_contains() {
    local expected="$1"
    local index
    for (( index = 0; index < ${#CERTIFICATE_HASHES[@]}; index += 1 )); do
        [[ "${CERTIFICATE_HASHES[$index]}" == "$expected" ]] && return 0
    done
    return 1
}

identity_list_contains() {
    local expected="$1"
    local index
    for (( index = 0; index < ${#IDENTITY_HASHES[@]}; index += 1 )); do
        [[ "${IDENTITY_HASHES[$index]}" == "$expected" ]] && return 0
    done
    return 1
}

secure_directory() {
    local directory="$1"
    local canonical mode owner
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    canonical="$(canonical_directory "$directory")" || return 1
    [[ "$canonical" == "$directory" ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$directory")" || return 1
    owner="$(/usr/bin/stat -f '%u' "$directory")" || return 1
    [[ "$mode" == "700" && "$owner" == "$CURRENT_UID" ]]
}

ensure_receipt_directory() {
    if [[ ! -e "$RECEIPT_DIRECTORY" ]]; then
        [[ "$TESTING_MODE" == "0" ]] \
            || { echo "setup-local-signing.sh: testing receipt directory disappeared" >&2; return 66; }
        [[ "$(dirname "$RECEIPT_DIRECTORY")" == "$HOME/Library/Application Support" ]] \
            || { echo "setup-local-signing.sh: refused unexpected receipt directory" >&2; return 66; }
        [[ "$(canonical_directory "$(dirname "$RECEIPT_DIRECTORY")")" == "$HOME/Library/Application Support" ]] \
            || { echo "setup-local-signing.sh: receipt parent directory is unsafe" >&2; return 66; }
        if /bin/mkdir "$RECEIPT_DIRECTORY"; then
            receipt_directory_created=1
        elif [[ ! -d "$RECEIPT_DIRECTORY" ]]; then
            echo "setup-local-signing.sh: could not create receipt directory" >&2
            return 66
        fi
        /bin/chmod 700 "$RECEIPT_DIRECTORY" || return 66
    fi
    if ! secure_directory "$RECEIPT_DIRECTORY"; then
        echo "setup-local-signing.sh: receipt directory must be owned by the current user with mode 700" >&2
        return 66
    fi
}

load_receipt() {
    local mode owner links key value
    local version_seen=0 identity_seen=0 root_seen=0 leaf_seen=0
    [[ -f "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]] || {
        echo "setup-local-signing.sh: pinned signing receipt is missing or unsafe: $RECEIPT_PATH" >&2
        return 66
    }
    mode="$(/usr/bin/stat -f '%Lp' "$RECEIPT_PATH")" || return 66
    owner="$(/usr/bin/stat -f '%u' "$RECEIPT_PATH")" || return 66
    links="$(/usr/bin/stat -f '%l' "$RECEIPT_PATH")" || return 66
    if [[ "$mode" != "600" || "$owner" != "$CURRENT_UID" || "$links" != "1" ]]; then
        echo "setup-local-signing.sh: pinned signing receipt must be owned by the current user, mode 600, with one link" >&2
        return 66
    fi
    RECEIPT_VERSION=""; RECEIPT_IDENTITY_NAME=""; RECEIPT_ROOT_SHA1=""; RECEIPT_LEAF_SHA1=""
    while IFS='=' read -r key value; do
        case "$key" in
            version) (( version_seen += 1 )); RECEIPT_VERSION="$value" ;;
            identity_name) (( identity_seen += 1 )); RECEIPT_IDENTITY_NAME="$value" ;;
            root_sha1) (( root_seen += 1 )); RECEIPT_ROOT_SHA1="$(printf '%s' "$value" | /usr/bin/tr '[:lower:]' '[:upper:]')" ;;
            leaf_sha1) (( leaf_seen += 1 )); RECEIPT_LEAF_SHA1="$(printf '%s' "$value" | /usr/bin/tr '[:lower:]' '[:upper:]')" ;;
            *) echo "setup-local-signing.sh: pinned signing receipt contains an unexpected field" >&2; return 66 ;;
        esac
    done < "$RECEIPT_PATH"
    if (( version_seen != 1 || identity_seen != 1 || root_seen != 1 || leaf_seen != 1 )) ||
       [[ "$RECEIPT_VERSION" != "1" || "$RECEIPT_IDENTITY_NAME" != "$IDENTITY_NAME" ||
          ! "$RECEIPT_ROOT_SHA1" =~ ^[0-9A-F]{40}$ || ! "$RECEIPT_LEAF_SHA1" =~ ^[0-9A-F]{40}$ ]]; then
        echo "setup-local-signing.sh: pinned signing receipt is malformed or names a different identity" >&2
        return 66
    fi
}

fingerprint_from_certificate() {
    local certificate="$1" output fingerprint
    output="$(/usr/bin/openssl x509 -in "$certificate" -noout -sha1 -fingerprint 2>/dev/null)" || return 1
    fingerprint="${output#*=}"
    fingerprint="$(printf '%s' "$fingerprint" | /usr/bin/tr -d ':' | /usr/bin/tr '[:lower:]' '[:upper:]')"
    [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s\n' "$fingerprint"
}

extension_value() {
    local certificate_text="$1" header="$2"
    printf '%s\n' "$certificate_text" | /usr/bin/awk -v header="$header" '
        index($0, header) { if (getline > 0) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print } exit }
    '
}

validate_certificate_files() {
    local root_certificate="$1" leaf_certificate="$2" expected_root="$3" expected_leaf="$4"
    local actual_root actual_leaf root_text leaf_text root_basic root_usage leaf_basic leaf_usage leaf_eku
    local root_subject leaf_subject leaf_issuer
    actual_root="$(fingerprint_from_certificate "$root_certificate")" || {
        echo "setup-local-signing.sh: root certificate fingerprint could not be read" >&2; return 66; }
    actual_leaf="$(fingerprint_from_certificate "$leaf_certificate")" || {
        echo "setup-local-signing.sh: leaf certificate fingerprint could not be read" >&2; return 66; }
    [[ "$actual_root" == "$expected_root" && "$actual_leaf" == "$expected_leaf" ]] || {
        echo "setup-local-signing.sh: installed certificate fingerprint does not match the pinned receipt" >&2; return 66; }
    root_text="$(/usr/bin/openssl x509 -in "$root_certificate" -noout -text 2>/dev/null)" || return 66
    leaf_text="$(/usr/bin/openssl x509 -in "$leaf_certificate" -noout -text 2>/dev/null)" || return 66
    root_basic="$(extension_value "$root_text" "X509v3 Basic Constraints: critical")"
    root_usage="$(extension_value "$root_text" "X509v3 Key Usage: critical")"
    leaf_basic="$(extension_value "$leaf_text" "X509v3 Basic Constraints: critical")"
    leaf_usage="$(extension_value "$leaf_text" "X509v3 Key Usage: critical")"
    leaf_eku="$(extension_value "$leaf_text" "X509v3 Extended Key Usage: critical")"
    if [[ "$root_basic" != "CA:TRUE, pathlen:0" || "$root_usage" != "Certificate Sign, CRL Sign" ]]; then
        echo "setup-local-signing.sh: root certificate profile is invalid" >&2; return 66
    fi
    if [[ "$leaf_basic" != "CA:FALSE" || "$leaf_usage" != "Digital Signature" || "$leaf_eku" != "Code Signing" ]]; then
        echo "setup-local-signing.sh: leaf certificate profile is invalid" >&2; return 66
    fi
    root_subject="$(/usr/bin/openssl x509 -in "$root_certificate" -noout -subject -nameopt 'RFC2253,utf8,-esc_msb' 2>/dev/null)" || return 66
    leaf_subject="$(/usr/bin/openssl x509 -in "$leaf_certificate" -noout -subject -nameopt 'RFC2253,utf8,-esc_msb' 2>/dev/null)" || return 66
    leaf_issuer="$(/usr/bin/openssl x509 -in "$leaf_certificate" -noout -issuer -nameopt 'RFC2253,utf8,-esc_msb' 2>/dev/null)" || return 66
    if [[ "$root_subject" != *"CN=$ROOT_NAME"* || "$leaf_subject" != *"CN=$IDENTITY_NAME"* ||
          "$leaf_issuer" != *"CN=$ROOT_NAME"* ]]; then
        echo "setup-local-signing.sh: certificate subject or issuer is invalid" >&2; return 66
    fi
    if ! /usr/bin/openssl x509 -in "$root_certificate" -noout -checkend 0 >/dev/null 2>&1 ||
       ! /usr/bin/openssl x509 -in "$leaf_certificate" -noout -checkend 0 >/dev/null 2>&1 ||
       ! /usr/bin/openssl verify -CAfile "$root_certificate" "$leaf_certificate" >/dev/null 2>&1; then
        echo "setup-local-signing.sh: certificate validity or chain verification failed" >&2; return 66
    fi
}

export_certificate() {
    local certificate_name="$1" destination="$2"
    if ! LC_ALL=en_US.UTF-8 "$SECURITY_TOOL" find-certificate -c "$certificate_name" -p "$KEYCHAIN" > "$destination"; then
        echo "setup-local-signing.sh: could not export certificate '$certificate_name'" >&2; return 66
    fi
    /bin/chmod 600 "$destination" || return 66
}

validate_leaf_acl() {
    local leaf_certificate="$1"
    local dump public_key_hash matching_keys certificate_serial
    dump="$(LC_ALL=en_US.UTF-8 "$SECURITY_TOOL" dump-keychain -a "$KEYCHAIN" 2>&1)" || {
        echo "setup-local-signing.sh: could not inspect private-key ACL" >&2; return 66; }
    certificate_serial="$(/usr/bin/openssl x509 -in "$leaf_certificate" -noout -serial 2>/dev/null)" || return 66
    certificate_serial="${certificate_serial#*=}"
    certificate_serial="$(printf '%s' "$certificate_serial" | /usr/bin/sed 's/^0*//' | /usr/bin/tr '[:lower:]' '[:upper:]')"
    [[ -n "$certificate_serial" ]] || certificate_serial="0"
    public_key_hash="$(printf '%s\n' "$dump" | /usr/bin/awk -v expected_serial="$certificate_serial" '
        BEGIN { RS = "keychain: " }
        index($0, "class: 0x80001000") && match($0, /\"snbr\"<blob>=0x[0-9A-Fa-f]+/) {
            serial = substr($0, RSTART, RLENGTH); sub(/^.*0x/, "", serial)
            serial = toupper(serial); sub(/^0+/, "", serial); if (serial == "") serial = "0"
            if (serial == expected_serial && match($0, /\"hpky\"<blob>=0x[0-9A-Fa-f]+/)) {
                value = substr($0, RSTART, RLENGTH); sub(/^.*0x/, "", value); print toupper(value)
            }
        }
    ')"
    [[ "$public_key_hash" =~ ^[0-9A-F]{40}$ ]] || {
        echo "setup-local-signing.sh: leaf public key could not be correlated with its ACL" >&2; return 66; }
    matching_keys="$(printf '%s\n' "$dump" | /usr/bin/awk -v hash="$public_key_hash" '
        BEGIN { RS = "keychain: "; count = 0 }
        index($0, "class: 0x00000010") && index($0, "0x00000006 <blob>=0x" hash) &&
        $0 ~ /authorizations .*sign/ && index($0, "applications (1):") &&
        index($0, "0: /usr/bin/codesign (OK)") &&
        index($0, "requirement: identifier \"com.apple.security.codesign\" and anchor apple") { count += 1 }
        END { print count }
    ')"
    [[ "$matching_keys" == "1" ]] || {
        echo "setup-local-signing.sh: leaf private-key ACL is not restricted to Apple codesign" >&2; return 66; }
}

validate_installed_identity() {
    local expected_root="$1" expected_leaf="$2"
    local validation_root="$MATERIAL_ROOT/installed-root.pem" validation_leaf="$MATERIAL_ROOT/installed-leaf.pem"
    read_identity_hashes 0 || return $?
    if (( ${#IDENTITY_HASHES[@]} != 1 )) || [[ "${IDENTITY_HASHES[0]}" != "$expected_leaf" ]]; then
        echo "setup-local-signing.sh: exact identity fingerprint is missing or duplicated" >&2; return 66
    fi
    read_identity_hashes 1 || return $?
    if (( ${#IDENTITY_HASHES[@]} != 1 )) || [[ "${IDENTITY_HASHES[0]}" != "$expected_leaf" ]]; then
        echo "setup-local-signing.sh: pinned identity is not valid for code signing" >&2; return 66
    fi
    read_certificate_hashes "$IDENTITY_NAME" || return $?
    if (( ${#CERTIFICATE_HASHES[@]} != 1 )) || [[ "${CERTIFICATE_HASHES[0]}" != "$expected_leaf" ]]; then
        echo "setup-local-signing.sh: leaf certificate fingerprint does not match the pinned receipt" >&2; return 66
    fi
    read_certificate_hashes "$ROOT_NAME" || return $?
    if (( ${#CERTIFICATE_HASHES[@]} != 1 )) || [[ "${CERTIFICATE_HASHES[0]}" != "$expected_root" ]]; then
        echo "setup-local-signing.sh: root certificate fingerprint does not match the pinned receipt" >&2; return 66
    fi
    export_certificate "$ROOT_NAME" "$validation_root" || return $?
    export_certificate "$IDENTITY_NAME" "$validation_leaf" || return $?
    validate_certificate_files "$validation_root" "$validation_leaf" "$expected_root" "$expected_leaf" || return $?
    validate_leaf_acl "$validation_leaf" || return $?
}

write_receipt_atomically() {
    local root_fingerprint="$1" leaf_fingerprint="$2" final_inode
    [[ ! -e "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]] || {
        echo "setup-local-signing.sh: refused to overwrite an existing signing receipt" >&2; return 66; }
    RECEIPT_TEMP="$(/usr/bin/mktemp "$RECEIPT_DIRECTORY/.local-signing-receipt.XXXXXX")" || return 66
    /bin/chmod 600 "$RECEIPT_TEMP" || return 66
    printf 'version=1\nidentity_name=%s\nroot_sha1=%s\nleaf_sha1=%s\n' \
        "$IDENTITY_NAME" "$root_fingerprint" "$leaf_fingerprint" > "$RECEIPT_TEMP" || return 66
    /bin/ln "$RECEIPT_TEMP" "$RECEIPT_PATH" || {
        echo "setup-local-signing.sh: could not atomically publish signing receipt" >&2; return 66; }
    receipt_written=1
    final_inode="$(/usr/bin/stat -f '%i' "$RECEIPT_PATH")" || return 66
    RECEIPT_INODE="$final_inode"
    /bin/rm -f "$RECEIPT_TEMP" || return 66
    RECEIPT_TEMP=""
    load_receipt || return $?
    [[ "$RECEIPT_ROOT_SHA1" == "$root_fingerprint" && "$RECEIPT_LEAF_SHA1" == "$leaf_fingerprint" ]] || return 66
}

TEMP_PARENT="$(canonical_directory "${TMPDIR:-/tmp}")" || fail_state "temporary directory is unavailable"
MATERIAL_ROOT="$(/usr/bin/mktemp -d "$TEMP_PARENT/meeting-recorder-signing-setup.XXXXXX")" \
    || fail_state "could not create temporary material directory"
/bin/chmod 700 "$MATERIAL_ROOT"

setup_succeeded=0; trust_attempted=0; import_attempted=0; receipt_written=0; receipt_directory_created=0
RECEIPT_TEMP=""; RECEIPT_INODE=""; ROOT_FINGERPRINT=""; LEAF_FINGERPRINT=""

remove_temporary_materials() {
    if [[ -n "$RECEIPT_TEMP" ]]; then
        case "$RECEIPT_TEMP" in
            "$RECEIPT_DIRECTORY"/.local-signing-receipt.*) /bin/rm -f "$RECEIPT_TEMP" || return 1; RECEIPT_TEMP="" ;;
            *) return 1 ;;
        esac
    fi
    if [[ -n "$MATERIAL_ROOT" ]]; then
        case "$MATERIAL_ROOT" in
            "$TEMP_PARENT"/meeting-recorder-signing-setup.*)
                /usr/bin/find "$MATERIAL_ROOT" -depth -delete >/dev/null 2>&1 || return 1
                [[ ! -e "$MATERIAL_ROOT" ]] || return 1
                MATERIAL_ROOT=""
                ;;
            *) return 1 ;;
        esac
    fi
}

rollback_setup() {
    local cleanup_failed=0 receipt_inode=""
    if (( receipt_written )); then
        if [[ -f "$RECEIPT_PATH" && ! -L "$RECEIPT_PATH" ]]; then
            receipt_inode="$(/usr/bin/stat -f '%i' "$RECEIPT_PATH" 2>/dev/null)" || cleanup_failed=1
            if [[ -n "$receipt_inode" && "$receipt_inode" == "$RECEIPT_INODE" ]]; then
                /bin/rm -f "$RECEIPT_PATH" || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        elif [[ -e "$RECEIPT_PATH" || -L "$RECEIPT_PATH" ]]; then cleanup_failed=1
        fi
    fi
    if (( import_attempted )); then
        if read_identity_hashes 0; then
            if identity_list_contains "$LEAF_FINGERPRINT"; then
                "$SECURITY_TOOL" delete-identity -Z "$LEAF_FINGERPRINT" "$KEYCHAIN" >/dev/null 2>&1 || cleanup_failed=1
            elif read_certificate_hashes "$IDENTITY_NAME" && certificate_list_contains "$LEAF_FINGERPRINT"; then
                "$SECURITY_TOOL" delete-certificate -Z "$LEAF_FINGERPRINT" "$KEYCHAIN" >/dev/null 2>&1 || cleanup_failed=1
            fi
        else cleanup_failed=1
        fi
        if read_certificate_hashes "$IDENTITY_NAME"; then
            certificate_list_contains "$LEAF_FINGERPRINT" && cleanup_failed=1
        else cleanup_failed=1
        fi
    fi
    if (( trust_attempted )); then
        if read_certificate_hashes "$ROOT_NAME"; then
            if certificate_list_contains "$ROOT_FINGERPRINT"; then
                "$SECURITY_TOOL" delete-certificate -Z "$ROOT_FINGERPRINT" -t "$KEYCHAIN" >/dev/null 2>&1 || cleanup_failed=1
            fi
        else cleanup_failed=1
        fi
        if read_certificate_hashes "$ROOT_NAME"; then
            certificate_list_contains "$ROOT_FINGERPRINT" && cleanup_failed=1
        else cleanup_failed=1
        fi
    fi
    if (( receipt_directory_created )) && [[ -d "$RECEIPT_DIRECTORY" ]]; then
        /bin/rmdir "$RECEIPT_DIRECTORY" >/dev/null 2>&1 || cleanup_failed=1
    fi
    return "$cleanup_failed"
}

finish_setup() {
    local original_status=$? final_status cleanup_failed=0
    final_status=$original_status
    trap - EXIT HUP INT QUIT TERM
    set +e
    (( setup_succeeded )) || rollback_setup || cleanup_failed=1
    remove_temporary_materials || cleanup_failed=1
    if (( cleanup_failed )); then
        echo "setup-local-signing.sh: cleanup or rollback was incomplete; manual remediation is required." >&2
        echo "setup-local-signing.sh: inspect receipt '$RECEIPT_PATH', leaf $LEAF_FINGERPRINT, and root $ROOT_FINGERPRINT in $KEYCHAIN" >&2
        final_status=70
    elif (( final_status == 0 && ! setup_succeeded )); then final_status=70
    fi
    exit "$final_status"
}

trap finish_setup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

[[ ! -e "$RECEIPT_DIRECTORY" ]] || ensure_receipt_directory || exit $?
read_identity_hashes 0 || exit $?
identity_count=${#IDENTITY_HASHES[@]}
if (( identity_count > 1 )); then
    echo "setup-local-signing.sh: multiple exact signing identities named '$IDENTITY_NAME' exist in $KEYCHAIN" >&2
    exit 65
fi
read_certificate_hashes "$IDENTITY_NAME" || exit $?
leaf_certificate_count=${#CERTIFICATE_HASHES[@]}
read_certificate_hashes "$ROOT_NAME" || exit $?
root_certificate_count=${#CERTIFICATE_HASHES[@]}

if (( identity_count == 1 )); then
    ensure_receipt_directory || exit $?
    load_receipt || exit $?
    [[ "${IDENTITY_HASHES[0]}" == "$RECEIPT_LEAF_SHA1" ]] || {
        echo "setup-local-signing.sh: existing identity fingerprint does not match the pinned receipt" >&2; exit 66; }
    ROOT_FINGERPRINT="$RECEIPT_ROOT_SHA1"; LEAF_FINGERPRINT="$RECEIPT_LEAF_SHA1"
    validate_installed_identity "$ROOT_FINGERPRINT" "$LEAF_FINGERPRINT" || exit $?
    remove_temporary_materials || {
        echo "setup-local-signing.sh: temporary cleanup failed; manual remediation is required" >&2; exit 70; }
    setup_succeeded=1
    echo "Local signing identity already exists and matches its pinned receipt: $IDENTITY_NAME"
    exit 0
fi

if [[ -e "$RECEIPT_PATH" || -L "$RECEIPT_PATH" || "$leaf_certificate_count" != "0" || "$root_certificate_count" != "0" ]]; then
    echo "setup-local-signing.sh: signing artifacts exist without one matching pinned identity; refusing to overwrite" >&2
    exit 66
fi
ensure_receipt_directory || exit $?

ROOT_PRIVATE_KEY="$MATERIAL_ROOT/root-private-key.pem"; ROOT_CERTIFICATE="$MATERIAL_ROOT/root-certificate.pem"
LEAF_PRIVATE_KEY="$MATERIAL_ROOT/leaf-private-key.pem"; LEAF_REQUEST="$MATERIAL_ROOT/leaf.csr"
LEAF_CERTIFICATE="$MATERIAL_ROOT/leaf-certificate.pem"; LEAF_EXTENSIONS="$MATERIAL_ROOT/leaf-extensions.cnf"
IDENTITY_ARCHIVE="$MATERIAL_ROOT/leaf-identity.p12"; OPENSSL_LOG="$MATERIAL_ROOT/openssl.log"
ROOT_SERIAL="$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"; LEAF_SERIAL="$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
ARCHIVE_PASSWORD="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"

if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -batch -utf8 \
    -set_serial "0x$ROOT_SERIAL" -subj "/CN=$ROOT_NAME/O=Meeting Recorder Local/OU=Code Signing Root/" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" -keyout "$ROOT_PRIVATE_KEY" -out "$ROOT_CERTIFICATE" \
    > "$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: root certificate generation failed" >&2; exit 67
fi
if ! /usr/bin/openssl req -new -newkey rsa:2048 -sha256 -nodes -batch -utf8 \
    -subj "/CN=$IDENTITY_NAME/O=Meeting Recorder Local/OU=Code Signing/" \
    -keyout "$LEAF_PRIVATE_KEY" -out "$LEAF_REQUEST" >> "$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: leaf certificate request generation failed" >&2; exit 67
fi
printf '%s\n' '[leaf_extensions]' 'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' 'extendedKeyUsage=critical,codeSigning' \
    'subjectKeyIdentifier=hash' 'authorityKeyIdentifier=keyid,issuer' > "$LEAF_EXTENSIONS"
if ! /usr/bin/openssl x509 -req -sha256 -days 3650 -set_serial "0x$LEAF_SERIAL" \
    -in "$LEAF_REQUEST" -CA "$ROOT_CERTIFICATE" -CAkey "$ROOT_PRIVATE_KEY" \
    -extfile "$LEAF_EXTENSIONS" -extensions leaf_extensions -out "$LEAF_CERTIFICATE" \
    >> "$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: leaf certificate signing failed" >&2; exit 67
fi
/bin/chmod 600 "$ROOT_PRIVATE_KEY" "$ROOT_CERTIFICATE" "$LEAF_PRIVATE_KEY" "$LEAF_REQUEST" \
    "$LEAF_CERTIFICATE" "$LEAF_EXTENSIONS" "$OPENSSL_LOG"
ROOT_FINGERPRINT="$(fingerprint_from_certificate "$ROOT_CERTIFICATE")" || {
    echo "setup-local-signing.sh: generated root fingerprint could not be read" >&2; exit 67; }
LEAF_FINGERPRINT="$(fingerprint_from_certificate "$LEAF_CERTIFICATE")" || {
    echo "setup-local-signing.sh: generated leaf fingerprint could not be read" >&2; exit 67; }
validate_certificate_files "$ROOT_CERTIFICATE" "$LEAF_CERTIFICATE" "$ROOT_FINGERPRINT" "$LEAF_FINGERPRINT" || exit $?
/bin/rm -f "$ROOT_PRIVATE_KEY" || { echo "setup-local-signing.sh: root private key could not be destroyed" >&2; exit 67; }
[[ ! -e "$ROOT_PRIVATE_KEY" ]] || { echo "setup-local-signing.sh: root private key remains on disk" >&2; exit 67; }
if ! /usr/bin/openssl pkcs12 -export -name "$IDENTITY_NAME" -inkey "$LEAF_PRIVATE_KEY" \
    -in "$LEAF_CERTIFICATE" -out "$IDENTITY_ARCHIVE" -passout "pass:$ARCHIVE_PASSWORD" \
    >> "$OPENSSL_LOG" 2>&1; then
    echo "setup-local-signing.sh: leaf identity archive generation failed" >&2; exit 67
fi
/bin/chmod 600 "$IDENTITY_ARCHIVE"

trust_attempted=1
if ! "$SECURITY_TOOL" add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$ROOT_CERTIFICATE" >/dev/null; then
    echo "setup-local-signing.sh: code-signing trust was not granted" >&2; exit 68
fi
import_attempted=1
if ! "$SECURITY_TOOL" import "$IDENTITY_ARCHIVE" -k "$KEYCHAIN" -f pkcs12 \
    -P "$ARCHIVE_PASSWORD" -x -T /usr/bin/codesign >/dev/null; then
    echo "setup-local-signing.sh: leaf identity import failed" >&2; exit 68
fi
validate_installed_identity "$ROOT_FINGERPRINT" "$LEAF_FINGERPRINT" || exit $?
write_receipt_atomically "$ROOT_FINGERPRINT" "$LEAF_FINGERPRINT" || exit $?
remove_temporary_materials || {
    echo "setup-local-signing.sh: temporary cleanup failed; manual remediation is required" >&2; exit 70; }
setup_succeeded=1
echo "Created local signing identity and pinned receipt: $IDENTITY_NAME"
