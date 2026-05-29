# Proxmox VE 8.x to 9.x Upgrade Helper

## Purpose

This article describes how to use the internal upgrade helper script for upgrading a Proxmox VE 8.x community/no-subscription host to Proxmox VE 9.x.

The script is intended to reduce manual errors during the upgrade process. It does not bypass the official Proxmox upgrade checks. If the official `pve8to9 --full` checker reports unresolved failures, the script stops.

---

## Supported Scenario

This procedure is intended for:

- Proxmox VE 8.x
- Upgrade target: Proxmox VE 9.x
- Debian Bookworm to Debian Trixie migration
- Community / no-subscription repository
- Standalone hosts

For clustered Proxmox systems, use extra care and upgrade only one node at a time.

---

## Important Warning

Before running the upgrade:

- Verify that all VMs and containers have working backups.
- Make sure no critical workloads are running.
- Use SSH or physical console access.
- Make sure recovery access is available in case the server does not boot.
- Do not run this during business-critical hours.

---

## GitHub Repository

Repository:

```text
git@github.com:Bostame/pve8-to-pve9-upgrade.git
```

Public raw script URL after pushing to GitHub:

```text
https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh
```

---

## Quick Run Command

Use this command on the Proxmox host as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
```

---

## Recommended Dry Run First

Before making changes, run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --dry-run
```

This shows what the script would do without applying changes.

---

## Manual Download Method

```bash
wget https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh
chmod +x pve8-to-pve9-upgrade.sh
./pve8-to-pve9-upgrade.sh
```

---

## Script Options

```text
-y, --yes              Non-interactive mode. Still stops on dangerous failures.
--dry-run              Show checks and intended actions without changing the system.
--allow-cluster        Allow running on a clustered node. Default is to stop.
--skip-guest-check     Do not stop when running guests are detected.
--auto-reboot          Reboot automatically at the end if upgrade commands succeeded.
-h, --help             Show help.
```

---

## What the Script Does

The script performs the following actions:

1. Checks that it is running as root.
2. Checks that the system is Proxmox VE 8.x.
3. Creates a backup of important configuration files.
4. Checks cluster status.
5. Checks whether VMs or containers are running.
6. Disables Proxmox enterprise repositories if present.
7. Enables Debian firmware components required for packages such as `intel-microcode`.
8. Updates the existing Proxmox VE 8 installation.
9. Installs Intel microcode on Intel systems if available.
10. Fixes the common leftover `systemd-boot` package issue.
11. Fixes GRUB removable EFI bootloader handling where applicable.
12. Runs the official `pve8to9 --full` checker.
13. Stops if the checker still reports failures.
14. Converts repositories from Bookworm to Trixie.
15. Configures the Proxmox VE 9 no-subscription repository.
16. Runs the major upgrade.
17. Cleans duplicate repository definitions.
18. Runs post-upgrade validation.
19. Shows final reboot and verification instructions.

---

## Configuration Backup Location

Backups are stored here:

```text
/root/pve8-to-pve9-upgrade-backups/
```

---

## Log Location

Logs are stored here:

```text
/root/pve8-to-pve9-upgrade-logs/
```

If the upgrade fails, always check the newest log file in this directory.

---

## After the Script Finishes

Reboot the host:

```bash
reboot
```

After reboot, verify:

```bash
pveversion
uname -r
cat /etc/os-release
pve8to9 --full
systemctl status pveproxy pvedaemon pvestatd
```

Expected result:

```text
Proxmox VE 9.x
Debian GNU/Linux 13 trixie
FAILURES: 0
```

The services should show:

```text
active (running)
```

---

## VM Validation After Upgrade

Check all VMs:

```bash
qm list
```

Start a VM if needed:

```bash
qm start <VMID>
```

Check VM status:

```bash
qm status <VMID>
```

If QEMU Guest Agent is installed and enabled:

```bash
qm agent <VMID> ping
```

If the guest agent is not configured, this is not critical. Validate the VM from the Proxmox web console instead.

---

## Optional Cleanup

After confirming the system works correctly:

```bash
apt autoremove
```

---

## Success Criteria

The upgrade is successful when:

- Proxmox VE reports version 9.x.
- Debian reports version 13 / Trixie.
- The new Proxmox kernel is loaded.
- `pve8to9 --full` reports zero failures.
- Proxmox services are active.
- VMs start normally.
- Backups still work.

---

# Full Upgrade Script

Save as:

```text
pve8-to-pve9-upgrade.sh
```

