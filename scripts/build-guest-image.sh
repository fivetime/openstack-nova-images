#!/usr/bin/env bash
# Build a nova-incus guest root as a unified Incus tar.
#
# Copies the newest build of SOURCE from the configured Incus remote,
# expands the rootfs, installs the packages required by the
# openstack-incus image contract (fuse2fs for Cinder data volumes),
# and repacks a unified tar (metadata.yaml + templates/ + rootfs/).
#
# Must run as root (chroot + package installation).

set -Eeuo pipefail

SOURCE=${SOURCE:-images:ubuntu/noble/cloud}
IMAGE_NAME=${IMAGE_NAME:-ubuntu-noble-24.04-cloud-incus}
OUTPUT_DIR=${OUTPUT_DIR:?Set OUTPUT_DIR for the build artifacts}
WORK_DIR=${WORK_DIR:-$(mktemp -d)}
LOCAL_ALIAS=${LOCAL_ALIAS:-build-$IMAGE_NAME}
PREINSTALL_SSH=${PREINSTALL_SSH:-false}
PREINSTALL_PACKAGES=${PREINSTALL_PACKAGES:-}

command -v incus >/dev/null
command -v unsquashfs >/dev/null
command -v jq >/dev/null
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

incus image delete "$LOCAL_ALIAS" >/dev/null 2>&1 || true
incus image copy "$SOURCE" local: --alias "$LOCAL_ALIAS"

# Record exactly which upstream build this artifact derives from.
image_json=$(incus image list local: --format json | jq -r \
    --arg a "$LOCAL_ALIAS" '[.[] | select(.aliases[]?.name == $a)][0]')
source_fingerprint=$(jq -r '.fingerprint' <<<"$image_json")
source_serial=$(jq -r '.properties.serial // ""' <<<"$image_json")

incus image export "$LOCAL_ALIAS" "$WORK_DIR/export"

rm -rf "$WORK_DIR/unified"
mkdir -p "$WORK_DIR/unified/rootfs"
tar -xf "$WORK_DIR/export" -C "$WORK_DIR/unified"
mkdir -p "$WORK_DIR/unified/templates"

root_file="$WORK_DIR/export.root"
case "$(file -b "$root_file")" in
    Squashfs*)
        unsquashfs -f -d "$WORK_DIR/unified/rootfs" "$root_file" >/dev/null
        ;;
    *gzip*|*tar*)
        tar -xf "$root_file" -C "$WORK_DIR/unified/rootfs"
        ;;
    *)
        echo "Unsupported Incus rootfs export: $(file -b "$root_file")" >&2
        exit 1
        ;;
esac

rootfs="$WORK_DIR/unified/rootfs"
if [[ ! -x "$rootfs/sbin/init" && ! -L "$rootfs/sbin/init" ]]; then
    echo "Incus image does not provide /sbin/init" >&2
    exit 1
fi

if [[ "$PREINSTALL_SSH" == "true" || -n "$PREINSTALL_PACKAGES" ]]; then
    cleanup_chroot_mounts() {
        if mountpoint -q "$rootfs/sys"; then umount -l "$rootfs/sys"; fi
        if mountpoint -q "$rootfs/proc"; then umount -l "$rootfs/proc"; fi
        if mountpoint -q "$rootfs/dev"; then umount -l "$rootfs/dev"; fi
    }
    trap cleanup_chroot_mounts EXIT

    # The chroot shares the host network, but not systemd-resolved's local
    # stub. Use the host's upstream resolver while installing packages.
    rm -f "$rootfs/etc/resolv.conf"
    cp -L /run/systemd/resolve/resolv.conf "$rootfs/etc/resolv.conf"
    mount --bind /dev "$rootfs/dev"
    mount -t proc proc "$rootfs/proc"
    mount -t sysfs sys "$rootfs/sys"

    packages=($PREINSTALL_PACKAGES)
    if [[ -x "$rootfs/sbin/apk" || -x "$rootfs/usr/bin/apk" ]]; then
        # Alpine bases. Package names differ from Debian: fuse2fs ships in
        # e2fsprogs-extra.
        if [[ "$PREINSTALL_SSH" == "true" ]]; then
            packages+=(openssh)
        fi
        if ((${#packages[@]})); then
            chroot "$rootfs" apk add --no-cache "${packages[@]}"
        fi
        if [[ "$PREINSTALL_SSH" == "true" ]]; then
            chroot "$rootfs" rc-update add sshd default
        fi
        rm -f "$rootfs"/etc/ssh/ssh_host_*
        rm -f "$rootfs/etc/resolv.conf"
    else
        chroot "$rootfs" apt-get -o Acquire::ForceIPv4=true update
        if [[ "$PREINSTALL_SSH" == "true" ]]; then
            packages+=(openssh-server)
        fi
        if ((${#packages[@]})); then
            chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive \
                apt-get -o Acquire::ForceIPv4=true install -y \
                --no-install-recommends "${packages[@]}"
        fi
        if [[ "$PREINSTALL_SSH" == "true" ]]; then
            chroot "$rootfs" systemctl enable ssh
        fi

        # Instances must generate unique host identities on first boot.
        rm -f "$rootfs"/etc/ssh/ssh_host_*
        rm -rf "$rootfs/var/lib/apt/lists"/*
        rm -f "$rootfs/etc/resolv.conf"
        ln -s ../run/systemd/resolve/stub-resolv.conf \
            "$rootfs/etc/resolv.conf"
    fi

    cleanup_chroot_mounts
    trap - EXIT
fi

# The openstack-incus driver rejects data-volume instances unless the image
# advertises fuse2fs, and re-verifies the executable at attach time. Only
# claim the capability when the binary is really executable in the rootfs.
data_volume_fuse=false
for fuse2fs_path in usr/bin/fuse2fs bin/fuse2fs usr/sbin/fuse2fs sbin/fuse2fs; do
    if [[ -x "$rootfs/$fuse2fs_path" ]]; then
        data_volume_fuse=true
        break
    fi
done

tar -C "$WORK_DIR/unified" -czf "$OUTPUT_DIR/$IMAGE_NAME.tar.gz" \
    metadata.yaml templates rootfs

jq -n \
    --arg name "$IMAGE_NAME" \
    --arg source "$SOURCE" \
    --arg fingerprint "$source_fingerprint" \
    --arg serial "$source_serial" \
    --arg unified "$IMAGE_NAME.tar.gz" \
    --argjson fuse "$data_volume_fuse" \
    '{name: $name, source_alias: $source,
      source_fingerprint: $fingerprint, source_serial: $serial,
      unified_tar: $unified, data_volume_fuse: $fuse}' \
    >"$OUTPUT_DIR/$IMAGE_NAME.manifest.json"

echo "Built $OUTPUT_DIR/$IMAGE_NAME.tar.gz"
echo "  source: $SOURCE serial=$source_serial"
echo "  fingerprint: $source_fingerprint"
echo "  data_volume_fuse: $data_volume_fuse"
