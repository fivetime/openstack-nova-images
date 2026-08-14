#!/usr/bin/env bash
# Upload built guest images to Glance with the openstack-incus property
# contract. Run this wherever the Glance endpoint is reachable (a CI
# runner with network access, or a control node after downloading the
# GitHub release artifacts).
#
# Usage: push-to-glance.sh <dist-dir>
#
# Environment:
#   OS_* ...            standard OpenStack auth (or a sourced openrc)
#   VISIBILITY          public|private|shared|community (default public)
#   HYPERVISOR_TYPE     value for the hypervisor_type property
#                       (default lxd, matching what nova-incus computes
#                       report; required for ImagePropertiesFilter in
#                       mixed libvirt/incus clusters)
#   IMAGE_STORE         optional Glance store to place images in
#                       (production BFV must select the RBD store
#                       explicitly for Cinder CoW cloning)
#   IMAGE_IMPORT_TIMEOUT  seconds to wait for store copy (default 600)
#   NAME_SUFFIX         optional suffix appended to Glance image names

set -Eeuo pipefail

DIST_DIR=${1:?Usage: push-to-glance.sh <dist-dir>}
VISIBILITY=${VISIBILITY:-public}
HYPERVISOR_TYPE=${HYPERVISOR_TYPE:-lxd}
IMAGE_STORE=${IMAGE_STORE:-}
IMAGE_IMPORT_TIMEOUT=${IMAGE_IMPORT_TIMEOUT:-600}
NAME_SUFFIX=${NAME_SUFFIX:-}

command -v openstack >/dev/null
command -v jq >/dev/null
[[ -n "${OS_AUTH_URL:-}" ]] || { echo "OS_AUTH_URL is not set" >&2; exit 1; }
if [[ -n "$IMAGE_STORE" ]]; then
    [[ "$IMAGE_STORE" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "IMAGE_STORE contains unsupported characters" >&2
        exit 1
    }
fi

# Upload one file as one Glance image, optionally routing it into an
# explicit store through the interoperable import API.
upload_image() {
    local name=$1 file=$2
    shift 2
    local props=("$@")

    openstack image delete "$name" >/dev/null 2>&1 || true

    if [[ -z "$IMAGE_STORE" ]]; then
        openstack image create "$name" \
            --disk-format raw --container-format bare \
            "--$VISIBILITY" "${props[@]}" --file "$file"
        openstack image show "$name" -c id -c status -c size
        return
    fi

    local image_id
    image_id=$(openstack image create "$name" \
        --disk-format raw --container-format bare \
        --private "${props[@]}" --file "$file" -f value -c id)
    openstack image import --method copy-image --store "$IMAGE_STORE" \
        --wait "$image_id"

    # The --wait above is insufficient for an already-active copy-image
    # source; poll the store list until the requested store appears.
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
    unified=$(jq -r '.unified_tar' "$manifest")
    bfv=$(jq -r '.bfv_raw // ""' "$manifest")
    fuse=$(jq -r '.data_volume_fuse' "$manifest")

    common_props=(--property "hypervisor_type=$HYPERVISOR_TYPE")
    if [[ "$fuse" == "true" ]]; then
        common_props+=(--property hw_incus_data_volume_fuse=true)
    fi

    echo "== $name (fuse2fs=$fuse) =="
    upload_image "$name$NAME_SUFFIX" "$DIST_DIR/$unified" \
        "${common_props[@]}"

    if [[ -n "$bfv" ]]; then
        bfv_file="$DIST_DIR/$bfv"
        if [[ "$bfv_file" == *.zst ]]; then
            command -v zstd >/dev/null
            zstd -d -f "$bfv_file" -o "${bfv_file%.zst}"
            bfv_file=${bfv_file%.zst}
        fi
        upload_image "$name-bfv$NAME_SUFFIX" "$bfv_file" \
            "${common_props[@]}" \
            --property hw_incus_boot_from_volume=true \
            --property hw_incus_rootfs_idmap_provenance=v1 \
            --property hw_incus_rootfs_layout=rootfs-directory
    fi
done
