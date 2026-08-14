#!/usr/bin/env bash
# Convert a unified Incus guest tar into a mountable ext4 BFV root image.
#
# Output layout follows the openstack-incus cephext contract: the ext4
# filesystem root contains a top-level rootfs/ directory plus the
# Incus-owned .incus-idmap provenance marker (mode 0600).
#
# Must run as root (loop mount).

set -Eeuo pipefail

IMAGE_NAME=${IMAGE_NAME:?Set IMAGE_NAME}
OUTPUT_DIR=${OUTPUT_DIR:?Set OUTPUT_DIR for the build artifacts}
UNIFIED_TAR=${UNIFIED_TAR:-$OUTPUT_DIR/$IMAGE_NAME.tar.gz}
OUTPUT=${OUTPUT:-$OUTPUT_DIR/$IMAGE_NAME-bfv.raw}
IMAGE_SIZE_MIB=${IMAGE_SIZE_MIB:-512}

command -v mkfs.ext4 >/dev/null
command -v jq >/dev/null
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ "$IMAGE_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] || {
    echo "IMAGE_SIZE_MIB must be a positive integer" >&2
    exit 1
}
[[ -f "$UNIFIED_TAR" ]] || { echo "missing $UNIFIED_TAR" >&2; exit 1; }

work_dir=$(mktemp -d)
mount_dir="$work_dir/root"
loop_device=
cleanup() {
    local status=$?
    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir" || status=$?
    fi
    if [[ -n "$loop_device" ]]; then
        losetup -d "$loop_device" || status=$?
    fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$mount_dir" "$(dirname "$OUTPUT")"
truncate -s "${IMAGE_SIZE_MIB}MiB" "$OUTPUT"
mkfs.ext4 -q -F -L incus-rootfs "$OUTPUT"
loop_device=$(losetup --find --show "$OUTPUT")
mount "$loop_device" "$mount_dir"
tar -xf "$UNIFIED_TAR" -C "$mount_dir"

[[ -x "$mount_dir/rootfs/sbin/init" ||
   -L "$mount_dir/rootfs/sbin/init" ]] || {
    echo "Unified image does not contain rootfs/sbin/init" >&2
    exit 1
}

# The marker is Incus-owned metadata beside rootfs, so it follows every RBD
# clone, snapshot and backup without being visible inside the guest.
printf '%s\n' '{"version":1,"state":"stable","idmap":[]}' \
    >"$mount_dir/.incus-idmap"
chmod 0600 "$mount_dir/.incus-idmap"

# Keep enough headroom for first-boot writes and filesystem metadata.
used_kib=$(du -sk "$mount_dir" | awk '{print $1}')
total_kib=$((IMAGE_SIZE_MIB * 1024))
((used_kib * 100 < total_kib * 85)) || {
    echo "Rootfs consumes more than 85% of the output image" >&2
    exit 1
}

sync
umount "$mount_dir"
losetup -d "$loop_device"
loop_device=
e2fsck -f -n "$OUTPUT"
file -s "$OUTPUT"

manifest="$OUTPUT_DIR/$IMAGE_NAME.manifest.json"
if [[ -f "$manifest" ]]; then
    jq --arg bfv "$(basename "$OUTPUT")" \
       --argjson size "$IMAGE_SIZE_MIB" \
       '. + {bfv_raw: $bfv, bfv_size_mib: $size}' \
       "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
fi

echo "Built $OUTPUT (${IMAGE_SIZE_MIB}MiB, used ${used_kib}KiB)"
