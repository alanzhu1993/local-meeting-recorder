#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
EXPECTED_TARGET="/Users/alan/Applications/会议录音.app"
INSTALL_DIR="${EXPECTED_TARGET:h}"
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

SOURCE_APP="$PROJECT_DIR/dist/会议录音-$BUILD_DATE.app"
SOURCE_APP="${SOURCE_APP:A}"
TARGET_APP="${EXPECTED_TARGET:A}"

if [[ "$TARGET_APP" != "$EXPECTED_TARGET" ]]; then
    print -u2 -- "Refusing unexpected install target: $TARGET_APP"
    exit 65
fi

# Validate the complete source before inspecting, stopping, or moving an installed app.
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 -- "Source app does not exist: $SOURCE_APP"
    exit 66
fi
if [[ ! -x "$SOURCE_APP/Contents/MacOS/MeetingRecorderApp" ]]; then
    print -u2 -- "Source app executable is missing: $SOURCE_APP"
    exit 66
fi
if ! /usr/bin/codesign --verify --deep --strict "$SOURCE_APP"; then
    print -u2 -- "Source app signature is invalid: $SOURCE_APP"
    exit 66
fi
source_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
source_ui_element="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$SOURCE_APP/Contents/Info.plist")"
if [[ "$source_bundle_id" != "com.alan.local-meeting-recorder" || "$source_ui_element" != "true" ]]; then
    print -u2 -- "Source app metadata is invalid: $SOURCE_APP"
    exit 66
fi

BACKUP_STAMP="$(/bin/date +%F-%H%M%S)"
BACKUP_APP="$INSTALL_DIR/会议录音-backup-$BACKUP_STAMP.app"
FAILED_APP="$INSTALL_DIR/会议录音-failed-$BACKUP_STAMP.app"
suffix=2
while [[ -e "$BACKUP_APP" || -e "$FAILED_APP" ]]; do
    BACKUP_APP="$INSTALL_DIR/会议录音-backup-$BACKUP_STAMP-v$suffix.app"
    FAILED_APP="$INSTALL_DIR/会议录音-failed-$BACKUP_STAMP-v$suffix.app"
    (( suffix += 1 ))
done

print -- "Source: $SOURCE_APP"
print -- "Target: $TARGET_APP"

if (( DRY_RUN )); then
    if [[ -d "$TARGET_APP" ]]; then
        print -- "Dry run: would preserve existing app as $BACKUP_APP"
    fi
    print -- "Dry run: would copy, verify, and launch $TARGET_APP"
    exit 0
fi

/bin/mkdir -p "$INSTALL_DIR"
if [[ -e "$TARGET_APP" && ! -d "$TARGET_APP" ]]; then
    print -u2 -- "Install target exists but is not an app directory: $TARGET_APP"
    exit 67
fi

EXACT_EXECUTABLE="$TARGET_APP/Contents/MacOS/MeetingRecorderApp"
stopped_pids=()
for candidate_pid in ${(@f)"$(/usr/bin/pgrep -x MeetingRecorderApp 2>/dev/null || true)"}; do
    [[ "$candidate_pid" == <-> ]] || continue
    candidate_executable="$(/bin/ps -p "$candidate_pid" -o comm= 2>/dev/null || true)"
    candidate_executable="${candidate_executable#"${candidate_executable%%[![:space:]]*}"}"
    candidate_executable="${candidate_executable%"${candidate_executable##*[![:space:]]}"}"
    [[ "$candidate_executable" == "$EXACT_EXECUTABLE" ]] || continue

    print -- "Stopping installed app PID $candidate_pid ($candidate_executable)"
    /bin/kill -TERM "$candidate_pid"
    stopped_pids+=("$candidate_pid")
done

for stopped_pid in $stopped_pids; do
    attempts=0
    while /bin/kill -0 "$stopped_pid" 2>/dev/null; do
        if (( attempts >= 50 )); then
            print -u2 -- "Installed app PID $stopped_pid did not stop; existing app was not moved."
            exit 68
        fi
        /bin/sleep 0.1
        (( attempts += 1 ))
    done
done

backup_made=0
install_succeeded=0

restore_previous_app() {
    local original_status=$?
    (( install_succeeded )) && return 0

    if (( backup_made )); then
        if [[ -e "$TARGET_APP" ]]; then
            if /bin/mv "$TARGET_APP" "$FAILED_APP"; then
                print -u2 -- "Preserved failed install at: $FAILED_APP"
            else
                print -u2 -- "Could not move failed install; previous app remains safe at: $BACKUP_APP"
                return "$original_status"
            fi
        fi
        if [[ ! -e "$TARGET_APP" ]] && /bin/mv "$BACKUP_APP" "$TARGET_APP"; then
            print -u2 -- "Restored previous app after install failure: $TARGET_APP"
        else
            print -u2 -- "Automatic restore failed; previous app remains at: $BACKUP_APP"
        fi
    else
        print -u2 -- "Install failed; there was no previous app to restore."
    fi
    return "$original_status"
}
trap restore_previous_app EXIT

if [[ -d "$TARGET_APP" ]]; then
    /bin/mv "$TARGET_APP" "$BACKUP_APP"
    backup_made=1
    print -- "Preserved previous app at: $BACKUP_APP"
fi

/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"

installed_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")"
installed_ui_element="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$TARGET_APP/Contents/Info.plist")"
if [[ "$installed_bundle_id" != "com.alan.local-meeting-recorder" || "$installed_ui_element" != "true" ]]; then
    print -u2 -- "Installed app metadata verification failed."
    exit 69
fi

install_succeeded=1
trap - EXIT
/usr/bin/open "$TARGET_APP"
print -- "Installed and launched: $TARGET_APP"
