#!/usr/bin/env bash
# Upload built libvirt/KVM guest disks to Glance. Run wherever the
# Glance endpoint is reachable.
#
# Usage: push-to-glance.sh <dist-dir>
#
# Environment:
#   OS_* ...            standard OpenStack auth (or a sourced openrc)
#   VISIBILITY          public|private|shared|community (default public)
#   HYPERVISOR_TYPE     value for the hypervisor_type property
#                       (default qemu, matching libvirt computes;
#                       required by ImagePropertiesFilter in mixed
#                       libvirt/incus clusters)
#   FIRMWARE_TYPE       hw_firmware_type value (default uefi — the
#                       upstream distrobuilder VM disks boot UEFI;
#                       set empty to omit)
#   IMAGE_STORE         optional Glance store to place images in
#   IMAGE_IMPORT_TIMEOUT  seconds to wait for store copy (default 600)
#   NAME_SUFFIX         optional suffix appended to Glance image names

set -Eeuo pipefail

DIST_DIR=${1:?Usage: push-to-glance.sh <dist-dir>}
VISIBILITY=${VISIBILITY:-public}
HYPERVISOR_TYPE=${HYPERVISOR_TYPE:-qemu}
FIRMWARE_TYPE=${FIRMWARE_TYPE-uefi}
IMAGE_STORE=${IMAGE_STORE:-}
IMAGE_IMPORT_TIMEOUT=${IMAGE_IMPORT_TIMEOUT:-600}
NAME_SUFFIX=${NAME_SUFFIX:-}

command -v openstack >/dev/null
command -v jq >/dev/null
[[ -n "${OS_CLOUD:-}" || -n "${OS_AUTH_URL:-}" ]] || {
    echo "Set OS_CLOUD or OS_AUTH_URL for OpenStack authentication" >&2
    exit 1
}
if [[ -n "$IMAGE_STORE" ]]; then
    [[ "$IMAGE_STORE" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "IMAGE_STORE contains unsupported characters" >&2
        exit 1
    }
fi

upload_image() {
    local name=$1 file=$2
    shift 2
    local props=("$@")

    openstack image delete "$name" >/dev/null 2>&1 || true

    if [[ -z "$IMAGE_STORE" ]]; then
        openstack image create "$name" \
            --disk-format qcow2 --container-format bare \
            "--$VISIBILITY" "${props[@]}" --file "$file"
        openstack image show "$name" -c id -c status -c size
        return
    fi

    local image_id
    image_id=$(openstack image create "$name" \
        --disk-format qcow2 --container-format bare \
        --private "${props[@]}" --file "$file" -f value -c id)
    openstack image import --method copy-image --store "$IMAGE_STORE" \
        --wait "$image_id"

    local deadline=$((SECONDS + IMAGE_IMPORT_TIMEOUT)) stores=
    while ((SECONDS < deadline)); do
        stores=$(openstack image show "$image_id" -f json | \
            jq -r '.properties.stores // ""')
        [[ ",$stores," == *",$IMAGE_STORE,"* ]] && break
        sleep 5
    done
    [[ ",$stores," == *",$IMAGE_STORE,"* ]] || {
        echo "Image $name was not copied to store $IMAGE_STORE" >&2
        openstack image delete "$image_id" >/dev/null 2>&1 || true
        exit 1
    }

    local store
    for store in ${stores//,/ }; do
        if [[ "$store" != "$IMAGE_STORE" ]]; then
            openstack image delete --store "$store" "$image_id"
        fi
    done
    openstack image set "--$VISIBILITY" "$image_id"
    openstack image show "$image_id" -c id -c status -c size -c properties
}

shopt -s nullglob
manifests=("$DIST_DIR"/*.manifest.json)
((${#manifests[@]})) || { echo "no manifests in $DIST_DIR" >&2; exit 1; }

for manifest in "${manifests[@]}"; do
    name=$(jq -r '.name' "$manifest")
    disk=$(jq -r '.disk' "$manifest")
    agent=$(jq -r '.qemu_guest_agent' "$manifest")

    props=(--property "hypervisor_type=$HYPERVISOR_TYPE")
    if [[ -n "$FIRMWARE_TYPE" ]]; then
        props+=(--property "hw_firmware_type=$FIRMWARE_TYPE")
    fi
    # hw_qemu_guest_agent=yes makes Nova attach the virtio channel that
    # the "openstack server set --password" API needs.
    if [[ "$agent" == "true" ]]; then
        props+=(--property hw_qemu_guest_agent=yes)
    fi

    echo "== $name (qemu_guest_agent=$agent) =="
    upload_image "$name$NAME_SUFFIX" "$DIST_DIR/$disk" "${props[@]}"
done
