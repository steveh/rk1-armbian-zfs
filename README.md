# RK1 Armbian — Debian Trixie, NVMe, ZFS on /srv

Builds an Armbian image for the Turing Pi 2 RK1 module:

- Debian Trixie userspace, minimal (server, no desktop).
- Mainline kernel (`BRANCH=current`) with Armbian's RK3588 patches.
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

`BRANCH=current` (mainline LTS, e.g. 6.12) is used because:

- Trixie ships OpenZFS 2.3.x, which dropped 5.10 support; mainline 6.12 pairs cleanly.
- This is a server use case — no NPU/MPP/VPU dependency on Rockchip BSP.
- Closer to "stock Debian".

If a peripheral does not work on `current`, switch to `BRANCH=vendor` in `userpatches/config-rk1.conf` and change `linux-u-boot-current-turing-rk1` → `linux-u-boot-vendor-turing-rk1` in `rootfs-to.sh`.
