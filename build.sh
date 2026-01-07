#!/bin/bash

set -e

echo "Building SwitchBot CO₂ Menu Bar App..."

# Set build directory
BUILD_DIR="build"
APP_NAME="SwitchBotCO2"
BUNDLE_ID="com.switchbot.co2menubar"

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Create app bundle structure
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macos11.0"
else
    TARGET="x86_64-apple-macos11.0"
fi

echo "Building for architecture: $ARCH"

# Compile Swift files
echo "Compiling Swift files..."
swiftc \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -sdk $(xcrun --show-sdk-path --sdk macosx) \
    -target $TARGET \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreBluetooth \
    -framework Combine \
    -framework UserNotifications \
    SwitchBotData.swift \
    BluetoothManager.swift \
    StatusItemController.swift \
    MenuBarView.swift \
    SettingsView.swift \
    AppDelegate.swift \
    main.swift

echo "Creating app bundle..."

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy icon
if [ -f "SwitchBotCO2.icns" ]; then
    cp SwitchBotCO2.icns "$APP_BUNDLE/Contents/Resources/"
    echo "Icon added"
fi

# Copy alert sounds
if [ -f "air_quality_alert.aiff" ]; then
    cp air_quality_alert.aiff "$APP_BUNDLE/Contents/Resources/"
    echo "Gentle alert sound added"
fi

if [ -f "fire_alarm.aiff" ]; then
    cp fire_alarm.aiff "$APP_BUNDLE/Contents/Resources/"
    echo "Fire alarm sound added"
fi

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Sign the app (ad-hoc signing for development)
if command -v codesign &> /dev/null; then
    echo "Signing app..."
    codesign --force --deep --sign - --entitlements SwitchBotCO2.entitlements "$APP_BUNDLE"
fi

echo ""
echo "================================================"
echo "Build complete! App bundle: $APP_BUNDLE"
echo "================================================"
echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install to Applications:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
echo "Note: On first run, you may need to grant Bluetooth"
echo "permission in System Settings → Privacy & Security → Bluetooth"
echo ""
