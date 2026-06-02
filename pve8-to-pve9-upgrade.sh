#!/usr/bin/env bash
# pve8-to-pve9-upgrade.sh
# Interactive Proxmox VE 8.x -> 9.x upgrade helper
# v2.0.0 - Ceph-aware safety checks

set -Eeuo pipefail

VERSION="2.0.0"
SCRIPT_NAME="$(basename -- "${0:-pve8-to-pve9-upgrade.sh}")"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
TIMESTAMP="$(date +%F-%H%M%S)"
LOG="/root/pve8-to-pve9-upgrade-${TIMESTAMP}.log"
BACKUP_DIR="/root/pve8-to-pve9-backup-${TIMESTAMP}"

ASSUME_YES=0
DRY_RUN=0
ALLOW_CLUSTER=0
ALLOW_CEPH=0
AUTO_REBOOT=0
SKIP_GUEST_CHECK=0
SKIP_MICROCODE=0
STAGE="full"

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"
exec > >(tee -a "$LOG") 2>&1

info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }
section(){ echo; echo -e "${BOLD}==== $* ====${RESET}"; }

usage(){ cat <<USAGE
$SCRIPT_NAME v$VERSION

Interactive Proxmox VE 8.x -> 9.x upgrade helper.

USAGE:
  bash $SCRIPT_NAME [options]

OPTIONS:
  --dry-run              Show checks/actions without changing repos or upgrading
  --yes                  Non-interactive where safe; still stops on hard risks
  --allow-cluster        Allow running on a Proxmox cluster node
  --allow-ceph           Allow running when local hyper-converged Ceph is detected
  --auto-reboot          Reboot automatically at the end if upgrade succeeds
  --skip-guest-check     Do not stop for running VMs/CTs
  --skip-microcode       Do not attempt to install intel/amd microcode
  --stage precheck       Only run prechecks and backups
  --stage repos          Only configure repositories for PVE 9/Trixie
  --stage upgrade        Only run apt update/dist-upgrade and post checks
  --stage full           Default: precheck + repos + upgrade
  -h, --help             Show this help

EXAMPLES:
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)"
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --dry-run
  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Bostame/pve8-to-pve9-upgrade/main/pve8-to-pve9-upgrade.sh)" -- --allow-cluster --allow-ceph

IMPORTANT:
  For Ceph clusters, upgrade Ceph to Squid 19.2+ on PVE 8 first.
  Then upgrade Proxmox nodes one by one.
USAGE
}

run(){ if [[ "$DRY_RUN" -eq 1 ]]; then echo "[DRY-RUN] $*"; else "$@"; fi; }
confirm_text(){
  local expected="$1" message="$2"
  [[ "$ASSUME_YES" -eq 1 ]] && { warn "Auto-confirm enabled for: $message"; return 0; }
  echo; warn "$message"; read -r -p "Type ${expected} to continue: " answer
  [[ "$answer" == "$expected" ]] || fail "Cancelled by user."
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1;; --yes) ASSUME_YES=1;; --allow-cluster) ALLOW_CLUSTER=1;; --allow-ceph) ALLOW_CEPH=1;;
      --auto-reboot) AUTO_REBOOT=1;; --skip-guest-check) SKIP_GUEST_CHECK=1;; --skip-microcode) SKIP_MICROCODE=1;;
      --stage) STAGE="${2:-}"; shift;; -h|--help) usage; exit 0;; *) fail "Unknown option: $1";;
    esac; shift
  done
  case "$STAGE" in precheck|repos|upgrade|full) ;; *) fail "Invalid --stage value: $STAGE";; esac
}

require_root(){ [[ "$EUID" -eq 0 ]] || fail "Run as root."; }
print_banner(){ section "Proxmox VE 8 -> 9 Upgrade Helper v$VERSION"; echo "Host: $HOSTNAME_SHORT"; echo "Log: $LOG"; echo "Backup: $BACKUP_DIR"; echo "Stage: $STAGE"; echo "Dry-run: $DRY_RUN"; echo "Ceph mode: $ALLOW_CEPH"; }

