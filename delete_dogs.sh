#!/usr/bin/env bash
# delete_dogs.sh
# Deletes Proxmox QEMU VMs whose VM name contains a pattern (default: "dog")
# Dry-run by default. Use --apply to actually delete.

set -euo pipefail

PATTERN=".dog"
KENNEL_PATTERN=".kennel"
APPLY=0
TIMEOUT=30

usage() {
  cat <<EOF
Usage:
  ./delete_dogs.sh [--pattern STR] [--apply] [--timeout SEC]

Defaults:
  --pattern  dog
  --timeout  30
  (dry-run unless --apply is set)

Examples:
  # Show what would be deleted (safe):
  ./delete_dogs.sh

  # Actually delete all VMs whose name contains ".dog":
  ./delete_dogs.sh --apply

  # Delete using a custom pattern:
  ./delete_dogs.sh --pattern myprefix --apply
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern|-p) PATTERN="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --timeout) TIMEOUT="${2:-30}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v qm >/dev/null || { echo "ERROR: qm not found. Run on a Proxmox node." >&2; exit 1; }

if (( EUID != 0 )); then
  echo "ERROR: please run as root (qm destroy needs root privileges)." >&2
  exit 1
fi

if [[ -z "$PATTERN" ]]; then
  echo "ERROR: --pattern cannot be empty." >&2
  exit 2
fi

# Collect VMIDs from qm list, then fetch names via qm config (robust even if list formatting changes)
mapfile -t VMIDS < <(qm list | awk 'NR>1 {print $1}')

dog_matches=()
kennel_matches=()
for id in "${VMIDS[@]}"; do
  name="$(qm config "$id" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}')"
  [[ -z "$name" ]] && continue
  if [[ "$name" == *"$KENNEL_PATTERN"* ]]; then
    kennel_matches+=("$id|$name")
  elif [[ "$name" == *"$PATTERN"* ]]; then
    dog_matches+=("$id|$name")
  fi
done

matches=()
[[ "${#dog_matches[@]}" -gt 0 ]] && matches+=("${dog_matches[@]}")
[[ "${#kennel_matches[@]}" -gt 0 ]] && matches+=("${kennel_matches[@]}")

if [[ "${#matches[@]}" -eq 0 ]]; then
  echo "No VMs found with pattern: \"$PATTERN\" or \"$KENNEL_PATTERN\""
  exit 0
fi

echo "Found ${#dog_matches[@]} dog VM(s) and ${#kennel_matches[@]} kennel VM(s):"
for m in "${matches[@]}"; do
  IFS='|' read -r id name <<< "$m"
  echo "  VMID $id  name: $name"
done
echo

if (( APPLY == 0 )); then
  echo "Dry-run only. Re-run with --apply to actually delete."
  echo
  echo "Would run (per VM, dogs first then kennel last):"
  echo "  qm shutdown <VMID> --timeout $TIMEOUT  (fallback to qm stop)"
  echo "  qm destroy <VMID> --purge 1 --destroy-unreferenced-disks 1 (fallback to qm destroy --purge 1)"
  exit 0
fi

echo "APPLY mode: deleting VMs now (dogs first, then kennel)..."
echo

# Delete dogs first
for m in "${dog_matches[@]}"; do
  IFS='|' read -r id name <<< "$m"
  echo "==> Deleting VMID $id ($name)"

  # Try graceful shutdown first
  qm shutdown "$id" --timeout "$TIMEOUT" >/dev/null 2>&1 || true

  # Ensure it's stopped
  qm stop "$id" >/dev/null 2>&1 || true

  # Destroy (try newer/safer flags first, fallback if not supported)
  if qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
    echo "    destroyed (purge + destroy-unreferenced-disks)"
  else
    qm destroy "$id" --purge 1 >/dev/null
    echo "    destroyed (purge)"
  fi
done

# Delete kennel last
for m in "${kennel_matches[@]}"; do
  IFS='|' read -r id name <<< "$m"
  echo "==> Deleting VMID $id ($name) [kennel - deleted last]"

  # Try graceful shutdown first
  qm shutdown "$id" --timeout "$TIMEOUT" >/dev/null 2>&1 || true

  # Ensure it's stopped
  qm stop "$id" >/dev/null 2>&1 || true

  # Destroy (try newer/safer flags first, fallback if not supported)
  if qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
    echo "    destroyed (purge + destroy-unreferenced-disks)"
  else
    qm destroy "$id" --purge 1 >/dev/null
    echo "    destroyed (purge)"
  fi
done

echo
echo "Done."
