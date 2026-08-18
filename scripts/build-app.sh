#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PATH="${MEETING_RECORDER_BUILD_PATH:-$PROJECT_DIR/.build}"
BUILD_PRODUCTS_DIR="$BUILD_PATH/arm64-apple-macosx/release"
BUILD_DATE="$(/bin/date +%F)"
APP_BUNDLE="$PROJECT_DIR/dist/会议录音-${BUILD_DATE}.app"

if [[ "$BUILD_PATH" != "$PROJECT_DIR/.build" ]]; then
    env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        /usr/bin/xcrun swift build -c release --product MeetingRecorderApp --scratch-path "$BUILD_PATH"
else
    env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        /usr/bin/xcrun swift build -c release --product MeetingRecorderApp
fi

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/bin/cp "$BUILD_PRODUCTS_DIR/MeetingRecorderApp" "$APP_BUNDLE/Contents/MacOS/MeetingRecorderApp"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/AppIcon-2026-08-18.icns" "$APP_BUNDLE/Contents/Resources/AppIcon-2026-08-18.icns"

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
