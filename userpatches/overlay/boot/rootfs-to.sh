#!/bin/sh
# Migrate the running eMMC rootfs to NVMe with layout:
#   p1  ext4   /boot   (BOOT_SIZE)
#   p2  ext4   /       (ROOT_SIZE)
#   p3  zfs    /srv    (pool name $SRV_POOL, dataset $SRV_POOL/srv)
# Then write u-boot to the NVMe and exit. Caller reboots.
#
# Reserves $BOOT_OFFSET at the start of the disk for u-boot SPL/blobs.
# Re-runnable: if a ZFS pool with the right name already exists, do not wipe;
# otherwise repartition.
#
# Usage: rootfs-to.sh /dev/nvme0n1

set -eu
set -x

TARGET_DEV="$1"

# ---- tunables ---------------------------------------------------------------
BOOT_OFFSET=16M           # space reserved at start of disk for u-boot
BOOT_SIZE=384M
ROOT_SIZE=256G             # set blank to use whole rest; we want /srv too
SRV_POOL=srv

ROOT_DIR=/mnt
ROOT_OPTS=relatime
BOOT_OPTS="relatime,x-systemd.automount,x-systemd.idle-timeout=31"

# u-boot package: must match BRANCH= used at build time
UBOOT_DIR=/usr/lib/linux-u-boot-vendor-turing-rk1
# -----------------------------------------------------------------------------

# partition device suffix: nvme0n1 -> p1, sda -> 1
case "$TARGET_DEV" in
  *[0-9]) PART_SEP=p ;;
  *)      PART_SEP=  ;;
esac
BOOT_DEV="${TARGET_DEV}${PART_SEP}1"
ROOT_DEV="${TARGET_DEV}${PART_SEP}2"
SRV_DEV="${TARGET_DEV}${PART_SEP}3"

cleanup() {
  rs=$?
  trap '' EXIT
  for m in "$ROOT_DIR/srv" "$ROOT_DIR/boot" "$ROOT_DIR/mnt" "$ROOT_DIR"; do
    while umount "$m" 2>/dev/null; do :; done
  done
  zpool export "$SRV_POOL" 2>/dev/null || :
  exit $rs
}
trap cleanup EXIT INT TERM

# ---- detect existing layout (idempotency) -----------------------------------
WIPE=yes
if [ -b "$ROOT_DEV" ] && mount -t ext4 "$ROOT_DEV" "$ROOT_DIR" 2>/dev/null; then
  WIPE=no
  umount "$ROOT_DIR"
fi

if [ "$WIPE" = yes ]; then
  # Wipe and partition.
  blkdiscard -f "$TARGET_DEV" 2>/dev/null || :
  wipefs -af "${TARGET_DEV}${PART_SEP}"* 2>/dev/null || :
  wipefs -af "$TARGET_DEV"
  ( echo "label: gpt"
    echo "${BOOT_OFFSET},${BOOT_SIZE},U"     # EFI System, /boot
    echo ",${ROOT_SIZE},L"                    # Linux, /
    echo ",,L"                                # Linux, /srv (zfs)
  ) | sfdisk "$TARGET_DEV"
  udevadm trigger
  udevadm settle

  mkfs.ext4 -F "$BOOT_DEV"
  mkfs.ext4 -F "$ROOT_DEV"
fi

BOOT_UUID="$(blkid -o value -s UUID "$BOOT_DEV")"
ROOT_UUID="$(blkid -o value -s UUID "$ROOT_DEV")"

# ---- mount target rootfs ----------------------------------------------------
mount "$ROOT_DEV" "$ROOT_DIR" -o "$ROOT_OPTS"
mkdir -p "$ROOT_DIR/boot"
mount "$BOOT_DEV" "$ROOT_DIR/boot"

# ---- copy rootfs ------------------------------------------------------------
# One filesystem, then explicitly add /boot and /dev which are separate mounts.
tar cf - --one-file-system --acls --xattrs --numeric-owner -C / . ./boot ./dev \
  | tar xf - --acls --xattrs --numeric-owner -C "$ROOT_DIR"

# ---- ZFS pool for /srv ------------------------------------------------------
mkdir -p "$ROOT_DIR/srv"
modprobe zfs

if ! zpool import -N -R "$ROOT_DIR" "$SRV_POOL" 2>/dev/null; then
  zpool create "$SRV_POOL" \
    -R "$ROOT_DIR" \
    -o autotrim=on \
    -O atime=off \
    -O relatime=off \
    -O exec=off \
    -O setuid=off \
    -O devices=off \
    -O xattr=off \
    -O overlay=off \
    -O compression=zstd \
    -O recordsize=1M \
    -O mountpoint=/srv \
    "$SRV_DEV"
fi

# Make the pool auto-import on the migrated system.
mkdir -p "$ROOT_DIR/etc/zfs"
zpool set cachefile=/etc/zfs/zpool.cache "$SRV_POOL"
cp -a /etc/zfs/zpool.cache "$ROOT_DIR/etc/zfs/zpool.cache"
# zfs-import-cache.service is enabled by default with zfsutils-linux; just confirm.
chroot "$ROOT_DIR" systemctl enable zfs-import-cache.service zfs-mount.service zfs.target 2>/dev/null || :

zpool export "$SRV_POOL"

# ---- /etc/fstab on target ---------------------------------------------------
cat > "$ROOT_DIR/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 $ROOT_OPTS 0 1
UUID=$BOOT_UUID /boot ext4 $BOOT_OPTS 0 2
tmpfs /tmp tmpfs mode=1777,nosuid 0 0
EOF
# /srv is managed by ZFS (mountpoint property), not fstab.

# ---- armbianEnv.txt: rootdev to NVMe ---------------------------------------
sed -i -r "s|^rootdev=.*|rootdev=UUID=$ROOT_UUID|" "$ROOT_DIR/boot/armbianEnv.txt"

# ---- disable cloud-init on the migrated system (NVMe boot is final) --------
mkdir -p "$ROOT_DIR/etc/cloud"
echo "disabled by rootfs-to.sh after NVMe install" \
  > "$ROOT_DIR/etc/cloud/cloud-init.disabled"

# ---- runtime dirs -----------------------------------------------------------
for d in tmp var/tmp run; do
  rm -rf "$ROOT_DIR/$d"
  mkdir -p "$ROOT_DIR/$d"
  chmod 1777 "$ROOT_DIR/$d" 2>/dev/null || chmod 0755 "$ROOT_DIR/$d"
done

# ---- write u-boot to NVMe ---------------------------------------------------
if [ -f "$UBOOT_DIR/u-boot-rockchip.bin" ]; then
  dd if="$UBOOT_DIR/u-boot-rockchip.bin" of="$TARGET_DEV" \
     bs=32k seek=1 conv=notrunc status=none
else
  echo "ERROR: $UBOOT_DIR/u-boot-rockchip.bin not found" >&2
  echo "Adjust UBOOT_DIR in rootfs-to.sh to match installed linux-u-boot-* package." >&2
  exit 1
fi

sync