detect_pve_version(){
  command -v pveversion >/dev/null 2>&1 || fail "pveversion not found. This does not look like a Proxmox VE host."
  PVEVERSION_RAW="$(pveversion | head -n1 || true)"
  PVE_MAJOR="$(echo "$PVEVERSION_RAW" | awk -F/ '/pve-manager/ {print $2}' | cut -d. -f1)"
  echo "Detected: $PVEVERSION_RAW"
  if [[ "$PVE_MAJOR" == "9" ]]; then ok "This host already runs Proxmox VE 9."; elif [[ "$PVE_MAJOR" != "8" ]]; then fail "This script supports only Proxmox VE 8 -> 9. Detected: $PVEVERSION_RAW"; fi
}

backup_configs(){
  section "Backup important configs"; run mkdir -p "$BACKUP_DIR"
  for path in /etc/apt /etc/pve /etc/network /etc/default/grub /etc/fstab /etc/hosts /etc/hostname /etc/kernel /etc/ceph; do
    [[ -e "$path" ]] && run cp -a "$path" "$BACKUP_DIR/" || true
  done
  ok "Backup step completed."
}

check_subscription_repos(){ section "APT repository scan"; grep -R --line-number -E "enterprise.proxmox.com|download.proxmox.com|bookworm|trixie" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true; }

check_cluster(){
  section "Cluster detection"
  if command -v pvecm >/dev/null 2>&1 && pvecm status >/tmp/pvecm-status.$$ 2>/dev/null; then
    cat /tmp/pvecm-status.$$ || true
    if grep -q "Nodes:[[:space:]]*[2-9]" /tmp/pvecm-status.$$ || grep -q "Quorate:[[:space:]]*Yes" /tmp/pvecm-status.$$; then
      [[ "$ALLOW_CLUSTER" -eq 1 ]] || fail "Cluster detected. Re-run with --allow-cluster after reading the cluster upgrade guide."
      warn "Cluster mode enabled. Upgrade one node at a time and maintain quorum."
    else ok "No multi-node cluster detected."; fi
  else ok "Standalone or cluster status not available."; fi
  rm -f /tmp/pvecm-status.$$ || true
}

has_local_ceph(){
  command -v ceph >/dev/null 2>&1 || return 1
  systemctl list-units --type=service --all 2>/dev/null | grep -Eq 'ceph-(mon|mgr|osd|mds|rgw)@|ceph.target' && return 0
  [[ -d /etc/ceph ]] && ceph -s >/dev/null 2>&1 && return 0
  return 1
}

check_ceph(){
  section "Ceph safety checks"
  if ! has_local_ceph; then ok "No local/hyper-converged Ceph detected."; return 0; fi
  warn "Ceph detected on this node."
  ceph -s || fail "Could not read Ceph status."
  ceph versions || true
  CEPH_VERSION="$(ceph --version | awk '{print $3}' || true)"; CEPH_MAJOR="$(echo "$CEPH_VERSION" | cut -d. -f1)"
  echo "Detected Ceph version: ${CEPH_VERSION:-unknown}"
  [[ -n "$CEPH_MAJOR" && "$CEPH_MAJOR" -ge 19 ]] || fail "Ceph must be upgraded to Squid 19.2+ before Proxmox VE 9. Current: ${CEPH_VERSION:-unknown}"
  if ! ceph -s | grep -q "HEALTH_OK"; then
    warn "Ceph is not HEALTH_OK."
    [[ "$ALLOW_CEPH" -eq 1 ]] || fail "Ceph health is not OK. Fix Ceph first, or re-run with --allow-ceph only if safe."
    confirm_text "CEPH-OK" "Ceph is not HEALTH_OK. Continue only if this warning is understood and safe."
  fi
  [[ "$ALLOW_CEPH" -eq 1 ]] || fail "Ceph detected. Re-run with --allow-ceph after confirming Ceph Squid 19.2+, HEALTH_OK, and one-node upgrade plan."
  warn "Ceph workflow reminder: upgrade one node at a time, migrate guests away, consider 'ceph osd set noout', and unset noout after all nodes are done."
  echo "Optional HA maintenance: ha-manager crm-command node-maintenance enable $HOSTNAME_SHORT"
  confirm_text "CEPH-READY" "Confirm this node is ready for Ceph-aware one-node upgrade."
}

