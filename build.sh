#!/bin/sh
# Build Armbian Trixie image for Turing RK1 with ZFS on /srv.
# See README.md.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-v25.11}"

if [ ! -d "$BUILD_DIR/.git" ]; then
  git clone --branch="$ARMBIAN_BRANCH" --depth=1 \
    https://github.com/armbian/build "$BUILD_DIR"
fi

# Sync our userpatches into the build tree (Armbian reads from build/userpatches/).
rm -rf "$BUILD_DIR/userpatches"
cp -a "$HERE/userpatches" "$BUILD_DIR/userpatches"

cd "$BUILD_DIR"
exec ./compile.sh build rk1
