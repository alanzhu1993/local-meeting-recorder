#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUNDLE_ID="com.alan.local-meeting-recorder"
APP_NAME="会议录音.app"
EXECUTABLE_NAME="MeetingRecorderApp"
TEST_MODE="${MEETING_RECORDER_INSTALL_TESTING:-0}"
DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

BUILD_DATE="${1:-$(/bin/date +%F)}"
if [[ "$BUILD_DATE" != [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]]; then
    print -u2 -- "Invalid build date: $BUILD_DATE (expected YYYY-MM-DD)"
    exit 64
fi

if [[ "$TEST_MODE" == "1" ]]; then
    TEST_ROOT_INPUT="${MEETING_RECORDER_TEST_ROOT:-}"
    [[ -n "$TEST_ROOT_INPUT" ]] || { print -u2 -- "Test root is required in install testing mode."; exit 70; }
    [[ -d "$TEST_ROOT_INPUT" && ! -L "$TEST_ROOT_INPUT" ]] || {
        print -u2 -- "Install test root must be an existing non-symlink directory."
        exit 70
    }
    TEST_ROOT="${TEST_ROOT_INPUT:A}"
    TEMP_ROOT="${TMPDIR:-/tmp}"
    TEMP_ROOT="${TEMP_ROOT:A}"
    if [[ "$TEST_ROOT" != "$TEMP_ROOT"/meeting-recorder-install-test.* ]]; then
        print -u2 -- "Unsafe install test root: $TEST_ROOT"
        exit 70
    fi

    SOURCE_ROOT_INPUT="${MEETING_RECORDER_SOURCE_ROOT:-$TEST_ROOT/source}"
    INSTALL_ROOT_INPUT="${MEETING_RECORDER_INSTALL_ROOT:-$TEST_ROOT/install}"
    BACKUP_ROOT_INPUT="${MEETING_RECORDER_BACKUP_ROOT:-$TEST_ROOT/backups}"
    if [[ ! -d "$SOURCE_ROOT_INPUT" || -L "$SOURCE_ROOT_INPUT" ||
          ! -d "$INSTALL_ROOT_INPUT" || -L "$INSTALL_ROOT_INPUT" ||
          ! -d "$BACKUP_ROOT_INPUT" || -L "$BACKUP_ROOT_INPUT" ]]; then
        print -u2 -- "Install test roots must be existing non-symlink directories."
        exit 70
    fi
    SOURCE_ROOT="${SOURCE_ROOT_INPUT:A}"
    INSTALL_ROOT="${INSTALL_ROOT_INPUT:A}"
    BACKUP_ROOT="${BACKUP_ROOT_INPUT:A}"
    if [[ "$SOURCE_ROOT" != "$TEST_ROOT"/* ||
          "$INSTALL_ROOT" != "$TEST_ROOT"/* ||
          "$BACKUP_ROOT" != "$TEST_ROOT"/* ]]; then
        print -u2 -- "Install test paths must remain inside: $TEST_ROOT"
        exit 70
    fi
    if [[ "$SOURCE_ROOT" == "$INSTALL_ROOT" ||
          "$SOURCE_ROOT" == "$BACKUP_ROOT" ||
          "$INSTALL_ROOT" == "$BACKUP_ROOT" ]]; then
        print -u2 -- "Install test source, target, and backup roots must be distinct."
        exit 70
    fi

    DITTO_TOOL="${MEETING_RECORDER_DITTO_TOOL:-/usr/bin/ditto}"
    CODESIGN_TOOL="${MEETING_RECORDER_CODESIGN_TOOL:-/usr/bin/codesign}"
    OPEN_TOOL="${MEETING_RECORDER_OPEN_TOOL:-/usr/bin/open}"
    QUIT_TOOL="${MEETING_RECORDER_QUIT_TOOL:-}"
    PGREP_TOOL="${MEETING_RECORDER_PGREP_TOOL:-/usr/bin/pgrep}"
    PS_TOOL="${MEETING_RECORDER_PS_TOOL:-/bin/ps}"
    SLEEP_TOOL="${MEETING_RECORDER_SLEEP_TOOL:-/bin/sleep}"
    MV_TOOL="${MEETING_RECORDER_MV_TOOL:-/bin/mv}"
    QUIT_ATTEMPTS="${MEETING_RECORDER_QUIT_ATTEMPTS:-2}"
    BACKUP_STAMP="${MEETING_RECORDER_TEST_BACKUP_STAMP:-$(/bin/date +%F-%H%M%S)}"

    for tool in "$DITTO_TOOL" "$CODESIGN_TOOL" "$OPEN_TOOL" "$PGREP_TOOL" "$PS_TOOL" "$SLEEP_TOOL" "$MV_TOOL"; do
        if [[ "$tool" != /* || ! -x "$tool" ]]; then
            print -u2 -- "Invalid install test tool: $tool"
            exit 70
        fi
    done
    if [[ -n "$QUIT_TOOL" && ( "$QUIT_TOOL" != /* || ! -x "$QUIT_TOOL" ) ]]; then
        print -u2 -- "Invalid install test quit tool: $QUIT_TOOL"
        exit 70
    fi
else
    if [[ "$TEST_MODE" != "0" ]]; then
        print -u2 -- "MEETING_RECORDER_INSTALL_TESTING must be 0 or 1."
        exit 70
    fi
    for override in \
        MEETING_RECORDER_TEST_ROOT MEETING_RECORDER_SOURCE_ROOT MEETING_RECORDER_INSTALL_ROOT \
        MEETING_RECORDER_BACKUP_ROOT \
        MEETING_RECORDER_DITTO_TOOL MEETING_RECORDER_CODESIGN_TOOL MEETING_RECORDER_OPEN_TOOL \
        MEETING_RECORDER_QUIT_TOOL MEETING_RECORDER_PGREP_TOOL MEETING_RECORDER_PS_TOOL \
        MEETING_RECORDER_SLEEP_TOOL MEETING_RECORDER_MV_TOOL MEETING_RECORDER_QUIT_ATTEMPTS \
        MEETING_RECORDER_TEST_BACKUP_STAMP; do
        if [[ -n "${(P)override:-}" ]]; then
            print -u2 -- "Test override $override requires MEETING_RECORDER_INSTALL_TESTING=1."
            exit 70
        fi
    done

    SOURCE_ROOT="$PROJECT_DIR/dist"
    INSTALL_ROOT="/Users/alan/Applications"
    BACKUP_ROOT="/Users/alan/Documents/快速本地录音软件/安装备份"
    DITTO_TOOL="/usr/bin/ditto"
    CODESIGN_TOOL="/usr/bin/codesign"
    OPEN_TOOL="/usr/bin/open"
    QUIT_TOOL="/usr/bin/osascript"
    PGREP_TOOL="/usr/bin/pgrep"
    PS_TOOL="/bin/ps"
    SLEEP_TOOL="/bin/sleep"
    MV_TOOL="/bin/mv"
    QUIT_ATTEMPTS=50
    BACKUP_STAMP="$(/bin/date +%F-%H%M%S)"
fi

if [[ "$BACKUP_STAMP" != [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
    print -u2 -- "Invalid backup timestamp: $BACKUP_STAMP"
    exit 70
fi
if [[ "$QUIT_ATTEMPTS" != <-> || "$QUIT_ATTEMPTS" -lt 1 || "$QUIT_ATTEMPTS" -gt 600 ]]; then
    print -u2 -- "Invalid quit wait attempt count: $QUIT_ATTEMPTS"
    exit 70
fi

SOURCE_APP="$SOURCE_ROOT/会议录音-$BUILD_DATE.app"
TARGET_APP="$INSTALL_ROOT/$APP_NAME"
SOURCE_APP="${SOURCE_APP:A}"
TARGET_APP="${TARGET_APP:A}"
EXPECTED_TARGET="$INSTALL_ROOT/$APP_NAME"
EXPECTED_TARGET="${EXPECTED_TARGET:A}"

if [[ "$TARGET_APP" != "$EXPECTED_TARGET" ]]; then
    print -u2 -- "Refusing unexpected install target: $TARGET_APP"
    exit 65
fi
if [[ "$TEST_MODE" == "0" && "$TARGET_APP" != "/Users/alan/Applications/会议录音.app" ]]; then
    print -u2 -- "Refusing unexpected production install target: $TARGET_APP"
    exit 65
fi
BACKUP_ROOT="${BACKUP_ROOT:A}"
if [[ "$TEST_MODE" == "0" && "$BACKUP_ROOT" != "/Users/alan/Documents/快速本地录音软件/安装备份" ]]; then
    print -u2 -- "Refusing unexpected production backup root: $BACKUP_ROOT"
    exit 65
fi

# Complete source preflight happens before process quit, backup, or target mutation.
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 -- "Source app does not exist: $SOURCE_APP"
    exit 66
fi
if [[ ! -x "$SOURCE_APP/Contents/MacOS/$EXECUTABLE_NAME" ]]; then
    print -u2 -- "Source app executable is missing: $SOURCE_APP"
    exit 66
fi
if ! "$CODESIGN_TOOL" --verify --deep --strict "$SOURCE_APP"; then
    print -u2 -- "Source app signature is invalid: $SOURCE_APP"
    exit 66
fi
source_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
source_ui_element="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$SOURCE_APP/Contents/Info.plist")"
if [[ "$source_bundle_id" != "$BUNDLE_ID" || "$source_ui_element" != "true" ]]; then
    print -u2 -- "Source app metadata is invalid: $SOURCE_APP"
    exit 66
fi

BACKUP_APP="$BACKUP_ROOT/会议录音-backup-$BACKUP_STAMP.app.backup"
FAILED_APP="$BACKUP_ROOT/会议录音-failed-$BACKUP_STAMP.app.backup"
suffix=2
while [[ -e "$BACKUP_APP" || -e "$FAILED_APP" ]]; do
    BACKUP_APP="$BACKUP_ROOT/会议录音-backup-$BACKUP_STAMP-v$suffix.app.backup"
    FAILED_APP="$BACKUP_ROOT/会议录音-failed-$BACKUP_STAMP-v$suffix.app.backup"
    (( suffix += 1 ))
done

print -- "Source: $SOURCE_APP"
print -- "Target: $TARGET_APP"

if (( DRY_RUN )); then
    if [[ -d "$TARGET_APP" ]]; then
        print -- "Dry run: would request normal app quit and preserve existing app as $BACKUP_APP"
    fi
    print -- "Dry run: would copy, verify, and launch $TARGET_APP"
    exit 0
fi

/bin/mkdir -p "$INSTALL_ROOT"
/bin/mkdir -p "$BACKUP_ROOT"
if [[ -e "$TARGET_APP" && ! -d "$TARGET_APP" ]]; then
    print -u2 -- "Install target exists but is not an app directory: $TARGET_APP"
    exit 67
fi

EXACT_EXECUTABLE="$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME"
matching_pids=()
for candidate_pid in ${(@f)"$("$PGREP_TOOL" -x "$EXECUTABLE_NAME" 2>/dev/null || true)"}; do
    [[ "$candidate_pid" == <-> ]] || continue
    candidate_executable="$("$PS_TOOL" -p "$candidate_pid" -o comm= 2>/dev/null || true)"
    candidate_executable="${candidate_executable#"${candidate_executable%%[![:space:]]*}"}"
    candidate_executable="${candidate_executable%"${candidate_executable##*[![:space:]]}"}"
    [[ "$candidate_executable" == "$EXACT_EXECUTABLE" ]] || continue
    matching_pids+=("$candidate_pid")
done

if (( ${#matching_pids} > 0 )); then
    print -- "Requesting normal quit for installed app PID(s): ${matching_pids[*]}"
    if [[ "$TEST_MODE" == "1" ]]; then
        [[ -n "$QUIT_TOOL" ]] || { print -u2 -- "Install test quit tool is required for a matching PID."; exit 68; }
        "$QUIT_TOOL" "$BUNDLE_ID"
    else
        "$QUIT_TOOL" \
            -e 'ignoring application responses' \
            -e "tell application id \"$BUNDLE_ID\" to quit" \
            -e 'end ignoring'
    fi

    for matching_pid in $matching_pids; do
        attempts=0
        while true; do
            running_executable="$("$PS_TOOL" -p "$matching_pid" -o comm= 2>/dev/null || true)"
            running_executable="${running_executable#"${running_executable%%[![:space:]]*}"}"
            running_executable="${running_executable%"${running_executable##*[![:space:]]}"}"
            [[ "$running_executable" == "$EXACT_EXECUTABLE" ]] || break
            if (( attempts >= QUIT_ATTEMPTS )); then
                print -u2 -- "Installed app PID $matching_pid did not quit normally. Stop recording and quit the app before installing; existing app was not moved."
                exit 68
            fi
            "$SLEEP_TOOL" 0.1
            (( attempts += 1 ))
        done
    done
fi

backup_made=0
install_succeeded=0

restore_previous_app() {
    local original_status=$?
    (( install_succeeded )) && return 0

    if [[ -e "$TARGET_APP" ]]; then
        if "$MV_TOOL" "$TARGET_APP" "$FAILED_APP"; then
            print -u2 -- "Preserved failed install at: $FAILED_APP"
        else
            print -u2 -- "Could not move failed install; it remains at: $TARGET_APP"
        fi
    fi

    if (( backup_made )); then
        if [[ ! -e "$TARGET_APP" ]] && "$MV_TOOL" "$BACKUP_APP" "$TARGET_APP"; then
            print -u2 -- "Restored previous app after install failure: $TARGET_APP"
        else
            print -u2 -- "Automatic restore could not replace the target; previous app remains safe at: $BACKUP_APP"
        fi
    elif [[ -e "$FAILED_APP" ]]; then
        print -u2 -- "No previous app existed; failed artifact remains at: $FAILED_APP"
    else
        print -u2 -- "No previous app existed; partial target remains at: $TARGET_APP"
    fi
    return "$original_status"
}
trap restore_previous_app EXIT INT HUP TERM

if [[ -d "$TARGET_APP" ]]; then
    "$MV_TOOL" "$TARGET_APP" "$BACKUP_APP"
    backup_made=1
    print -- "Preserved previous app at: $BACKUP_APP"
fi

"$DITTO_TOOL" "$SOURCE_APP" "$TARGET_APP"
"$CODESIGN_TOOL" --verify --deep --strict "$TARGET_APP"

installed_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")"
installed_ui_element="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$TARGET_APP/Contents/Info.plist")"
if [[ "$installed_bundle_id" != "$BUNDLE_ID" || "$installed_ui_element" != "true" ]]; then
    print -u2 -- "Installed app metadata verification failed."
    exit 69
fi

install_succeeded=1
trap - EXIT INT HUP TERM
"$OPEN_TOOL" "$TARGET_APP"
print -- "Installed and launched: $TARGET_APP"
