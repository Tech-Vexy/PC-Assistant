#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=========================================================="
echo "          Zen AI Linux Packaging Utility                  "
echo "=========================================================="

BUILD_RELEASE=true
BUILD_DEB=true
BUILD_APPIMAGE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            BUILD_RELEASE=false
            shift
            ;;
        --deb-only)
            BUILD_APPIMAGE=false
            shift
            ;;
        --appimage-only)
            BUILD_DEB=false
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--no-build] [--deb-only] [--appimage-only]"
            exit 1
            ;;
    esac
done

cd "${ROOT_DIR}"

if [ "$BUILD_RELEASE" = true ]; then
    echo "Building Flutter Linux release bundle..."
    flutter build linux --release
fi

if [ "$BUILD_DEB" = true ]; then
    bash "${SCRIPT_DIR}/build_deb.sh"
fi

if [ "$BUILD_APPIMAGE" = true ]; then
    bash "${SCRIPT_DIR}/build_appimage.sh"
fi

echo "All Linux packaging tasks completed! Outputs located in ${ROOT_DIR}/dist"
