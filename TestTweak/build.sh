#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

BUILD_DIR="$SCRIPT_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

TARGET_DYLIB="$SCRIPT_DIR/layout/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4CrashTest.dylib"

echo "Compiling Cr4CrashTest for arm64..."
clang -target arm64-apple-ios15.0 -isysroot "$SDK_PATH" -O2 -fobjc-arc -shared -framework Foundation -framework UIKit -framework CoreGraphics -install_name "/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4CrashTest.dylib" "$SCRIPT_DIR/Tweak.m" -o "$BUILD_DIR/Cr4CrashTest_arm64.dylib"

echo "Compiling Cr4CrashTest for arm64e..."
clang -target arm64e-apple-ios15.0 -isysroot "$SDK_PATH" -O2 -fobjc-arc -shared -framework Foundation -framework UIKit -framework CoreGraphics -install_name "/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4CrashTest.dylib" "$SCRIPT_DIR/Tweak.m" -o "$BUILD_DIR/Cr4CrashTest_arm64e.dylib"

echo "Creating Universal Mach-O..."
lipo -create "$BUILD_DIR/Cr4CrashTest_arm64.dylib" "$BUILD_DIR/Cr4CrashTest_arm64e.dylib" -output "$TARGET_DYLIB"

echo "Signing..."
ldid -S "$TARGET_DYLIB"

OUT_DIR="$ROOT_DIR/packages"
mkdir -p "$OUT_DIR"
DEB_PATH="$OUT_DIR/com.test.cr4crashtest_1.0.0_iphoneos-arm64.deb"

echo "Building deb package..."
dpkg-deb -Zxz -b "$SCRIPT_DIR/layout" "$DEB_PATH"

echo "Successfully built: $DEB_PATH"
