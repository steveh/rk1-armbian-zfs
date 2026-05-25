#!/bin/bash
# Armbian userpatches/customize-image.sh
# Runs in the image chroot at the end of rootfs build.
# https://docs.armbian.com/Developer-Guide_User-Configurations/

set -eu

# RELEASE, LINUXFAMILY, BRANCH, BOARD, BUILD_DESKTOP are exported by the framework.

# The cloud-init extension already drops userpatches/cloud-init/{user-data,meta-data,network-config}
# into /boot. We additionally need /boot/runcmd.ci.sh and /boot/rootfs-to.sh, which user-data
# references.

OVERLAY_SRC=/tmp/overlay
if [ -d "$OVERLAY_SRC" ]; then
  cp -av "$OVERLAY_SRC"/boot/. /boot/
  chmod 0755 /boot/runcmd.ci.sh /boot/rootfs-to.sh
fi

# Install ZFS userspace + initramfs hooks so the running image can `zpool create` on first boot.
# The `zfs` extension installs zfs-dkms; we add zfsutils-linux for the CLI.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends zfsutils-linux

# Ensure modules load when the image boots.
echo zfs > /etc/modules-load.d/zfs.conf

exit 0
