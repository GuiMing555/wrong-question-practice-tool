#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="${APP_VERSION:-1.3.1}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-39}"

CAPTURE_PRODUCT="WrongQuestionDailyOrganizer"
CAPTURE_DISPLAY_NAME="错题每日自动化整理"
CAPTURE_BUNDLE_ID="com.guiming.wrong-question-daily-organizer"

PRACTICE_PRODUCT="MedicalQuestionPractice"
PRACTICE_DISPLAY_NAME="错题刷题工具"
PRACTICE_BUNDLE_ID="com.guiming.medical-question-practice"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CAPTURE_BUNDLE="$DIST_DIR/$CAPTURE_DISPLAY_NAME.app"
PRACTICE_BUNDLE="$DIST_DIR/$PRACTICE_DISPLAY_NAME.app"

cd "$ROOT_DIR"
CIVIL_SERVICE_BUNDLE_READY=false
if [[ -n "${CIVIL_SERVICE_BANK_SOURCE:-}" ]]; then
  if [[ ! -f "$CIVIL_SERVICE_BANK_SOURCE" ]]; then
    echo "CIVIL_SERVICE_BANK_SOURCE 指向的文件不存在。" >&2
    exit 1
  fi
  python3 "$ROOT_DIR/script/build_civil_service_bank.py" \
    "$CIVIL_SERVICE_BANK_SOURCE" \
    "$ROOT_DIR/.build/civil-service-bank/questions.jsonl"
  CIVIL_SERVICE_BUNDLE_READY=true
else
  echo "未提供 CIVIL_SERVICE_BANK_SOURCE：开源构建不内置公务员题库数据。"
fi
swift build --configuration release
BUILD_DIR="$(swift build --configuration release --show-bin-path)"

stage_bundle() {
  local product="$1"
  local display_name="$2"
  local bundle_id="$3"
  local bundle_path="$4"
  local ui_element="$5"
  local copy_resources="$6"
  local contents="$bundle_path/Contents"
  local macos_dir="$contents/MacOS"
  local resources_dir="$contents/Resources"
  local executable="$macos_dir/$product"

  rm -rf "$bundle_path"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$BUILD_DIR/$product" "$executable"
  chmod +x "$executable"

  if [[ "$copy_resources" == "true" ]]; then
    cp -R "$ROOT_DIR/Resources/DocxFonts" "$resources_dir/DocxFonts"
  fi

  if [[ "$product" == "$PRACTICE_PRODUCT" && "$CIVIL_SERVICE_BUNDLE_READY" == "true" ]]; then
    mkdir -p "$resources_dir/CivilServiceQuestionBank"
    cp "$ROOT_DIR/.build/civil-service-bank/questions.jsonl" \
      "$resources_dir/CivilServiceQuestionBank/questions.jsonl"
  fi

  cat >"$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$product</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleName</key>
  <string>$display_name</string>
  <key>CFBundleDisplayName</key>
  <string>$display_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <$ui_element/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  # Public builds use an ad-hoc signature. No certificate, team identity,
  # provisioning profile, or Keychain signing material enters the bundle.
  /usr/bin/codesign --force --deep --sign - "$bundle_path" >/dev/null
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle_path"
  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
}

stage_bundle "$CAPTURE_PRODUCT" "$CAPTURE_DISPLAY_NAME" "$CAPTURE_BUNDLE_ID" "$CAPTURE_BUNDLE" true true
stage_bundle "$PRACTICE_PRODUCT" "$PRACTICE_DISPLAY_NAME" "$PRACTICE_BUNDLE_ID" "$PRACTICE_BUNDLE" false true

if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
  pkill -x "$CAPTURE_PRODUCT" >/dev/null 2>&1 || true
  pkill -x "WrongQuestionCapture" >/dev/null 2>&1 || true
  pkill -x "$PRACTICE_PRODUCT" >/dev/null 2>&1 || true
fi

open_capture() {
  /usr/bin/open -n "$CAPTURE_BUNDLE"
}

open_practice() {
  /usr/bin/open -n "$PRACTICE_BUNDLE"
}

install_bundles() {
  /usr/bin/ditto "$CAPTURE_BUNDLE" "/Applications/$CAPTURE_DISPLAY_NAME.app"
  /usr/bin/ditto "$PRACTICE_BUNDLE" "/Applications/$PRACTICE_DISPLAY_NAME.app"
}

verify_processes() {
  sleep 2
  pgrep -x "$CAPTURE_PRODUCT" >/dev/null
  pgrep -x "$PRACTICE_PRODUCT" >/dev/null
}

case "$MODE" in
  run)
    open_capture
    open_practice
    ;;
  --capture|capture)
    open_capture
    ;;
  --practice|practice)
    open_practice
    ;;
  --debug|debug)
    lldb -- "$PRACTICE_BUNDLE/Contents/MacOS/$PRACTICE_PRODUCT"
    ;;
  --logs|logs)
    open_capture
    open_practice
    /usr/bin/log stream --info --style compact --predicate "process == \"$CAPTURE_PRODUCT\" OR process == \"$PRACTICE_PRODUCT\""
    ;;
  --telemetry|telemetry)
    open_capture
    open_practice
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$CAPTURE_BUNDLE_ID\" OR subsystem == \"$PRACTICE_BUNDLE_ID\""
    ;;
  --verify|verify)
    open_capture
    open_practice
    verify_processes
    ;;
  --install|install)
    install_bundles
    ;;
  --install-verify|install-verify)
    install_bundles
    /usr/bin/open -n "/Applications/$CAPTURE_DISPLAY_NAME.app"
    /usr/bin/open -n "/Applications/$PRACTICE_DISPLAY_NAME.app"
    verify_processes
    ;;
  --build-only|build-only)
    ;;
  *)
    echo "usage: $0 [run|--capture|--practice|--debug|--logs|--telemetry|--verify|--install|--install-verify|--build-only]" >&2
    exit 2
    ;;
esac
