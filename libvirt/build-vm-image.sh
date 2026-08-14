#!/usr/bin/env bash
# Build a libvirt/KVM guest disk from the newest upstream VM build.
#
# Copies the virtual-machine image for SOURCE from the Incus image
# remote, installs and enables qemu-guest-agent inside the disk (the
# channel Nova's libvirt driver uses for the "set admin password" API),
# and emits a recompressed qcow2 plus a provenance manifest.
#
# Must run as root (libguestfs appliance + readable host kernel).

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
command -v virt-customize >/dev/null
command -v virt-ls >/dev/null
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
disk="$WORK_DIR/export.root"
case "$(file -b "$disk")" in
    QEMU\ QCOW*) ;;
    *)
        echo "Unsupported VM disk export: $(file -b "$disk")" >&2
        exit 1
        ;;
esac

export LIBGUESTFS_BACKEND=direct

customize_args=(-a "$disk")
# The guest resolv.conf is a dangling systemd-resolved symlink inside
# the appliance; point it at the SLIRP resolver while installing.
customize_args+=(--run-command \
    'rm -f /etc/resolv.conf; printf "nameserver 10.0.2.3\nnameserver 1.1.1.1\n" > /etc/resolv.conf')
if [[ -n "$PRE_COMMAND" ]]; then
    customize_args+=(--run-command "$PRE_COMMAND")
fi
customize_args+=(
    --install qemu-guest-agent
    # systemd distros enable via unit, OpenRC (Alpine) via rc-update.
    --run-command 'command -v systemctl >/dev/null 2>&1 \
        && systemctl enable qemu-guest-agent.service \
        || rc-update add qemu-guest-agent default'
    # Instances must generate unique host identities on first boot.
    --run-command 'rm -f /etc/ssh/ssh_host_*'
    # Restore the distro resolver arrangement.
    --run-command 'rm -f /etc/resolv.conf; if [ -d /usr/lib/systemd ]; then ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; fi'
)
virt-customize "${customize_args[@]}"

# Verify the agent binary really landed; the Glance property is an
# admission contract, not a wish.
qemu_guest_agent=false
for dir in /usr/bin /usr/sbin /bin /sbin; do
    if virt-ls -a "$disk" "$dir" 2>/dev/null | grep -qx 'qemu-ga'; then
        qemu_guest_agent=true
        break
    fi
done

# Recompress: virt-customize appends uncompressed clusters.
qemu-img convert -O qcow2 -c "$disk" "$OUTPUT_DIR/$IMAGE_NAME.qcow2"

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
