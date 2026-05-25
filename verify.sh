#!/bin/bash
# Loop-mount a built Armbian .img and check the three things that commonly break
# the NVMe-migration flow:
#   1. U-Boot package path used by rootfs-to.sh exists
#   2. /boot/armbianEnv.txt contains a rootdev= line
#   3. cloud-init NoCloud seed location matches what customize-image.sh populates
#
# Usage: sudo ./verify.sh path/to/Armbian_*.img

set -eu

IMG="${1:?usage: $0 <image.img>}"
if [ ! -r "$IMG" ]; then
  echo "cannot read $IMG" >&2
  exit 1
fi

MNT="$(mktemp -d)"
BOOT_MNT="$(mktemp -d)"
LOOP=""

cleanup() {
  rc=$?
  trap '' EXIT
  mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT" || :
  mountpoint -q "$MNT" && umount "$MNT" || :
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || :
  rmdir "$BOOT_MNT" "$MNT" 2>/dev/null || :
  exit $rc
}
trap cleanup EXIT INT TERM

LOOP="$(losetup --show -fP "$IMG")"
echo "looped $IMG -> $LOOP"

# Armbian default: single-partition ext4 image; sometimes boot+root.
if [ -b "${LOOP}p2" ]; then
  ROOT_PART="${LOOP}p2"
  BOOT_PART="${LOOP}p1"
else
  ROOT_PART="${LOOP}p1"
  BOOT_PART=""
fi

mount -o ro "$ROOT_PART" "$MNT"
if [ -n "$BOOT_PART" ]; then
  mount -o ro "$BOOT_PART" "$BOOT_MNT"
  BOOT_DIR="$BOOT_MNT"
else
  BOOT_DIR="$MNT/boot"
fi

fail=0
check() {
  if eval "$2"; then
    printf "  ok   %s\n" "$1"
  else
    printf "  FAIL %s\n" "$1"
    fail=$((fail+1))
  fi
}

echo
echo "== 1. u-boot package present =="
UBOOT_PKG_DIR="$MNT/usr/lib/linux-u-boot-current-turing-rk1"
check "linux-u-boot-current-turing-rk1 installed" \
      "[ -d '$UBOOT_PKG_DIR' ]"
check "u-boot-rockchip.bin present" \
      "[ -f '$UBOOT_PKG_DIR/u-boot-rockchip.bin' ]"
echo "  found packages:"
ls -1 "$MNT/usr/lib/" 2>/dev/null | grep '^linux-u-boot-' | sed 's/^/    /' || \
  echo "    (none)"

echo
echo "== 2. armbianEnv.txt has rootdev= =="
if [ -f "$BOOT_DIR/armbianEnv.txt" ]; then
  check "rootdev= line present" \
        "grep -q '^rootdev=' '$BOOT_DIR/armbianEnv.txt'"
  echo "  current: $(grep '^rootdev=' "$BOOT_DIR/armbianEnv.txt" || echo '(none)')"
else
  echo "  FAIL  $BOOT_DIR/armbianEnv.txt missing"
  fail=$((fail+1))
fi

echo
echo "== 3. cloud-init NoCloud seed =="
check "zfsutils-linux installed" \
      "[ -x '$MNT/sbin/zpool' ] || [ -x '$MNT/usr/sbin/zpool' ]"
check "zfs DKMS module built" \
      "compgen -G '$MNT/lib/modules/*/updates/dkms/zfs.ko*' >/dev/null \
       || compgen -G '$MNT/lib/modules/*/extra/zfs.ko*' >/dev/null"

# Where will cloud-init look for user-data?
# Armbian's cloud-init extension typically configures NoCloud with seedfrom=/boot/
echo "  cloud.cfg.d entries referencing nocloud / seedfrom:"
grep -lrE 'NoCloud|seedfrom|/boot/' "$MNT/etc/cloud/cloud.cfg.d/" 2>/dev/null \
  | sed 's/^/    /' || echo "    (none)"

check "/boot/user-data placed by customize-image.sh" \
      "[ -f '$BOOT_DIR/user-data' ]"
check "/boot/meta-data placed" \
      "[ -f '$BOOT_DIR/meta-data' ]"
check "/boot/runcmd.ci.sh placed and executable" \
      "[ -x '$BOOT_DIR/runcmd.ci.sh' ]"
check "/boot/rootfs-to.sh placed and executable" \
      "[ -x '$BOOT_DIR/rootfs-to.sh' ]"

echo
if [ "$fail" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fail check(s) failed"
  exit 1
fi
