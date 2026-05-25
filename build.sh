#!/bin/sh
# Build Armbian Trixie image for Turing RK1 with ZFS on /srv.
# See README.md.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
ARMBIAN_BRANCH="${ARMBIAN_BRANCH:-v26.05}"

if [ ! -d "$BUILD_DIR/.git" ]; then
  git clone --branch="$ARMBIAN_BRANCH" --depth=1 \
    https://github.com/armbian/build "$BUILD_DIR"
fi

# Sync our userpatches into the build tree (Armbian reads from build/userpatches/).
rm -rf "$BUILD_DIR/userpatches"
cp -a "$HERE/userpatches" "$BUILD_DIR/userpatches"

# If secrets.env exists, stage it into the overlay so customize-image.sh can read it.
# secrets.env is gitignored and not part of userpatches/. See secrets.env.example.
if [ -f "$HERE/secrets.env" ]; then
  cp "$HERE/secrets.env" "$BUILD_DIR/userpatches/overlay/secrets.env"
  chmod 0600 "$BUILD_DIR/userpatches/overlay/secrets.env"
  echo "build.sh: staged secrets.env into overlay"
else
  echo "build.sh: no secrets.env found; image will have no preseeded user/ssh keys" >&2
fi

cd "$BUILD_DIR"
exec ./compile.sh build rk1
