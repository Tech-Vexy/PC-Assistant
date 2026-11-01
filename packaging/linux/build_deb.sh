#!/bin/bash
set -e

# Build .deb package for Zen
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/build/linux/x64/release/bundle"
DIST_DIR="${ROOT_DIR}/dist"
PKG_NAME="zen-ai"
VERSION="1.0.0"
ARCH="amd64"
DEB_BUILD_DIR="${ROOT_DIR}/build/deb_dist"

echo "=== Building Debian package for ${PKG_NAME} v${VERSION} (${ARCH}) ==="

if [ ! -d "${BUNDLE_DIR}" ]; then
    echo "Error: Release bundle not found at ${BUNDLE_DIR}."
    echo "Run 'flutter build linux --release' first."
    exit 1
fi

rm -rf "${DEB_BUILD_DIR}"
mkdir -p "${DEB_BUILD_DIR}/DEBIAN"
mkdir -p "${DEB_BUILD_DIR}/usr/lib/${PKG_NAME}"
mkdir -p "${DEB_BUILD_DIR}/usr/bin"
mkdir -p "${DEB_BUILD_DIR}/usr/share/applications"
mkdir -p "${DEB_BUILD_DIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${DIST_DIR}"

# 1. Copy bundle contents to /usr/lib/zen-ai/
cp -r "${BUNDLE_DIR}/"* "${DEB_BUILD_DIR}/usr/lib/${PKG_NAME}/"

# 2. Create launcher script in /usr/bin/zen
cat << 'EOF' > "${DEB_BUILD_DIR}/usr/bin/zen"
#!/bin/sh
exec /usr/lib/zen-ai/zen "$@"
EOF
chmod +x "${DEB_BUILD_DIR}/usr/bin/zen"

# 3. Copy desktop entry & icons
cp "${SCRIPT_DIR}/com.veldrine.zen_ai.desktop" "${DEB_BUILD_DIR}/usr/share/applications/com.veldrine.zen_ai.desktop"
if [ -f "${ROOT_DIR}/assets/images/icon.png" ]; then
    cp "${ROOT_DIR}/assets/images/icon.png" "${DEB_BUILD_DIR}/usr/share/icons/hicolor/256x256/apps/zen.png"
fi

# 4. Generate DEBIAN/control file
cat << EOF > "${DEB_BUILD_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: libc6, libgtk-3-0, libsqlite3-0, libglib2.0-0
Recommends: xdotool, wmctrl
Maintainer: Veldrine <dev@zen.ai>
Description: Zen - Cross-Platform On-Device AI Assistant
 Zen is an on-device intelligent assistant integrating low-latency multimodal
 speech-to-speech with Gemini Live, scheduled routines, privacy-shielded
 automation, and bidirectional PC bridging.
EOF

# 5. Build .deb package
dpkg-deb --build "${DEB_BUILD_DIR}" "${DIST_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo "=== Successfully built Debian package: ${DIST_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb ==="
