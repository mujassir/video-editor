#!/bin/zsh
# Captures App Store screenshots on the iPhone 6.9" and iPad 13" simulators.
#   tools/screenshots/capture.sh <output-folder>
# Needs Xcode, xcodegen, and the simulators "iPhone 17 Pro Max" and "iPad Pro 13-inch (M5)".
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?output folder}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
mkdir -p "$OUT"

xcrun swift tools/screenshots/make-footage.swift "$WORK/footage"
xcodegen generate >/dev/null

for SIM in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  UDID=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  xcrun simctl ui "$UDID" appearance dark
  for svc in photos photos-add speech-recognition; do
    xcrun simctl privacy "$UDID" grant $svc com.mujassir.cutnweld 2>/dev/null || true
  done
  TEST_RUNNER_SCREENSHOT_DIR="$OUT" TEST_RUNNER_DEMO_MEDIA="$WORK/footage" \
  xcodebuild test -project Cutline.xcodeproj -scheme Cutline \
    -only-testing:CutlineUITests/AppStoreScreenshotUITests \
    -destination "id=$UDID" -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO 2>&1 \
    | grep -E "error:|Test Case|passed|failed|\*\* " || true
  xcrun simctl status_bar "$UDID" clear
done
ls -la "$OUT"
