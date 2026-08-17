#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"
APP_NAME="Piccolo"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "==> Cleaning previous build artifacts..."
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${DIST_DIR}" "${BUILD_DIR}"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building Release target..."
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}/Release" \
  CODE_SIGN_IDENTITY="Apple Development: ianrapko@comcast.net (9LCS964PD7)" \
  CODE_SIGN_STYLE="Manual" \
  build

APP_PATH="${BUILD_DIR}/Release/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "Error: ${APP_PATH} was not created." >&2
  exit 1
fi

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Creating Zip archive..."
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${DIST_DIR}/${ZIP_NAME}"

echo "==> Creating DMG staging directory..."
DMG_STAGING="${BUILD_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> Generating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DIST_DIR}/${DMG_NAME}"

echo ""
echo "======================================================="
echo "✅ Packaged successfully!"
echo "   DMG: ${DIST_DIR}/${DMG_NAME}"
echo "   ZIP: ${DIST_DIR}/${ZIP_NAME}"
echo "======================================================="
ls -lh "${DIST_DIR}"
