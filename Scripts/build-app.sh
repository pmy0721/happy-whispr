#!/bin/bash
set -euo pipefail

# Happy Whispr — Build & Package Script
# Creates a .app bundle from the SPM build output

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Happy Whispr"
BINARY_NAME="HappyWhispr"
BUILD_DIR="$PROJECT_DIR/.build/debug"
APP_DIR="$PROJECT_DIR/.build/$APP_NAME.app"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ICON_FILE="$RESOURCES_DIR/AppIcon.icns"

echo "=== Happy Whispr Build Script ==="

# Step 1: Build the Swift binary
echo "[1/4] Building Swift binary..."
cd "$PROJECT_DIR"
swift build

# Step 2: Create .app bundle structure
echo "[2/4] Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Step 3: Copy binary and Info.plist
echo "[3/4] Copying files..."
cp "$BUILD_DIR/$BINARY_NAME" "$APP_DIR/Contents/MacOS/"
cp "$RESOURCES_DIR/Info.plist" "$APP_DIR/Contents/"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "Warning: app icon not found at $ICON_FILE"
fi

# Step 4: Sign (ad-hoc) and report
echo "[4/4] Ad-hoc signing..."
codesign --force --deep -s - "$APP_DIR" 2>/dev/null || true

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_DIR"
echo "To run: open '$APP_DIR'"
echo ""
echo "⚠️  First launch: grant Accessibility and Microphone permissions in System Settings."
