#!/usr/bin/env bash
# Build a libvirt/KVM guest disk from the newest upstream VM build.
#
# Copies the virtual-machine image for SOURCE from the Incus image
# remote, then installs and enables qemu-guest-agent (the channel
# Nova's libvirt driver uses for the "set admin password" API) by
# loop-mounting the disk and chrooting with host networking — the same
# proven mechanism as the container pipeline; the libguestfs appliance
# network does not work on GitHub runners.
#
# Must run as root (loop mount + chroot).

set -Eeuo pipefail

SOURCE=${SOURCE:-images:ubuntu/noble/cloud}
IMAGE_NAME=${IMAGE_NAME:-ubuntu-noble-cloud-kvm}
OUTPUT_DIR=${OUTPUT_DIR:?Set OUTPUT_DIR for the build artifacts}
WORK_DIR=${WORK_DIR:-$(mktemp -d)}
LOCAL_ALIAS=${LOCAL_ALIAS:-build-$IMAGE_NAME}
# Optional command run inside the guest before package installation
# (e.g. Arch keyring initialization).
PRE_COMMAND=${PRE_COMMAND:-}

command -v incus >/dev/null
command -v qemu-img >/dev/null
command -v jq >/dev/null
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

incus image delete "$LOCAL_ALIAS" >/dev/null 2>&1 || true
incus image copy "$SOURCE" local: --alias "$LOCAL_ALIAS" --vm

# Record exactly which upstream build this artifact derives from.
image_json=$(incus image list local: --format json | jq -r \
    --arg a "$LOCAL_ALIAS" '[.[] | select(.aliases[]?.name == $a)][0]')
source_fingerprint=$(jq -r '.fingerprint' <<<"$image_json")
source_serial=$(jq -r '.properties.serial // ""' <<<"$image_json")

incus image export "$LOCAL_ALIAS" "$WORK_DIR/export"
qcow="$WORK_DIR/export.root"
case "$(file -b "$qcow")" in
    QEMU\ QCOW*) ;;
    *)
        echo "Unsupported VM disk export: $(file -b "$qcow")" >&2
        exit 1
        ;;
esac

raw="$WORK_DIR/disk.raw"
qemu-img convert -O raw "$qcow" "$raw"
rm -f "$qcow"

loop_device=
rootfs="$WORK_DIR/root"
mkdir -p "$rootfs"
cleanup() {
    local status=$?
    for m in "$rootfs/sys" "$rootfs/proc" "$rootfs/dev" "$rootfs"; do
        if mountpoint -q "$m"; then umount -l "$m" || status=$?; fi
    done
    if [[ -n "$loop_device" ]]; then
        losetup -d "$loop_device" || status=$?
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

loop_device=$(losetup --find --show -P "$raw")

# Find the root partition: the distrobuilder layout is ESP (vfat) plus
# a Linux root filesystem; probe non-vfat partitions for /sbin/init.
root_part=
for part in "$loop_device"p*; do
    fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    case "$fstype" in
        ext4|xfs|btrfs) ;;
        *) continue ;;
    esac
    mount "$part" "$rootfs"
    if [[ -x "$rootfs/sbin/init" || -L "$rootfs/sbin/init" ]]; then
        root_part=$part
        break
    fi
    umount "$rootfs"
done
[[ -n "$root_part" ]] || {
    echo "No root filesystem with /sbin/init found in $SOURCE" >&2
    exit 1
}

# The chroot shares the host network, but not systemd-resolved's local
# stub. Use the host's upstream resolver while installing packages.
had_resolv_link=false
[[ -L "$rootfs/etc/resolv.conf" ]] && had_resolv_link=true
rm -f "$rootfs/etc/resolv.conf"
cp -L /run/systemd/resolve/resolv.conf "$rootfs/etc/resolv.conf"
mount --bind /dev "$rootfs/dev"
mount -t proc proc "$rootfs/proc"
mount -t sysfs sys "$rootfs/sys"

if [[ -n "$PRE_COMMAND" ]]; then
    chroot "$rootfs" sh -c "$PRE_COMMAND"
fi

if [[ -x "$rootfs/sbin/apk" || -x "$rootfs/usr/bin/apk" ]]; then
    chroot "$rootfs" apk add --no-cache qemu-guest-agent
    chroot "$rootfs" rc-update add qemu-guest-agent default
