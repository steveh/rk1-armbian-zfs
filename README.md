# RK1 Armbian — Debian Trixie, NVMe, ZFS on /srv

Builds an Armbian image for the Turing Pi 2 RK1 module:

- Debian Trixie userspace, minimal (server, no desktop).
- Rockchip BSP kernel (`BRANCH=vendor`, 6.1.x). Required because OpenZFS 2.3.x (shipped by Trixie) supports kernels up to 6.14 only; mainline `BRANCH=current` on RK3588 currently delivers 6.18.
- ZFS DKMS module + userspace, built into the image.
- First boot from eMMC runs cloud-init, which migrates the system to NVMe with a custom partition layout (ext4 `/boot`, ext4 `/`, ZFS pool on `/srv`), writes U-Boot to the NVMe, then reboots.
- eMMC is left untouched as a rescue: re-select eMMC in the BMC to boot the original image. If you boot eMMC again, cloud-init re-runs and re-migrates (idempotent).

Inspired by https://github.com/j0ju/sbc-fw-alchemy (`docs/TuringPi2-Alpine/RK1-Armbian`).

## Layout

```
build.sh                    # entry point; clones armbian/build and runs compile.sh
userpatches/
  config-rk1.conf           # all compile.sh switches
  customize-image.sh        # runs in chroot at end of rootfs build; copies cloud-init files into image
  cloud-init/
    user-data               # cloud-init user-data: runs runcmd.ci.sh
    meta-data
    network-config          # DHCP on eth0
  overlay/
    boot/
      runcmd.ci.sh          # first-boot script: apt update/install, then call rootfs-to.sh
      rootfs-to.sh          # repartition NVMe, copy rootfs, set up ZFS pool, write u-boot
```

## Usage

```
./build.sh
```

Output image: `build/output/images/Armbian_*_Turing-rk1_trixie_current_*.img.xz`.

Flash to eMMC via the Turing Pi BMC, boot RK1, watch the serial console — cloud-init runs, migration completes, board reboots to NVMe.

## Requirements

Per https://docs.armbian.com/Developer-Guide_Build-Preparation/ :

- Ubuntu Noble 24.04 host (or any Docker-capable Linux; build uses Docker by default).
- ≥8 GB RAM, ~50 GB free disk.
- sudo / root.

## Partition layout (NVMe)

| # | Size       | Type        | FS    | Mount  |
|---|------------|-------------|-------|--------|
| - | 0–16 MiB   | reserved    | -     | U-Boot |
| 1 | 384 MiB    | EFI System  | ext4  | /boot  |
| 2 | 16 GiB     | Linux       | ext4  | /      |
| 3 | rest       | Linux       | zfs   | (pool `srv`, mounted /srv) |

Adjust sizes at the top of `userpatches/overlay/boot/rootfs-to.sh`.

## Rescue

eMMC retains the original cloud-init image. To return to it:

1. Use the Turing Pi BMC to select eMMC as the boot source for this node.
2. The board boots the eMMC image. Cloud-init will re-run unless you previously `touch /etc/cloud/cloud-init.disabled` on eMMC.

## Branch choice

`BRANCH=vendor` — Rockchip BSP kernel 6.1 (`rk-6.1-rkr5.1`, packaged by Armbian from `armbian/linux-rockchip`).

Why not `current`? On Armbian `v25.11`, RK3588 `current` ships a 6.18 mainline kernel. OpenZFS 2.3.2 (Trixie's version) refuses to build on kernels newer than 6.14:

```
configure: error:
    *** Cannot build against kernel version 6.18.10-current-rockchip64.
    *** The maximum supported kernel version is 6.14.
```

`vendor` 6.1 falls inside the supported range, has full RK3588 hardware support, and is the practical pairing with ZFS on Trixie today. To switch when a future Armbian release ships kernel ≤6.14 on `current` (or OpenZFS catches up), change `BRANCH` in `userpatches/config-rk1.conf` and the `UBOOT_DIR` package name in `userpatches/overlay/boot/rootfs-to.sh`.

Serial console: vendor branch uses `ttyS9 @ 115200` (current/edge use `ttyS0`). The board config (`config/boards/turing-rk1.csc` in armbian/build) sets this automatically.
