#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

DERIVED="$ROOT/build"
rm -rf "$DERIVED"
mkdir -p "$DERIVED"

BUILD_FLAGS=(-configuration Release -sdk iphoneos -destination "generic/platform=iOS" "ARCHS=arm64 arm64e" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO BUILD_DIR="$DERIVED" -derivedDataPath "$DERIVED/DerivedData" build)

xcodebuild -project Cr4shed.xcodeproj -scheme Cr4shed "${BUILD_FLAGS[@]}"

for scheme in Cr4shedException Cr4shedMach Cr4shedJetsam cr4shedd; do
  xcodebuild -project Cr4shed.xcodeproj -scheme "$scheme" "${BUILD_FLAGS[@]}"
done

PROD="$DERIVED/Release-iphoneos"
STAGE="$ROOT/.package"
JB="$STAGE/var/jb"
rm -rf "$STAGE"
mkdir -p "$JB/Library/MobileSubstrate/DynamicLibraries" "$JB/usr/libexec" "$JB/Applications" "$JB/Library/LaunchDaemons" "$JB/Library/libSandy" "$STAGE/DEBIAN"

cp -R "$ROOT/Sources/Packaging/layout/DEBIAN/." "$STAGE/DEBIAN/"
cp "$ROOT/Sources/Packaging/layout/Library/MobileSubstrate/DynamicLibraries/"*.plist "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$ROOT/Sources/Packaging/layout/Library/LaunchDaemons/"*.plist "$JB/Library/LaunchDaemons/"
cp "$ROOT/Sources/Packaging/layout/Library/libSandy/"*.plist "$JB/Library/libSandy/"

install_dylib() {
  local name="$1"
  local src
  src="$(find "$DERIVED" -name "$name.dylib" ! -path "*.dSYM*" | head -n 1)"
  if [ -z "$src" ]; then
    echo "missing $name.dylib" >&2
    exit 1
  fi
  cp "$src" "$JB/Library/MobileSubstrate/DynamicLibraries/$name.dylib"
  install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/$name.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/$name.dylib" || true
}

install_dylib Cr4shedException
install_dylib Cr4shedMach
install_dylib Cr4shedJetsam

DAEMON="$(find "$DERIVED" -type f -name cr4shedd | head -n 1)"
cp "$DAEMON" "$JB/usr/libexec/cr4shedd"

APP="$(find "$DERIVED" -name Cr4shed.app -type d | head -n 1)"
cp -R "$APP" "$JB/Applications/Cr4shed.app"
cp "$ROOT/cr4shedgui/Resources/"AppIcon*.png "$JB/Applications/Cr4shed.app/" 2>/dev/null || true
cp "$ROOT/cr4shedgui/Resources/AppIcon60x60@2x.png" "$JB/Applications/Cr4shed.app/icon.png" 2>/dev/null || true
cp "$ROOT/cr4shedgui/Resources/AppIcon60x60@2x.png" "$JB/Applications/Cr4shed.app/AppIcon.png" 2>/dev/null || true
cp "$ROOT/cr4shedgui/Resources/AppIcon60x60@3x.png" "$JB/Applications/Cr4shed.app/icon@3x.png" 2>/dev/null || true

ldid -S"$ROOT/Sources/Packaging/entitlements/cr4shedd.plist" "$JB/usr/libexec/cr4shedd"
ldid -S"$ROOT/Sources/Packaging/entitlements/app.plist" "$JB/Applications/Cr4shed.app/Cr4shed"
ldid -S "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedException.dylib"
ldid -S "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedMach.dylib"
ldid -S "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedJetsam.dylib"

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm" "$JB/usr/libexec/cr4shedd"

OUT="$ROOT/packages"
mkdir -p "$OUT"
dpkg-deb -Zxz -b "$STAGE" "$OUT/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb"
echo "Built $OUT/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb"