check_running_guests(){
  section "Running guests"; [[ "$SKIP_GUEST_CHECK" -eq 1 ]] && { warn "Skipping running guest check."; return 0; }
  running_vms="$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1":"$2}' || true)"
  running_cts="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1":"$3}' || true)"
  if [[ -n "$running_vms" || -n "$running_cts" ]]; then
    warn "Running guests detected."; [[ -n "$running_vms" ]] && echo "VMs:" && echo "$running_vms"; [[ -n "$running_cts" ]] && echo "CTs:" && echo "$running_cts"
    confirm_text "GUESTS-OK" "Stop/migrate guests where possible. Continue only if intentional."
  else ok "No running guests detected."; fi
}

update_pve8_base(){ section "Update current PVE 8 base"; [[ "$PVE_MAJOR" == "9" ]] && { ok "Already on PVE 9; skipping."; return; }; run apt update; run apt dist-upgrade -y; }

fix_systemd_boot_leftover(){
  section "Bootloader checks"
  if dpkg -l systemd-boot >/dev/null 2>&1 && [[ ! -f /etc/kernel/proxmox-boot-uuids ]]; then warn "Removing leftover systemd-boot package."; run apt remove -y systemd-boot || warn "Could not remove systemd-boot automatically."; fi
  if [[ -d /boot/efi/EFI/BOOT ]] && dpkg -l grub-efi-amd64 >/dev/null 2>&1; then
    info "Ensuring GRUB can update removable EFI fallback path."
    if [[ "$DRY_RUN" -eq 1 ]]; then echo "[DRY-RUN] debconf-set-selections grub removable"; else echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections -v -u; fi
    run apt install --reinstall -y grub-efi-amd64 || warn "GRUB reinstall did not complete."; run update-grub || warn "update-grub failed or not applicable."
  fi
}

run_pve8to9_precheck(){
  section "pve8to9 precheck"; command -v pve8to9 >/dev/null 2>&1 || fail "pve8to9 tool not found."
  out="$(pve8to9 --full || true)"; echo "$out"
  echo "$out" | grep -q "FAILURES: 0" && ok "pve8to9 reports no failures." || fail "pve8to9 reports failures. Fix them manually, then rerun. Log: $LOG"
}

disable_enterprise_repos(){
  section "Disable enterprise repositories"
  find /etc/apt/sources.list.d/ -type f \( -name "*.list" -o -name "*.sources" \) -print0 2>/dev/null | while IFS= read -r -d '' file; do
    if grep -q "enterprise.proxmox.com" "$file"; then run mv "$file" "${file}.disabled.${TIMESTAMP}"; warn "Disabled $file"; fi
  done
  if grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then run sed -i.bak-"$TIMESTAMP" 's|^deb .*enterprise.proxmox.com|# &|g' /etc/apt/sources.list; warn "Commented enterprise lines in /etc/apt/sources.list"; fi
}

convert_repos_to_trixie(){
  section "Configure Debian Trixie repositories"; run mkdir -p /etc/apt/sources.list.d
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "[DRY-RUN] would replace bookworm with trixie in APT source files"; else find /etc/apt/ -type f \( -name "*.list" -o -name "*.sources" \) -print0 | while IFS= read -r -d '' file; do sed -i.bak-"$TIMESTAMP" 's/bookworm/trixie/g' "$file"; done; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "[DRY-RUN] would write /etc/apt/sources.list"; else cat > /etc/apt/sources.list <<'SRC'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
SRC
  fi
  ok "Debian repos prepared."
}