elif [[ -x "$rootfs/usr/bin/apt-get" ]]; then
    chroot "$rootfs" apt-get -o Acquire::ForceIPv4=true update
    chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Acquire::ForceIPv4=true install -y \
        --no-install-recommends qemu-guest-agent
    chroot "$rootfs" systemctl enable qemu-guest-agent.service
    rm -rf "$rootfs/var/lib/apt/lists"/*
elif [[ -x "$rootfs/usr/bin/dnf" ]]; then
    chroot "$rootfs" dnf install -y \
        --setopt=install_weak_deps=False qemu-guest-agent
    chroot "$rootfs" systemctl enable qemu-guest-agent.service
    chroot "$rootfs" dnf clean all
elif [[ -x "$rootfs/usr/bin/zypper" ]]; then
    chroot "$rootfs" zypper --non-interactive install \
        --no-recommends qemu-guest-agent
    chroot "$rootfs" systemctl enable qemu-guest-agent.service
    chroot "$rootfs" zypper --non-interactive clean --all
elif [[ -x "$rootfs/usr/bin/pacman" ]]; then
    sed -i 's/^CheckSpace/#CheckSpace/' "$rootfs/etc/pacman.conf"
    for attempt in 1 2 3; do
        if chroot "$rootfs" pacman -Sy --noconfirm --needed \
            qemu-guest-agent; then
            break
        fi
        ((attempt < 3)) || exit 1
        sleep 15
    done
    sed -i 's/^#CheckSpace/CheckSpace/' "$rootfs/etc/pacman.conf"
    # Arch's qemu-guest-agent unit has no [Install] section; a udev
    # rule starts it when the virtio-serial port appears, so there is
    # nothing to enable. Kill the keyring agents on their real homedir
    # or they keep the mount busy.
    chroot "$rootfs" gpgconf --homedir /etc/pacman.d/gnupg \
        --kill all || true
    rm -rf "$rootfs/var/cache/pacman/pkg"/*
else
    echo "No supported package manager found in $SOURCE rootfs" >&2
    exit 1
fi

# Instances must generate unique host identities on first boot.
rm -f "$rootfs"/etc/ssh/ssh_host_*

# Restore the distro resolver arrangement.
rm -f "$rootfs/etc/resolv.conf"
if [[ "$had_resolv_link" == true && -d "$rootfs/usr/lib/systemd" ]]; then
    ln -s ../run/systemd/resolve/stub-resolv.conf \
        "$rootfs/etc/resolv.conf"
fi

# Verify the agent binary really landed; the Glance property is an
# admission contract, not a wish.
qemu_guest_agent=false
for p in usr/bin/qemu-ga usr/sbin/qemu-ga bin/qemu-ga sbin/qemu-ga; do
    if [[ -x "$rootfs/$p" ]]; then
        qemu_guest_agent=true
        break
    fi
done

sync
umount -l "$rootfs/sys" "$rootfs/proc" "$rootfs/dev"
# Kill any stray chroot processes (package-manager agents) that would
# keep the root mount busy.
fuser -k -m "$rootfs" 2>/dev/null || true
sleep 1
umount "$rootfs"
losetup -d "$loop_device"
loop_device=

qemu-img convert -O qcow2 -c "$raw" "$OUTPUT_DIR/$IMAGE_NAME.qcow2"

jq -n \
    --arg name "$IMAGE_NAME" \
    --arg source "$SOURCE" \
    --arg fingerprint "$source_fingerprint" \
    --arg serial "$source_serial" \
    --arg disk "$IMAGE_NAME.qcow2" \
    --argjson agent "$qemu_guest_agent" \
    '{name: $name, source_alias: $source,
      source_fingerprint: $fingerprint, source_serial: $serial,
      disk: $disk, qemu_guest_agent: $agent}' \
    >"$OUTPUT_DIR/$IMAGE_NAME.manifest.json"

echo "Built $OUTPUT_DIR/$IMAGE_NAME.qcow2"
echo "  source: $SOURCE serial=$source_serial"
echo "  fingerprint: $source_fingerprint"
echo "  qemu_guest_agent: $qemu_guest_agent"
