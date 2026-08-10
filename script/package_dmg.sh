#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.3.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CAPTURE_APP="$DIST_DIR/错题每日自动化整理.app"
PRACTICE_APP="$DIST_DIR/考试题本练习.app"
OUTPUT="$DIST_DIR/medical-wrong-question-suite-macOS-arm64-v$VERSION.dmg"
STAGING_DIR="$(mktemp -d /private/tmp/medical-question-dmg.XXXXXX)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "当前脚本只打包 Apple 芯片版本。" >&2
  exit 1
fi

APP_VERSION="$VERSION" "$ROOT_DIR/script/build_and_run.sh" --build-only

/usr/bin/ditto "$CAPTURE_APP" "$STAGING_DIR/错题每日自动化整理.app"
/usr/bin/ditto "$PRACTICE_APP" "$STAGING_DIR/考试题本练习.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "医学题本与错题练习 $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT"

/usr/bin/hdiutil verify "$OUTPUT"
/usr/bin/shasum -a 256 "$OUTPUT"