setup_pve9_repo(){
  section "Configure Proxmox VE 9 no-subscription repository"; run rm -f /etc/apt/sources.list.d/pve-install-repo.list /etc/apt/sources.list.d/pve-no-subscription.list
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "[DRY-RUN] would write pve-no-subscription.sources"; else cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC
  fi
  ok "PVE no-subscription repo prepared."
}

install_microcode(){
  section "CPU microcode"; [[ "$SKIP_MICROCODE" -eq 1 ]] && { warn "Skipping microcode installation."; return; }
  if lscpu | grep -qi "GenuineIntel"; then info "Intel CPU detected."; run apt update; run apt install -y intel-microcode || warn "intel-microcode install failed.";
  elif lscpu | grep -qi "AuthenticAMD"; then info "AMD CPU detected."; run apt update; run apt install -y amd64-microcode || warn "amd64-microcode install failed.";
  else warn "Could not determine CPU vendor; skipping microcode."; fi
}

upgrade_packages(){ section "Upgrade packages"; warn "During config prompts, normally keep the local version currently installed."; confirm_text "UPGRADE" "Ready to run apt update and apt dist-upgrade for Proxmox VE 9?"; run apt update; run apt dist-upgrade -y; }
cleanup_repos(){ section "Repository cleanup"; [[ -f /etc/apt/sources.list.d/pve-install-repo.list ]] && run mv /etc/apt/sources.list.d/pve-install-repo.list "/root/pve-install-repo.list.disabled.${TIMESTAMP}"; run apt update || warn "apt update still has warnings/errors."; }

post_checks(){
  section "Post-upgrade checks"; pveversion || true; uname -r || true; cat /etc/os-release || true; systemctl status pveproxy pvedaemon pvestatd --no-pager || true; run update-grub || warn "update-grub failed or not applicable."
  command -v pve8to9 >/dev/null 2>&1 && pve8to9 --full || true
  if has_local_ceph; then section "Post-upgrade Ceph status"; ceph -s || true; ceph versions || true; warn "If you set noout manually, unset it only after all nodes are upgraded and Ceph is healthy: ceph osd unset noout"; fi
}

final_message(){
  section "Finished"; ok "Script finished."; echo "Log file: $LOG"; echo "Backup dir: $BACKUP_DIR"
  if [[ "$AUTO_REBOOT" -eq 1 && "$DRY_RUN" -eq 0 ]]; then warn "Auto reboot enabled. Rebooting now..."; reboot; else warn "Reboot manually when ready:"; echo "  reboot"; echo; warn "After reboot, verify:"; echo "  pveversion"; echo "  uname -r"; echo "  pve8to9 --full"; has_local_ceph && echo "  ceph -s"; fi
}

main(){
  parse_args "$@"; require_root; print_banner; detect_pve_version
  if [[ "$STAGE" == "precheck" || "$STAGE" == "full" ]]; then confirm_text "I-HAVE-BACKUPS" "Confirm you have valid VM/CT and Proxmox configuration backups."; backup_configs; check_subscription_repos; check_cluster; check_ceph; check_running_guests; update_pve8_base; fix_systemd_boot_leftover; run_pve8to9_precheck; fi
  if [[ "$STAGE" == "repos" || "$STAGE" == "full" ]]; then disable_enterprise_repos; convert_repos_to_trixie; setup_pve9_repo; install_microcode; fi
  if [[ "$STAGE" == "upgrade" || "$STAGE" == "full" ]]; then upgrade_packages; cleanup_repos; post_checks; final_message; else ok "Stage '$STAGE' completed."; echo "Log file: $LOG"; fi
}
main "$@"
