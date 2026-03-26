#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_NAME="TypeFlow"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/App/Info.plist" 2>/dev/null || echo "0.0.0")
echo "Building ${APP_NAME} v${VERSION}..."

# Build whisper.cpp static libraries if needed (handles commit hash + library checks)
"$ROOT_DIR/scripts/build_whisper.sh"

# Generate app icon if not cached
ICON_PATH="$ROOT_DIR/App/AppIcon.icns"
if [ ! -f "$ICON_PATH" ]; then
    echo "Generating app icon..."
    ICONSET_PATH="/tmp/TypeFlow.iconset"
    rm -rf "$ICONSET_PATH"
    if swiftc -o /tmp/typeflow_icongen "$ROOT_DIR/scripts/create_icon.swift" 2>/dev/null; then
        /tmp/typeflow_icongen "$ICONSET_PATH"
        if iconutil -c icns "$ICONSET_PATH" -o "$ICON_PATH" 2>/dev/null; then
            echo "Icon generated: $ICON_PATH"
        else
            echo "Warning: iconutil failed, skipping icon"
        fi
        rm -rf "$ICONSET_PATH" /tmp/typeflow_icongen
    else
        echo "Warning: Could not compile icon generator, skipping icon"
    fi
fi

mkdir -p "$ROOT_DIR/dist"

swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

# Copy icon if available
if [ -f "$ICON_PATH" ]; then
    cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
fi

chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$APP_DIR"
fi

# Install to /Applications (update in place), then remove dist copy
# to avoid duplicate Spotlight entries.
INSTALL_DIR="/Applications/${APP_NAME}.app"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi
cp -R "$APP_DIR" "$INSTALL_DIR"
rm -rf "$APP_DIR"

echo "Installed $INSTALL_DIR (v${VERSION})"
