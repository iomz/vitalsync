#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Vitalsync.xcodeproj"
SCHEME="Vitalsync"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedData}"

if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

DESTINATION="generic/platform=iOS"
if [[ -n "${DEVICE_ID:-}" ]]; then
  DESTINATION="platform=iOS,id=$DEVICE_ID"
elif [[ -n "${DEVICE_NAME:-}" ]]; then
  DESTINATION="platform=iOS,name=$DEVICE_NAME"
fi

SETTINGS=()
if [[ -n "${TEAM_ID:-}" ]]; then
  SETTINGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi
if [[ -n "${BUNDLE_ID:-}" ]]; then
  SETTINGS+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  "${SETTINGS[@]}" \
  build

APP_PATH="$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos" -maxdepth 1 -name 'Vitalsync.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "Built app not found under $DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos" >&2
  exit 1
fi

if [[ -n "${DEVICE_ID:-}" ]]; then
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
elif [[ -n "${DEVICE_NAME:-}" ]]; then
  xcrun devicectl device install app --device "$DEVICE_NAME" "$APP_PATH"
else
  echo "Build complete: $APP_PATH"
  echo "Set DEVICE_ID or DEVICE_NAME to install on iPhone."
fi
