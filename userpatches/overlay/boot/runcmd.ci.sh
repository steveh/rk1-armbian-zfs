#!/bin/sh
# First-boot script invoked by cloud-init from /boot/user-data.
# Runs on the eMMC image, prepares the system, then calls rootfs-to.sh
# to migrate to NVMe.
set -eu
PS4="runcmd.ci.sh: "
set -x

export DEBIAN_FRONTEND=noninteractive

# Make sure ZFS userspace + kernel module are present.
# (Image already has zfsutils-linux + zfs-dkms from build; this is a belt-and-braces install.)
apt-get install -y --no-install-recommends zfsutils-linux

# Ensure the running kernel has the module before we touch NVMe.
modprobe zfs

# Cleanup before potentially long-running migration.
apt-get clean

# If we are on eMMC and an NVMe is present, migrate.
ROOT_SRC="$(findmnt / -n -o SOURCE)"
case "$ROOT_SRC" in
  /dev/mmcblk0p*)
    if [ -b /dev/nvme0n1 ]; then
      sh /boot/rootfs-to.sh /dev/nvme0n1
      sync
      reboot
    fi
    ;;
esac
