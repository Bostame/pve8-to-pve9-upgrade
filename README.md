# Proxmox VE 8 → 9 Upgrade Helper

Interactive Bash helper for upgrading **Proxmox VE 8.x to Proxmox VE 9.x** using the community/no-subscription repository.

Version 2 adds **Ceph-aware safety checks** for hyper-converged Proxmox + Ceph clusters.

> This script helps automate the official upgrade flow. It does not replace reading the official Proxmox documentation.

## One-line command

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
```

## Safer first test

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --dry-run
```

## Standalone node

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
```

## Cluster node

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --allow-cluster
```

## Ceph cluster node

Only use after Ceph has already been upgraded to **Squid 19.2+** on Proxmox VE 8 and the cluster is healthy.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --allow-cluster --allow-ceph
```

## Options

| Option | Description |
|---|---|
| `--dry-run` | Show what would happen without changing repositories or upgrading |
| `--yes` | Reduce prompts, but still stop on hard risks |
| `--allow-cluster` | Allow execution on a Proxmox cluster node |
| `--allow-ceph` | Allow execution when Ceph is detected |
| `--auto-reboot` | Reboot automatically after successful script completion |
| `--skip-guest-check` | Do not stop for running VMs/CTs |
| `--skip-microcode` | Do not attempt CPU microcode installation |
| `--stage precheck` | Run checks/backups only |
| `--stage repos` | Configure repositories only |
| `--stage upgrade` | Run upgrade/post-checks only |
| `--stage full` | Default full flow |

## Important Ceph rule

For hyper-converged Ceph clusters, Ceph must be upgraded to **Squid 19.2+ before upgrading Proxmox VE 8 to 9**.

Recommended flow:

1. Upgrade Ceph Reef/Quincy to Squid while still on Proxmox VE 8.
2. Confirm `ceph -s` is healthy.
3. Upgrade one Proxmox node at a time.
4. Migrate or shut down guests on the node.
5. Consider setting `ceph osd set noout`.
6. Upgrade the node.
7. Reboot and validate.
8. Continue with the next node.
9. After all nodes are upgraded and healthy, unset `noout`.

## Disclaimer

Use at your own risk. Always keep verified backups before performing a major Proxmox upgrade.
