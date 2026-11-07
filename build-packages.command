#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/NotifyDynamicX-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
XCODE_15_DEVELOPER_DIR="/Users/happy/Xcode.app/Contents/Developer"
XCODE_15_CLANG="$XCODE_15_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
BUILD_TARGET="iphone:clang:16.5:15.0"
BUILD_ARCHS="arm64 arm64e"

if [[ ! -x "$XCODE_15_CLANG" ]]; then
  echo "Xcode 15.4 toolchain not found at $XCODE_15_DEVELOPER_DIR" >&2
  exit 1
fi

export DEVELOPER_DIR="$XCODE_15_DEVELOPER_DIR"
XCODE_VERSION="$(/usr/bin/xcodebuild -version 2>/dev/null | sed -n '1p')"
CLANG_VERSION="$($XCODE_15_CLANG --version 2>/dev/null | sed -n '1p')"
if [[ "$XCODE_VERSION" != "Xcode 15.4" || "$CLANG_VERSION" != "Apple clang version 15.0.0"* ]]; then
  echo "Expected Xcode 15.4, found: $XCODE_VERSION / $CLANG_VERSION" >&2
  exit 1
fi

echo "==> Using required Xcode toolchain:"
/usr/bin/xcodebuild -version
echo "$CLANG_VERSION"

rsync -a --delete \
  --exclude ".theos" \
  --exclude ".clang-module-cache" \
  --exclude "packages" \
  --exclude "work" \
  "$PROJECT_DIR/" "$BUILD_DIR/"

cd "$BUILD_DIR"

mkdir -p "$BUILD_DIR/.clang-module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/.clang-module-cache"

build_package() {
  local scheme="$1"
  local theos_dir="$2"
  local package_version
  package_version="$(awk '/^Version:/ { print $2; exit }' control)"

  if [[ ! -d "$theos_dir" ]]; then
    echo "THEOS directory not found for $scheme: $theos_dir" >&2
    exit 1
  fi

  echo
  echo "==> Building $scheme ($BUILD_ARCHS) with THEOS=$theos_dir TARGET=$BUILD_TARGET"
  THEOS="$theos_dir" make clean package \
    FINALPACKAGE=1 \
    THEOS_PACKAGE_SCHEME="$scheme" \
    ARCHS="$BUILD_ARCHS" \
    PACKAGE_VERSION="$package_version" \
    TARGET="$BUILD_TARGET"
}

build_package rootless "/Users/happy/theos"
build_package roothide "/Users/happy/theos2"

ROOTLESS_PACKAGES=("$BUILD_DIR"/packages/*_iphoneos-arm64.deb(N))
ROOTHIDE_PACKAGES=("$BUILD_DIR"/packages/*_iphoneos-arm64e.deb(N))
if (( ${#ROOTLESS_PACKAGES[@]} == 0 || ${#ROOTHIDE_PACKAGES[@]} == 0 )); then
  echo "Expected both Rootless and RootHide DEB packages, but one or both are missing" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/packages"
find "$PROJECT_DIR/packages" -maxdepth 1 -type f -name "*.deb" -delete
cp -f "${ROOTLESS_PACKAGES[@]}" "${ROOTHIDE_PACKAGES[@]}" "$PROJECT_DIR/packages/"

echo
echo "Done. Packages are in:"
ls -lt "$PROJECT_DIR"/packages/*.deb 2>/dev/null | head -n 10 || true
