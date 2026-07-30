#!/usr/bin/env bash
# setup_host.sh
# Enables IOMMU & VFIO on a Proxmox/Debian host with an AMD CPU:
#   1. Edit /etc/default/grub to add "amd_iommu=on iommu=pt" to GRUB_CMDLINE_LINUX_DEFAULT
#   2. Run update-grub to apply the change
#   3. Load VFIO kernel modules (vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd) via /etc/modules
#   4. Optionally reboot to apply everything
#
# Idempotent: safe to run multiple times, existing settings are preserved/updated in place.
# A backup of each modified file is created before any change (*.bak.<timestamp>).

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"
VFIO_MODULES=(vfio vfio_iommu_type1 vfio_pci vfio_virqfd)
IOMMU_PARAMS="amd_iommu=on iommu=pt"

DRY_RUN=0
DO_REBOOT=0

usage() {
  cat <<EOF
Usage:
  sudo ./setup_host.sh [options]

Configures GRUB and kernel modules to enable IOMMU & VFIO passthrough on an
AMD-CPU host, following the documented setup steps:
  - GRUB_CMDLINE_LINUX_DEFAULT gets "${IOMMU_PARAMS}" appended (in ${GRUB_FILE})
  - update-grub is run to apply the change
  - vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd are added to ${MODULES_FILE}

Options:
  --reboot       Reboot the host automatically after applying changes.
  --dry-run      Print what would change, without modifying anything.
  --help, -h     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)   DO_REBOOT=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if (( EUID != 0 )) && (( ! DRY_RUN )); then
  echo "ERROR: this script must be run as root (it edits ${GRUB_FILE} and ${MODULES_FILE})." >&2
  exit 1
fi

run() {
  if (( DRY_RUN )); then
    echo "+ $*"
  else
    "$@"
  fi
}

backup_file() {
  local file="$1"
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  if [[ -f "$file" ]]; then
    run cp -a "$file" "${file}.bak.${ts}"
    echo "Backed up ${file} -> ${file}.bak.${ts}"
  fi
}

# ----------------------------
# 1) Edit GRUB: ensure GRUB_CMDLINE_LINUX_DEFAULT contains amd_iommu=on iommu=pt
# ----------------------------
[[ -f "$GRUB_FILE" ]] || { echo "ERROR: ${GRUB_FILE} not found. Is this a Debian/Proxmox host?" >&2; exit 1; }

echo "== Step 1/2: Configuring GRUB (${GRUB_FILE}) =="

current_line="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)"
current_value=""
if [[ -n "$current_line" ]]; then
  current_value="$(sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="?(.*)"?$/\1/' <<< "$current_line")"
  current_value="${current_value%\"}"
  current_value="${current_value#\"}"
fi
[[ -z "$current_value" ]] && current_value="quiet"

new_value="$current_value"
for param in $IOMMU_PARAMS; do
  key="${param%%=*}"
  if [[ "$new_value" =~ (^|[[:space:]])${key}= ]]; then
    # Update existing key=value in place
    new_value="$(sed -E "s/(^|[[:space:]])${key}=[^[:space:]]*/\1${param}/" <<< "$new_value")"
  else
    new_value="${new_value} ${param}"
  fi
done
# Normalize whitespace
new_value="$(echo "$new_value" | xargs)"
new_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_value}\""

if [[ "$current_line" == "$new_line" ]]; then
  echo "GRUB_CMDLINE_LINUX_DEFAULT already set correctly: ${new_line}"
else
  backup_file "$GRUB_FILE"
  if (( DRY_RUN )); then
    echo "+ (would set) ${new_line}"
  else
    if [[ -n "$current_line" ]]; then
      sed -i -E "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*#${new_line//\//\\/}#" "$GRUB_FILE"
    else
      echo "$new_line" >> "$GRUB_FILE"
    fi
  fi
  echo "Set: ${new_line}"
fi

command -v update-grub >/dev/null || { echo "ERROR: update-grub not found." >&2; exit 1; }
echo "Applying GRUB configuration..."
run update-grub

# ----------------------------
# 2) Load VFIO kernel modules via /etc/modules
# ----------------------------
echo
echo "== Step 2/2: Configuring VFIO kernel modules (${MODULES_FILE}) =="

[[ -f "$MODULES_FILE" ]] || run touch "$MODULES_FILE"

modules_to_add=()
for mod in "${VFIO_MODULES[@]}"; do
  if [[ -f "$MODULES_FILE" ]] && grep -qE "^${mod}\$" "$MODULES_FILE" 2>/dev/null; then
    echo "Module already present in ${MODULES_FILE}: ${mod}"
  else
    modules_to_add+=("$mod")
  fi
done

if [[ "${#modules_to_add[@]}" -gt 0 ]]; then
  backup_file "$MODULES_FILE"
  if (( DRY_RUN )); then
    for mod in "${modules_to_add[@]}"; do
      echo "+ (would add) ${mod} to ${MODULES_FILE}"
    done
  else
    {
      for mod in "${modules_to_add[@]}"; do
        echo "$mod"
      done
    } >> "$MODULES_FILE"
    echo "Added modules to ${MODULES_FILE}: ${modules_to_add[*]}"
  fi
else
  echo "All VFIO modules already configured."
fi

echo
echo "GRUB and VFIO module configuration complete."

if (( DO_REBOOT )); then
  echo "Rebooting now to apply changes..."
  run reboot
else
  echo "A reboot is required for the changes to take effect. Run 'reboot' (or re-run with --reboot) when ready."
fi
