#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate

DERIVED="$ROOT/build"
rm -rf "$DERIVED"
mkdir -p "$DERIVED"

BUILD_FLAGS=(-configuration Release -sdk iphoneos -destination "generic/platform=iOS" "ARCHS=arm64 arm64e" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO BUILD_DIR="$DERIVED" -derivedDataPath "$DERIVED/DerivedData" build)

case "${DEBUG:-0}" in
  0)
    BUILD_FLAGS+=(CR4_DEBUG_LOGGING=0 CR4_SWIFT_LOGGING_CONDITION=)
    ;;
  1)
    BUILD_FLAGS+=(CR4_DEBUG_LOGGING=1 CR4_SWIFT_LOGGING_CONDITION=CR4_DEBUG_LOGGING)
    ;;
  *)
    echo "error: DEBUG must be 0 or 1" >&2
    exit 2
    ;;
esac

echo "=== Building Cr4shed App ==="
xcodebuild -project Cr4shed.xcodeproj -scheme Cr4shed "${BUILD_FLAGS[@]}"

for scheme in Cr4shedException Cr4shedMach Cr4shedJetsam cr4shedd; do
  echo "=== Building $scheme ==="
  xcodebuild -project Cr4shed.xcodeproj -scheme "$scheme" "${BUILD_FLAGS[@]}"
done

PROD="$DERIVED/Release-iphoneos"
STAGE="$ROOT/.package"
JB="$STAGE/var/jb"
rm -rf "$STAGE"

mkdir -p "$STAGE/DEBIAN"
mkdir -p "$JB/Applications"
mkdir -p "$JB/usr/libexec"
mkdir -p "$JB/Library/LaunchDaemons"
mkdir -p "$JB/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$JB/Library/libSandy"

cp -R "$ROOT/Sources/Packaging/layout/DEBIAN/." "$STAGE/DEBIAN/"
cp "$ROOT/Sources/Packaging/layout/Library/MobileSubstrate/DynamicLibraries/"*.plist "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$ROOT/Sources/Packaging/layout/Library/LaunchDaemons/"*.plist "$JB/Library/LaunchDaemons/"
cp "$ROOT/Sources/Packaging/layout/Library/libSandy/"*.plist "$JB/Library/libSandy/"

cp "$PROD/Cr4shedException.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$PROD/Cr4shedMach.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$PROD/Cr4shedJetsam.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/"
cp "$PROD/cr4shedd" "$JB/usr/libexec/cr4shedd"
cp -R "$PROD/Cr4shed.app" "$JB/Applications/Cr4shed.app"

for binary in \
  "$JB/usr/libexec/cr4shedd" \
  "$JB/Applications/Cr4shed.app/Cr4shed" \
  "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedException.dylib" \
  "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedMach.dylib" \
  "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedJetsam.dylib"; do
  if otool -L "$binary" | grep -Fq "/usr/lib/swift/libswiftXPC.dylib"; then
    echo "error: $binary must not depend on libswiftXPC.dylib" >&2
    exit 1
  fi
done

install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4shedException.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedException.dylib" || true
install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4shedMach.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedMach.dylib" || true
install_name_tool -id "/var/jb/Library/MobileSubstrate/DynamicLibraries/Cr4shedJetsam.dylib" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedJetsam.dylib" || true

ldid -S"$ROOT/Sources/Packaging/entitlements/cr4shedd.plist" "$JB/usr/libexec/cr4shedd"
ldid -S"$ROOT/Sources/Packaging/entitlements/app.plist" "$JB/Applications/Cr4shed.app/Cr4shed"
ldid -S"$ROOT/Sources/Packaging/entitlements/tweak.plist" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedException.dylib"
ldid -S"$ROOT/Sources/Packaging/entitlements/tweak.plist" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedMach.dylib"
ldid -S"$ROOT/Sources/Packaging/entitlements/tweak.plist" "$JB/Library/MobileSubstrate/DynamicLibraries/Cr4shedJetsam.dylib"

chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm" "$JB/usr/libexec/cr4shedd"

OUT="$ROOT/packages"
mkdir -p "$OUT"
DEB_NAME="com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb"
dpkg-deb -Zxz -b "$STAGE" "$OUT/$DEB_NAME"
echo "=== Successfully built: $OUT/$DEB_NAME ==="
