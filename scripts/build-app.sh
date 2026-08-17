#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PRODUCTS_DIR="$PROJECT_DIR/.build/release"
BUILD_DATE="$(/bin/date +%F)"
APP_BUNDLE="$PROJECT_DIR/dist/会议录音-${BUILD_DATE}.app"

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift build -c release --product MeetingRecorderApp

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/bin/cp "$BUILD_PRODUCTS_DIR/MeetingRecorderApp" "$APP_BUNDLE/Contents/MacOS/MeetingRecorderApp"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
