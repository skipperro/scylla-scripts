#!/usr/bin/env bash
# delete_dogs.sh
# Deletes Proxmox QEMU VMs whose VM name contains a pattern (default: "dog")
# Dry-run by default. Use --apply to actually delete.
#
# Parallelized: sends shutdown to all VMs simultaneously, waits once for the
# timeout, then destroys all in parallel. Much faster than sequential deletion.

set -euo pipefail

PATTERN=".dog"
KENNEL_PATTERN=".kennel"
APPLY=0
TIMEOUT=30
MAX_PARALLEL=4

usage() {
  cat <<EOF
Usage:
  ./delete_dogs.sh [--pattern STR] [--apply] [--timeout SEC] [--parallel N]

Defaults:
  --pattern   dog
  --timeout   30
  --parallel  4
  (dry-run unless --apply is set)

Examples:
  # Show what would be deleted (safe):
  ./delete_dogs.sh

  # Actually delete all VMs whose name contains ".dog":
  ./delete_dogs.sh --apply

  # Delete using a custom pattern:
  ./delete_dogs.sh --pattern myprefix --apply

  # Delete with higher parallelism:
  ./delete_dogs.sh --apply --parallel 8
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern|-p) PATTERN="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --timeout) TIMEOUT="${2:-30}"; shift 2 ;;
    --parallel) MAX_PARALLEL="${2:-4}"; shift 2 ;;
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
  echo "Would run (dogs first then kennel last, parallelized up to $MAX_PARALLEL at a time):"
  echo "  1. qm shutdown <all VMIDs> in parallel"
  echo "  2. Wait ${TIMEOUT}s for graceful shutdown"
  echo "  3. qm stop <still-running VMIDs> in parallel"
  echo "  4. qm destroy <all VMIDs> --purge 1 --destroy-unreferenced-disks 1 in parallel"
  exit 0
fi

# --- Helper: delete a batch of VMs in parallel ---
# Sends shutdown to all, waits once, force-stops stragglers, then destroys all in parallel.
delete_batch() {
  local label="$1"
  shift
  local batch=("$@")

  if [[ "${#batch[@]}" -eq 0 ]]; then
    return
  fi

  echo "=== Deleting ${#batch[@]} ${label} VM(s) in parallel (max $MAX_PARALLEL concurrent) ==="
  echo

  # Step 1: Send shutdown to all VMs in parallel
  echo "--- Sending shutdown to all ${label} VMs ---"
  local shutdown_pids=()
  local job_count=0
  for m in "${batch[@]}"; do
    IFS='|' read -r id name <<< "$m"
    while (( job_count >= MAX_PARALLEL )); do
      wait -n 2>/dev/null || true
      job_count=$((job_count - 1))
    done
    (
      qm shutdown "$id" --timeout "$TIMEOUT" >/dev/null 2>&1 || true
    ) &
    shutdown_pids+=("$!")
    job_count=$((job_count + 1))
    echo "  VMID $id ($name): shutdown signal sent"
  done

  # Wait for all shutdown commands to finish (they have their own internal timeout)
  for pid in "${shutdown_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  echo "  All shutdown commands completed."
  echo

  # Step 2: Force-stop any VMs that are still running
  echo "--- Force-stopping any remaining VMs ---"
  local stop_pids=()
  job_count=0
  for m in "${batch[@]}"; do
    IFS='|' read -r id name <<< "$m"
    while (( job_count >= MAX_PARALLEL )); do
      wait -n 2>/dev/null || true
      job_count=$((job_count - 1))
    done
    (
      qm stop "$id" >/dev/null 2>&1 || true
    ) &
    stop_pids+=("$!")
    job_count=$((job_count + 1))
  done
  for pid in "${stop_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  echo "  All VMs stopped."
  echo

  # Step 3: Destroy all VMs in parallel
  echo "--- Destroying all ${label} VMs ---"
  local destroy_pids=()
  job_count=0
  for m in "${batch[@]}"; do
    IFS='|' read -r id name <<< "$m"
    while (( job_count >= MAX_PARALLEL )); do
      wait -n 2>/dev/null || true
      job_count=$((job_count - 1))
    done
    (
      if qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
        echo "  VMID $id ($name): destroyed (purge + destroy-unreferenced-disks)"
      else
        qm destroy "$id" --purge 1 >/dev/null 2>&1
        echo "  VMID $id ($name): destroyed (purge)"
      fi
    ) &
    destroy_pids+=("$!")
    job_count=$((job_count + 1))
  done
  for pid in "${destroy_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  echo "  All ${label} VMs destroyed."
  echo
}

echo "APPLY mode: deleting VMs now (dogs first, then kennel)..."
echo "Parallelism: up to $MAX_PARALLEL concurrent operations"
echo

# Delete dogs first, then kennels
delete_batch "dog" "${dog_matches[@]}"
delete_batch "kennel" "${kennel_matches[@]}"

echo "Done."
