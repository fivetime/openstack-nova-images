# nova-incus-image

Automated guest-image pipeline for the
[openstack-incus](https://github.com/fivetime/openstack-incus) Nova
driver. Every run inherits the **newest upstream build** from
`images.linuxcontainers.org` (the `images:` remote resolves aliases to
the latest daily build), installs the packages the driver's image
contract requires, and produces the two artifacts the driver accepts:

| Artifact | Glance format | Purpose |
|---|---|---|
| `<name>.tar.gz` | raw/bare unified tar (`metadata.yaml` + `templates/` + `rootfs/`) | Incus-managed guest root |
| `<name>-bfv.raw.zst` | raw/bare ext4 with top-level `rootfs/` + `.incus-idmap` | Cinder boot-from-volume root (RBD CoW clone) |

A `<name>.manifest.json` records the upstream fingerprint/serial and
capability flags for provenance.

Do **not** upload qcow2 VM disks: the driver only accepts the two
layouts above (see openstack-incus `doc/source/image_build_guide.rst`).

## Why the images are customized

* **`fuse2fs` is mandatory for Cinder data volumes.** The driver
  refuses to build an instance with initial data volumes unless the
  Glance image carries `hw_incus_data_volume_fuse=true`, and re-checks
  the executable inside the guest at attach time. Tenant ext4 is parsed
  in userspace, never by the compute kernel. The default (guest runs
  `fuse2fs` itself) is the only path compatible with CRIU live
  migration.
* **cloud-init** comes from the upstream `cloud` variant (user-data,
  keypairs, Neutron network config).
* **SSH** is preinstalled with host keys removed so each instance
  generates a unique identity on first boot.
* **Manila needs nothing in the guest** — shares are staged on the
  compute host and exposed as Incus disk devices.
* The CI build validates `rootfs/sbin/init`, the fuse2fs capability,
  the `.incus-idmap` marker (0600), 15% free headroom, and `e2fsck`.

## Workflow

`.github/workflows/build.yaml` runs monthly (1st, 00:00 UTC) and on
manual dispatch. It always publishes a GitHub release with checksums.

### Pushing to Glance

GitHub-hosted runners **cannot reach a private OpenStack endpoint**
(e.g. a cluster on 10.x.x.x), so the Glance push is a separate opt-in
job. Choose one:

1. **Self-hosted runner** with network access to Keystone/Glance:
   register it, set repo variable `GLANCE_RUNNER` to its label, set
   `PUSH_TO_GLANCE=true`, and configure the `OS_*` secrets
   (`OS_AUTH_URL`, `OS_PROJECT_NAME`, `OS_PROJECT_DOMAIN_NAME`,
   `OS_USERNAME`, `OS_USER_DOMAIN_NAME`, `OS_PASSWORD`,
   `OS_REGION_NAME`). Optional: variable `GLANCE_IMAGE_STORE` to route
   uploads into an explicit store (production BFV should name the RBD
   store so Cinder can CoW-clone).
2. **Manual from a control node** that has `openstack` CLI:

   ```bash
   gh release download <tag> --dir dist --repo fivetime/nova-incus-image
   source /etc/openstack/admin-openrc
   IMAGE_STORE=rbd bash scripts/push-to-glance.sh dist
   ```

The push script applies the full property contract, including
`hypervisor_type=lxd` (what nova-incus computes report — required by
`ImagePropertiesFilter` in mixed libvirt/incus clusters; override with
`HYPERVISOR_TYPE=` if your deployment differs) and the BFV properties
(`hw_incus_boot_from_volume`, `hw_incus_rootfs_idmap_provenance`,
`hw_incus_rootfs_layout`).

## Adding an image

Add a matrix entry in `.github/workflows/build.yaml`:

```yaml
- name: debian-trixie-cloud-incus
  source: images:debian/trixie/cloud
  packages: fuse2fs jq        # e2fsprogs-extra on Alpine
  bfv_size_mib: 2048
```

Keep releases pinned (`ubuntu/noble`, not `ubuntu`) — the alias still
tracks the latest *build* of that release. Remember the openstack-incus
rule: a new image revision is not production-ready until it passes the
image acceptance matrix (create/delete, BFV, data volumes, hard reboot,
snapshot/restore, and — only if advertised — the live-migration
matrix). Publishing here is build evidence, not qualification.
