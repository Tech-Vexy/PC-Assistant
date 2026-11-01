#!/bin/bash
set -e

# Build AppImage for Zen
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/build/linux/x64/release/bundle"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${ROOT_DIR}/build/AppDir"
APP_NAME="Zen"
ARCH="x86_64"

echo "=== Packaging ${APP_NAME} AppImage (${ARCH}) ==="

if [ ! -d "${BUNDLE_DIR}" ]; then
    echo "Error: Release bundle not found at ${BUNDLE_DIR}."
    echo "Run 'flutter build linux --release' first."
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/usr/bin"
mkdir -p "${APP_DIR}/usr/lib"
mkdir -p "${APP_DIR}/usr/share/applications"
mkdir -p "${APP_DIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${DIST_DIR}"

# 1. Copy bundle to AppDir
cp -r "${BUNDLE_DIR}/"* "${APP_DIR}/usr/bin/"
# Move shared libraries to usr/lib if any
if [ -d "${BUNDLE_DIR}/lib" ]; then
    cp -r "${BUNDLE_DIR}/lib/"* "${APP_DIR}/usr/lib/" 2>/dev/null || true
fi

# 2. Copy AppRun, desktop file, and icon
cp "${SCRIPT_DIR}/AppRun" "${APP_DIR}/AppRun"
chmod +x "${APP_DIR}/AppRun"

cp "${SCRIPT_DIR}/com.veldrine.zen_ai.desktop" "${APP_DIR}/com.veldrine.zen_ai.desktop"
cp "${SCRIPT_DIR}/com.veldrine.zen_ai.desktop" "${APP_DIR}/zen.desktop"

if [ -f "${ROOT_DIR}/assets/images/icon.png" ]; then
    cp "${ROOT_DIR}/assets/images/icon.png" "${APP_DIR}/zen.png"
    cp "${ROOT_DIR}/assets/images/icon.png" "${APP_DIR}/.DirIcon"
    cp "${ROOT_DIR}/assets/images/icon.png" "${APP_DIR}/usr/share/icons/hicolor/256x256/apps/zen.png"
fi

# 3. Check for appimagetool or download if missing
APPIMAGETOOL="${ROOT_DIR}/build/appimagetool"
if ! command -v appimagetool &> /dev/null; then
    if [ ! -f "${APPIMAGETOOL}" ]; then
        echo "Downloading appimagetool..."
        curl -sL "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${ARCH}.AppImage" -o "${APPIMAGETOOL}"
        chmod +x "${APPIMAGETOOL}"
    fi
    TOOL="${APPIMAGETOOL}"
else
    TOOL="appimagetool"
fi

# 4. Generate AppImage
echo "Executing appimagetool..."
ARCH="${ARCH}" "${TOOL}" --appimage-extract-and-run "${APP_DIR}" "${DIST_DIR}/${APP_NAME}-${ARCH}.AppImage"

echo "=== Successfully built AppImage: ${DIST_DIR}/${APP_NAME}-${ARCH}.AppImage ==="