```bash
#!/usr/bin/env bash
# Proxmox VE 8.x to 9.x interactive upgrade helper for community/no-subscription systems.
# Author: Bostame / prepared with ChatGPT
# License: MIT

set -Eeuo pipefail

SCRIPT_NAME="pve8-to-pve9-upgrade"
LOG_DIR="/root/${SCRIPT_NAME}-logs"
BACKUP_BASE="/root/${SCRIPT_NAME}-backups"
RUN_ID="$(date +%F-%H%M%S)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}-${RUN_ID}.log"
BACKUP_DIR="${BACKUP_BASE}/${RUN_ID}"
ASSUME_YES=0
DRY_RUN=0
ALLOW_CLUSTER=0
SKIP_GUEST_CHECK=0
AUTO_REBOOT=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "$LOG_DIR" "$BACKUP_BASE"
exec > >(tee -a "$LOG_FILE") 2>&1

info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; echo "Log: $LOG_FILE"; exit 1; }
step()  { echo; echo -e "${BOLD}==> $*${RESET}"; }

usage() {
  cat <<USAGE
${SCRIPT_NAME}
Interactive helper to upgrade Proxmox VE 8.x to 9.x using the no-subscription repository.

Usage:
  bash ${SCRIPT_NAME}.sh [options]

Options:
  -y, --yes              Non-interactive mode. Still stops on dangerous failures.
  --dry-run              Show checks and intended actions without changing the system.
  --allow-cluster        Allow running on a clustered node. Default is to stop.
  --skip-guest-check     Do not stop when running guests are detected.
  --auto-reboot          Reboot automatically at the end if upgrade commands succeeded.
  -h, --help             Show this help.

Recommended one-liner after publishing to GitHub:
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-cluster) ALLOW_CLUSTER=1 ;;
    --skip-guest-check) SKIP_GUEST_CHECK=1 ;;
    --auto-reboot) AUTO_REBOOT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1"
  local required="${2:-YES}"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "Auto-confirmed: $prompt"
    return 0
  fi
  echo
  read -r -p "$prompt Type ${required}: " answer
  [[ "$answer" == "$required" ]]
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Please run this script as root on the Proxmox host."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

get_pve_major() {
  pveversion 2>/dev/null | awk -F/ '/pve-manager/ {split($2,a,"."); print a[1]; exit}'
}

get_debian_codename() {
  . /etc/os-release
  echo "${VERSION_CODENAME:-unknown}"
}

banner() {
  cat <<'BANNER'
============================================================
 Proxmox VE 8.x -> 9.x Interactive Upgrade Helper
 Community / No-Subscription Repository
============================================================
BANNER
  echo "Log file: $LOG_FILE"
}

safety_intro() {
  step "Safety notice"
  warn "This is a major Proxmox/Debian upgrade helper, not a magic no-risk installer."
  warn "It will stop if Proxmox reports unresolved upgrade failures."
  warn "Make sure you have working backups of all VMs/CTs before continuing."
  warn "Recommended: use SSH or physical console, not only the Proxmox web shell."
  confirm "Continue with upgrade preparation?" "UPGRADE" || fail "Cancelled by user."
}

backup_configs() {
  step "Backing up configuration"
  run mkdir -p "$BACKUP_DIR"
  for path in /etc/apt /etc/pve /etc/network /etc/default/grub /etc/fstab /etc/hosts /etc/hostname; do
    if [[ -e "$path" ]]; then
      run cp -a "$path" "$BACKUP_DIR/" || warn "Could not backup $path"
    fi
  done
  ok "Backup directory: $BACKUP_DIR"
}

check_environment() {
  step "Checking environment"
  require_command pveversion
  require_command apt
  require_command apt-get

  local major codename
  major="$(get_pve_major)"
  codename="$(get_debian_codename)"

  info "Detected: $(pveversion | head -n1)"
  info "Debian codename: $codename"

  if [[ "$major" == "9" ]]; then
    ok "This host is already on Proxmox VE 9. Running post-upgrade validation only."
    post_upgrade_validation
    exit 0
  fi

  [[ "$major" == "8" ]] || fail "Only Proxmox VE 8.x -> 9.x is supported. Detected major version: ${major:-unknown}"
  [[ "$codename" == "bookworm" ]] || warn "Expected Debian bookworm before upgrade, detected: $codename"
}

check_cluster() {
  step "Checking cluster status"
  if command -v pvecm >/dev/null 2>&1 && pvecm status >/tmp/pvecm-status.$$ 2>/dev/null; then
    if grep -q "Nodes:[[:space:]]*[2-9]" /tmp/pvecm-status.$$; then
      cat /tmp/pvecm-status.$$
      rm -f /tmp/pvecm-status.$$
      if [[ "$ALLOW_CLUSTER" -ne 1 ]]; then
        fail "Cluster detected. Upgrade clustered nodes one at a time. Re-run with --allow-cluster only if you understand the process."
      fi
      warn "Cluster allowed by user. Upgrade only one node at a time and migrate guests away first."
    else
      ok "Standalone node or single-node cluster state detected."
    fi
    rm -f /tmp/pvecm-status.$$ || true
  else
    ok "No active cluster status detected."
  fi
}

check_running_guests() {
  step "Checking running VMs and containers"
  if [[ "$SKIP_GUEST_CHECK" -eq 1 ]]; then
    warn "Guest check skipped by user."
    return 0
  fi

  local running_vms running_cts
  running_vms="$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}' | xargs || true)"
  running_cts="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | xargs || true)"

  if [[ -n "$running_vms" || -n "$running_cts" ]]; then
    warn "Running guests detected."
    [[ -n "$running_vms" ]] && echo "Running VMs: $running_vms"
    [[ -n "$running_cts" ]] && echo "Running CTs: $running_cts"
    confirm "Continue anyway?" "YES" || fail "Stop/migrate guests first, then run again."
  else
    ok "No running guests detected."
  fi
}

apt_update_safe() {
  step "Running apt update"
  if ! run apt update; then
    warn "apt update failed. Trying to disable enterprise repositories and retry."
    disable_enterprise_repos
    run apt update || fail "apt update still failed. Check repositories manually."
  fi
}

upgrade_current_pve8() {
  step "Updating current Proxmox VE 8 packages"
  apt_update_safe
  run apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
  ok "Current PVE 8 packages updated."
}

disable_enterprise_repos() {
  step "Disabling enterprise repositories"
  local changed=0

  while IFS= read -r -d '' file; do
    if grep -q "enterprise.proxmox.com" "$file" 2>/dev/null; then
      run mv "$file" "${file}.disabled-${RUN_ID}"
      warn "Disabled enterprise repo file: $file"
      changed=1
    fi
  done < <(find /etc/apt/sources.list.d -type f \( -name "*.list" -o -name "*.sources" \) -print0 2>/dev/null)

  if grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
    run sed -i 's|^[[:space:]]*deb .*enterprise.proxmox.com|# disabled by pve8-to-pve9-upgrade: &|g' /etc/apt/sources.list
    warn "Disabled enterprise repo line in /etc/apt/sources.list"
    changed=1
  fi

  [[ "$changed" -eq 0 ]] && ok "No enterprise repository found." || ok "Enterprise repositories disabled."
}

ensure_bookworm_firmware_components() {
  step "Ensuring firmware repository components on PVE 8"
  if [[ "$(get_debian_codename)" != "bookworm" ]]; then
    warn "Skipping bookworm firmware component step because codename is not bookworm."
    return 0
  fi

  # This normalizes the Debian base repos only. Proxmox repo handling is done separately.
  run cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list.before-bookworm-normalize" 2>/dev/null || true
  run tee /etc/apt/sources.list >/dev/null <<'EOF2'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF2
  ok "Debian bookworm repos include contrib and non-free-firmware."
}

install_intel_microcode_if_needed() {
  step "Checking CPU microcode"
  if lscpu 2>/dev/null | grep -qi "GenuineIntel"; then
    info "Intel CPU detected. Installing intel-microcode if available."
    apt_update_safe
    if run apt-get install -y intel-microcode; then
      ok "intel-microcode installed or already present."
    else
      warn "intel-microcode installation failed. The Proxmox checker may report this. Continue only if you accept this risk."
      confirm "Continue without confirmed intel-microcode?" "YES" || fail "Stopped because intel-microcode could not be installed."
    fi
  else
    ok "Intel CPU not detected. Skipping intel-microcode."
  fi
}

fix_systemd_boot_leftover() {
  step "Checking bootloader package state"
  if dpkg -s systemd-boot >/dev/null 2>&1; then
    if [[ ! -f /etc/kernel/proxmox-boot-uuids ]]; then
      warn "systemd-boot package is installed, but proxmox-boot-tool is not configured."
      warn "This commonly blocks pve8to9 checks on GRUB-based installations."
      if confirm "Remove leftover systemd-boot package?" "YES"; then
        run apt-get remove -y systemd-boot
        ok "systemd-boot removed."
      else
        fail "Cannot continue while systemd-boot failure may remain unresolved."
      fi
    else
      ok "systemd-boot appears managed by proxmox-boot-tool. Not removing."
    fi
  else
    ok "systemd-boot package is not installed."
  fi
}

fix_grub_removable_path() {
  step "Checking GRUB removable EFI path"
  if [[ -d /boot/efi/EFI/BOOT ]] && dpkg -s grub-efi-amd64 >/dev/null 2>&1; then
    info "Applying GRUB removable EFI update setting."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections -v -u"
    else
      echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections -v -u
    fi
    run apt-get install --reinstall -y grub-efi-amd64
    run update-grub || true
    ok "GRUB removable EFI handling checked."
  else
    ok "No GRUB removable EFI action required."
  fi
}

run_pve8to9_check_or_stop() {
  step "Running pve8to9 --full"
  require_command pve8to9
  local output failures
  output="$(pve8to9 --full || true)"
  echo "$output"
  failures="$(echo "$output" | awk '/FAILURES:/ {print $2}' | tail -n1)"
  if [[ "${failures:-999}" == "0" ]]; then
    ok "pve8to9 reports zero failures."
  else
    fail "pve8to9 still reports failures. Fix them manually and rerun."
  fi
}

setup_trixie_repositories() {
  step "Configuring Debian 13 Trixie and Proxmox VE 9 repositories"

  run cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list.before-trixie" 2>/dev/null || true

  run tee /etc/apt/sources.list >/dev/null <<'EOF2'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF2

  disable_enterprise_repos

  run rm -f /etc/apt/sources.list.d/pve-install-repo.list
  run rm -f /etc/apt/sources.list.d/pve-no-subscription.list

  # Convert any leftover bookworm references in enabled source files.
  while IFS= read -r -d '' file; do
    run sed -i 's/bookworm/trixie/g' "$file"
  done < <(find /etc/apt/sources.list.d -type f \( -name "*.list" -o -name "*.sources" \) ! -name "*.disabled*" -print0 2>/dev/null)

  run tee /etc/apt/sources.list.d/pve-no-subscription.sources >/dev/null <<'EOF2'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF2

  ok "Trixie and PVE 9 no-subscription repositories configured."
}

perform_major_upgrade() {
  step "Performing Proxmox VE 9 upgrade"
  apt_update_safe
  warn "If a package prompt appears, the safest default is usually: keep the local version currently installed."
  run apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
  ok "Major package upgrade completed."
}

remove_duplicate_repo_files() {
  step "Cleaning duplicate repository files"
  if [[ -f /etc/apt/sources.list.d/pve-install-repo.list ]]; then
    run mv /etc/apt/sources.list.d/pve-install-repo.list "/root/pve-install-repo.list.disabled-${RUN_ID}"
    warn "Disabled old pve-install-repo.list"
  fi
  apt_update_safe
}

post_upgrade_validation() {
  step "Post-upgrade validation"
  pveversion || true
  uname -r || true
  cat /etc/os-release || true

  if command -v pve8to9 >/dev/null 2>&1; then
    pve8to9 --full || true
  fi

  systemctl status pveproxy pvedaemon pvestatd --no-pager || true
  ok "Validation completed. Review output above."
}

finish() {
  step "Final steps"
  run update-grub || true

  ok "Upgrade helper finished."
  info "Log file: $LOG_FILE"
  info "Backup directory: $BACKUP_DIR"

  if [[ "$AUTO_REBOOT" -eq 1 ]]; then
    warn "Auto reboot enabled. Rebooting now."
    run reboot
  else
    warn "Reboot is required to load the new Proxmox kernel."
    echo "Run: reboot"
    echo
    echo "After reboot, verify with:"
    echo "  pveversion"
    echo "  uname -r"
    echo "  pve8to9 --full"
  fi
}

main() {
  banner
  require_root
  safety_intro
  check_environment
  backup_configs
  check_cluster
  check_running_guests
  disable_enterprise_repos
  ensure_bookworm_firmware_components
  upgrade_current_pve8
  install_intel_microcode_if_needed
  fix_systemd_boot_leftover
  fix_grub_removable_path
  run_pve8to9_check_or_stop
  setup_trixie_repositories
  perform_major_upgrade
  remove_duplicate_repo_files
  install_intel_microcode_if_needed
  post_upgrade_validation
  finish
}

main "$@"
```
