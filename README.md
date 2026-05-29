# Proxmox VE 8 to 9 Upgrade Helper

Interactive Bash helper for upgrading **Proxmox VE 8.x** to **Proxmox VE 9.x** on community/no-subscription installations.

> This script is designed to assist with the official Proxmox VE 8 to 9 upgrade process. It does not replace the official Proxmox documentation. Always verify backups before running a major upgrade.

## What it does

- Checks whether the host is Proxmox VE 8.x
- Stops if the system is not suitable for direct 8 to 9 upgrade
- Creates backups of important configuration files
- Checks running VMs and containers
- Warns on cluster systems unless explicitly allowed
- Disables Proxmox enterprise repositories on no-subscription systems
- Ensures Debian firmware repository components are available
- Attempts to install `intel-microcode` on Intel systems
- Handles common `systemd-boot` leftover package issue
- Handles GRUB removable EFI bootloader warning
- Runs `pve8to9 --full` and stops if failures remain
- Converts repositories from Debian Bookworm to Debian Trixie
- Configures Proxmox VE 9 no-subscription repository
- Runs the major upgrade
- Performs post-upgrade validation
- Creates a detailed log file

## Tested scenario

This approach was tested on:

- Proxmox VE 8.4
- Standalone node
- No-subscription repository
- Local storage / local-lvm
- No Ceph
- Upgrade target: Proxmox VE 9.x / Debian 13 Trixie

## Important safety notes

Before running this script:

1. Make sure all VMs and containers have working backups.
2. Make sure you have physical console/IPMI/iDRAC/iLO or other recovery access.
3. Do not run this blindly on production clusters.
4. For clusters, upgrade one node at a time and migrate guests away first.
5. Read the official Proxmox upgrade guide before using this helper.

## Quick run

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
```

## Safer dry-run first

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --dry-run
```

## Download and run manually

```bash
wget https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh
chmod +x pve8-to-pve9-upgrade.sh
./pve8-to-pve9-upgrade.sh
```

## Options

```text
-y, --yes              Non-interactive mode. Still stops on dangerous failures.
--dry-run              Show checks and intended actions without changing the system.
--allow-cluster        Allow running on a clustered node. Default is to stop.
--skip-guest-check     Do not stop when running guests are detected.
--auto-reboot          Reboot automatically at the end if upgrade commands succeeded.
-h, --help             Show help.
```

## Recommended normal usage

For most standalone community/no-subscription hosts:

```bash
./pve8-to-pve9-upgrade.sh
```

For checking only:

```bash
./pve8-to-pve9-upgrade.sh --dry-run
```

For an already prepared lab system:

```bash
./pve8-to-pve9-upgrade.sh --yes
```

## After reboot

After the upgrade finishes, reboot the host:

```bash
reboot
```

Then verify:

```bash
pveversion
uname -r
cat /etc/os-release
pve8to9 --full
systemctl status pveproxy pvedaemon pvestatd
```

Expected result:

- Proxmox VE 9.x
- Debian GNU/Linux 13 Trixie
- New Proxmox kernel loaded
- `pve8to9 --full` shows `FAILURES: 0`
- Proxmox services are active

## Logs and backups

The script writes logs to:

```text
/root/pve8-to-pve9-upgrade-logs/
```

Configuration backups are stored in:

```text
/root/pve8-to-pve9-upgrade-backups/
```

## Disclaimer

Use at your own risk. A Proxmox major upgrade can affect bootloaders, kernels, storage, networking, and repositories. Always test first and keep verified backups.
