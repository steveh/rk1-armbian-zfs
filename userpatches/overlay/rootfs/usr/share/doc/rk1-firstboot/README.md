# RK1 firstboot / migration notes

Built from https://github.com/.../rk1-armbian-zfs (Armbian build framework,
`BRANCH=vendor`, Debian Trixie userspace, ZFS on `/srv`).

## Where am I booted from?

```
findmnt /
```

- `/dev/mmcblk0p2` → booted from eMMC. Either this is first boot (migration
  is pending or running), or the BMC was switched back to eMMC for rescue.
- `/dev/nvme0n1p2` → booted from NVMe. Normal post-migration state.

## What happens on the first eMMC boot

1. cloud-init reads `/boot/{user-data,meta-data,network-config}` from the
   FAT boot partition (NoCloud datasource).
2. `user-data` declares the login user, hashed passwords, SSH keys.
3. The `runcmd` block backgrounds itself (detaches from `cloud-final.service`
   so it can outlive cloud-init), then:
   - waits for `cloud-final.service` to exit,
   - waits for the network to reach `deb.debian.org`,
   - runs `apt-get update`,
   - runs `/boot/runcmd.ci.sh`, which calls `/boot/rootfs-to.sh /dev/nvme0n1`.
4. `rootfs-to.sh`:
   - GPT partitions NVMe: `p1` 384M vfat `/boot`, `p2` 256G ext4 `/`,
     `p3` rest as ZFS pool `srv` mounted `/srv`.
   - tars the running rootfs to NVMe.
   - writes `/etc/fstab` with NVMe UUIDs.
   - rewrites `/boot/armbianEnv.txt` `rootdev=` to the NVMe root UUID.
   - creates `/etc/cloud/cloud-init.disabled` on the NVMe target.
   - `dd`s `u-boot-rockchip.bin` to NVMe at sector 64.
   - syncs and exits; the outer script reboots.

Elapsed time: ~2–5 minutes depending on rootfs size and NVMe speed.

## Where the logs are

| Log | Path | Notes |
|-----|------|-------|
| Background firstboot wrapper | `/var/log/rk1-firstboot.log` | The detached runcmd writes here. |
| Migration script (xtrace) | same file | `runcmd.ci.sh` / `rootfs-to.sh` run with `sh -eux`, output goes to the wrapper log. |
| cloud-init | `/var/log/cloud-init.log`, `/var/log/cloud-init-output.log` | Cloud-init's own log; runcmd appears here but exits in milliseconds because the work is backgrounded. |

After migration these logs exist on **both** the eMMC and NVMe roots
(`rootfs-to.sh` tars them across). To read the eMMC copy from the
NVMe-booted system:

```
sudo mkdir -p /mnt/emmc
sudo mount /dev/mmcblk0p2 /mnt/emmc
ls /mnt/emmc/var/log/rk1-firstboot.log
```

## How to re-trigger migration

The migration is idempotent: it skips repartitioning if NVMe `p2` already
contains an ext4 filesystem that mounts cleanly. To force a fresh migration,
wipe NVMe first:

```
sudo wipefs -af /dev/nvme0n1
sudo blkdiscard -f /dev/nvme0n1
sudo reboot
```

If you are already booted from NVMe and just want to re-flash the eMMC
image, use the BMC to flash a new image to the eMMC slot.

## Subsequent eMMC boots (rescue mode)

The eMMC retains the original image. Selecting eMMC as the boot source in
the Turing Pi BMC will boot it. cloud-init will re-run unless you previously
disabled it on the eMMC root (`touch /etc/cloud/cloud-init.disabled` while
the eMMC is mounted).

If cloud-init re-runs from a rescue eMMC boot it will re-execute the
migration. To prevent that while keeping eMMC bootable for rescue:

```
sudo mkdir -p /mnt/emmc
sudo mount /dev/mmcblk0p2 /mnt/emmc
sudo touch /mnt/emmc/etc/cloud/cloud-init.disabled
sudo umount /mnt/emmc
```

## Switching boot source on the BMC

From the Turing Pi 2 BMC web UI or `tpi`:

```
tpi power off -n <node>
tpi advanced msd -n <node>        # USB mass-storage mode for flashing
# or
tpi power on -n <node>
```

To change which device the node boots from, use the BMC's per-node boot
order configuration. Refer to Turing Pi docs.

## Disk layout reference

NVMe (`/dev/nvme0n1`):

| # | Range | Type | FS | Mount |
|---|-------|------|----|-------|
| – | 0–16 MiB | reserved | – | u-boot (`dd` at sector 64) |
| 1 | 384 MiB | EFI System | vfat | `/boot` |
| 2 | 256 GiB | Linux | ext4 | `/` |
| 3 | rest | Linux | zfs (pool `srv`) | `/srv` |

eMMC (`/dev/mmcblk0`): single-partition Armbian default; `/boot` is FAT
embedded in `mmcblk0p1`, root on `mmcblk0p2`.

## ZFS notes

- Pool name: `srv`. Single vdev: `nvme0n1p3`.
- Properties: `compression=zstd`, `recordsize=1M`, `xattr=off`,
  `atime=off`, `exec=off`, `setuid=off`, `devices=off`, `overlay=off`.
- Pool auto-imports via `zfs-import-cache.service` (cachefile at
  `/etc/zfs/zpool.cache`).
- Run `sudo zpool upgrade srv` to enable newer pool features. Optional.

## Versions

- Kernel: Rockchip BSP 6.1 (`vendor` branch). Required because OpenZFS 2.3
  in Trixie does not build against kernels newer than 6.14, and Armbian's
  `current` branch ships ≥6.18.
- Userspace: Debian Trixie, minimal server.
- ZFS: `zfsutils-linux` + `zfs-dkms` from Debian `contrib`.
