#!/bin/bash
# Armbian userpatches/customize-image.sh
# Runs in the image chroot at the end of rootfs build.
# https://docs.armbian.com/Developer-Guide_User-Configurations/

set -eu

# RELEASE, LINUXFAMILY, BRANCH, BOARD, BUILD_DESKTOP are exported by the framework.

OVERLAY_SRC=/tmp/overlay

# --- Render cloud-init user-data from template + secrets.env -------------------
# secrets.env is gitignored and only present if the operator created it locally;
# build.sh stages it into the overlay. If absent, placeholders remain and the
# image boots with no preseeded login.

TMPL="$OVERLAY_SRC/boot/user-data.tmpl"
SECRETS="$OVERLAY_SRC/secrets.env"
USER_DATA_OUT=/tmp/user-data.rendered

RK1_USER="root"
RK1_USER_PASSWORD_HASH=""
RK1_ROOT_PASSWORD_HASH=""
RK1_USER_SSH_KEYS=""

if [ -f "$SECRETS" ]; then
  # /tmp/overlay is mounted read-only inside the chroot; copy out before sourcing
  # so we can't be tricked into leaving the secret file behind.
  install -m 0600 "$SECRETS" /tmp/secrets.env
  # shellcheck disable=SC1091
  . /tmp/secrets.env
  shred -u /tmp/secrets.env 2>/dev/null || rm -f /tmp/secrets.env
  echo "customize-image.sh: loaded secrets.env (user=$RK1_USER)"
else
  echo "customize-image.sh: no secrets.env; user-data will have placeholder values" >&2
fi

# Convert RK1_USER_SSH_KEYS (newline-separated) into a YAML block list indented
# under ssh_authorized_keys:.
if [ -n "$RK1_USER_SSH_KEYS" ]; then
  SSH_KEYS_YAML=$(printf '%s\n' "$RK1_USER_SSH_KEYS" | sed -e '/^$/d' -e 's/^/      - /')
else
  SSH_KEYS_YAML="      []"
fi

export RK1_USER RK1_USER_PASSWORD_HASH RK1_ROOT_PASSWORD_HASH SSH_KEYS_YAML

python3 - "$TMPL" "$USER_DATA_OUT" <<'PYEOF'
import sys, os
src, dst = sys.argv[1], sys.argv[2]
repl = {
    "__RK1_USER__": os.environ.get("RK1_USER", ""),
    "__RK1_USER_PASSWORD_HASH__": os.environ.get("RK1_USER_PASSWORD_HASH", ""),
    "__RK1_ROOT_PASSWORD_HASH__": os.environ.get("RK1_ROOT_PASSWORD_HASH", ""),
    "__RK1_USER_SSH_KEYS_YAML__": os.environ.get("SSH_KEYS_YAML", "      []"),
}
with open(src) as f:
    body = f.read()
for k, v in repl.items():
    body = body.replace(k, v)
with open(dst, "w") as f:
    f.write(body)
PYEOF

rm -f "$TMPL" 2>/dev/null || :   # /tmp/overlay is read-only; ignore

# --- Copy overlay boot/ tree into image /boot ---------------------------------
if [ -d "$OVERLAY_SRC/boot" ]; then
  cp -av "$OVERLAY_SRC"/boot/. /boot/
  rm -f /boot/user-data.tmpl
  install -m 0644 "$USER_DATA_OUT" /boot/user-data
  shred -u "$USER_DATA_OUT" 2>/dev/null || rm -f "$USER_DATA_OUT"
  chmod 0755 /boot/runcmd.ci.sh /boot/rootfs-to.sh
  # /boot is vfat on the shipped image (cloud-init extension forces BOOTFS_TYPE=fat),
  # so Unix mode bits on user-data are not preserved. Secrets live in user-data;
  # protect them by keeping the secret-bearing file out of git, not via filesystem ACLs.
fi

# --- Copy overlay rootfs/ tree into image / ---------------------------------
# Mirrors target paths under userpatches/overlay/rootfs/.
if [ -d "$OVERLAY_SRC/rootfs" ]; then
  cp -av "$OVERLAY_SRC"/rootfs/. /
  # Dynamic MOTD snippets must be executable.
  find /etc/update-motd.d -type f -name '*-rk1-*' -exec chmod 0755 {} +
fi

# --- Extra packages -----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    zfsutils-linux \
    vim

echo zfs > /etc/modules-load.d/zfs.conf

exit 0
