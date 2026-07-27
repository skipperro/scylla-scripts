#!/usr/bin/env bash
# initialize_dogs_sh (phased)
#
# Phase 1: Start all matching VMs
# Phase 2: Wait for QEMU guest agent on each VM
# Phase 3: Wait extra settle time (default 20s)
# Phase 4: Apply changes in guest (longer timeout + retries)
# Phase 5: Reboot all + wait until they come back
#
# Requires: Windows QEMU Guest Agent installed + enabled (agent: 1).

set -euo pipefail

NODE_NAME="$(hostname -s 2>/dev/null || hostname)"
SERVICE_NAME="arcware-runner"

# Filtering
NAME_CONTAINS=".arcware.com"
ALL=0

# Timeouts / behavior
GA_TIMEOUT_SEC=900          # wait for GA to become available
SETTLE_SEC=60               # wait after VM start (changed from 20 to 60 for boot time)
CMD_TIMEOUT_SEC=600         # timeout for the "apply changes" PowerShell guest command
CMD_RETRIES=3               # retries for "apply changes" if guest command fails/timeouts
CMD_RETRY_SLEEP_SEC=15      # wait between retries

REBOOT_DOWN_WAIT_SEC=120    # wait for GA to go down after reboot triggers
REBOOT_WAIT_SEC=900         # wait for GA to come back after reboot

DRY_RUN=0
MAX_PARALLEL_JOBS=3         # max parallel jobs for apply changes
START_DELAY_SEC=3           # delay between VM starts to prevent resource spikes
SHUTDOWN_DELAY_SEC=3        # delay between VM shutdowns to prevent resource spikes

usage() {
  cat <<EOF
Usage:
  sudo ./initialize_dogs_sh [options]

Options:
  --node NAME              Override detected node name (default: $NODE_NAME)
  --service NAME           Windows service name (default: $SERVICE_NAME)
  --name-contains STR      Only process VMs whose Proxmox VM name contains STR (default: "$NAME_CONTAINS")
  --all                    Process ALL local QEMU VMs on this node (templates skipped)

  --ga-timeout SEC         Wait for guest agent (default: $GA_TIMEOUT_SEC)
  --settle SEC             Extra wait after GA is available (default: $SETTLE_SEC)

  --cmd-timeout SEC        Timeout for apply-changes command (default: $CMD_TIMEOUT_SEC)
  --cmd-retries N          Retries for apply-changes (default: $CMD_RETRIES)
  --cmd-retry-sleep SEC    Sleep between retries (default: $CMD_RETRY_SLEEP_SEC)

  --reboot-down-wait SEC   Wait for GA to go down after reboot (default: $REBOOT_DOWN_WAIT_SEC)
  --reboot-wait SEC        Wait for GA to return after reboot (default: $REBOOT_WAIT_SEC)

  --dry-run                Print actions, do not execute
  -h|--help                Help

Examples:
  sudo ./initialize_dogs_sh
  sudo ./initialize_dogs_sh --dry-run
  sudo ./initialize_dogs_sh --all --settle 30 --cmd-timeout 900
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)              NODE_NAME="${2:-}"; shift 2 ;;
    --service)           SERVICE_NAME="${2:-}"; shift 2 ;;
    --name-contains)     NAME_CONTAINS="${2:-}"; shift 2 ;;
    --all)               ALL=1; shift ;;

    --ga-timeout)        GA_TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --settle)            SETTLE_SEC="${2:-}"; shift 2 ;;

    --cmd-timeout)       CMD_TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --cmd-retries)       CMD_RETRIES="${2:-}"; shift 2 ;;
    --cmd-retry-sleep)   CMD_RETRY_SLEEP_SEC="${2:-}"; shift 2 ;;

    --reboot-down-wait)  REBOOT_DOWN_WAIT_SEC="${2:-}"; shift 2 ;;
    --reboot-wait)       REBOOT_WAIT_SEC="${2:-}"; shift 2 ;;

    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if (( EUID != 0 )); then
  echo "ERROR: run as root." >&2
  exit 1
fi

command -v qm >/dev/null || { echo "ERROR: qm not found. Run on a Proxmox node." >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    echo "+ $*"
  else
    "$@"
  fi
}

is_template() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | grep -qE '^template:\s*1'
}

get_vm_name() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/{print $2; exit}'
}

# PowerShell encoded command helpers (robust quoting)
ps_to_b64() {
  local script="$1"
  command -v iconv >/dev/null 2>&1 || return 1
  command -v base64 >/dev/null 2>&1 || return 1

  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    printf "%s" "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
  else
    printf "%s" "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
  fi
}

ps_escape_single_quotes() {
  # PowerShell single-quoted string: escape ' as ''
  local s="$1"
  printf "%s" "${s//\'/\'\'}"
}

ga_ok() {
  local vmid="$1"
  if (( DRY_RUN )); then
    return 0
  fi
  qm guest exec "$vmid" --timeout 10 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Output ok" >/dev/null 2>&1
}

wait_for_guest_agent() {
  local vmid="$1"
  if (( DRY_RUN )); then
    echo "DRY RUN: would wait for guest agent on VMID $vmid (up to ${GA_TIMEOUT_SEC}s)"
    return 0
  fi

  local deadline=$(( $(date +%s) + GA_TIMEOUT_SEC ))
  local last_msg=0
  while (( $(date +%s) < deadline )); do
    if ga_ok "$vmid"; then
      return 0
    fi
    local now=$(( $(date +%s) ))
    if (( now - last_msg >= 15 )); then
      echo "VMID $vmid: waiting for guest agent... ($((deadline-now))s left)"
      last_msg=$now
    fi
    sleep 5
  done
  return 1
}

wait_for_guest_agent_down() {
  local vmid="$1"
  if (( DRY_RUN )); then
    echo "DRY RUN: would wait for guest agent DOWN on VMID $vmid (up to ${REBOOT_DOWN_WAIT_SEC}s)"
    return 0
  fi

  local deadline=$(( $(date +%s) + REBOOT_DOWN_WAIT_SEC ))
  while (( $(date +%s) < deadline )); do
    if ! ga_ok "$vmid"; then
      return 0
    fi
    sleep 3
  done
  # Not fatal: sometimes GA doesn't drop cleanly / fast
  return 0
}

wait_for_guest_agent_after_reboot() {
  local vmid="$1"
  if (( DRY_RUN )); then
    echo "DRY RUN: would wait for guest agent AFTER reboot on VMID $vmid (up to ${REBOOT_WAIT_SEC}s)"
    return 0
  fi

  local deadline=$(( $(date +%s) + REBOOT_WAIT_SEC ))
  local last_msg=0
  while (( $(date +%s) < deadline )); do
    if ga_ok "$vmid"; then
      return 0
    fi
    local now=$(( $(date +%s) ))
    if (( now - last_msg >= 15 )); then
      echo "VMID $vmid: waiting after reboot... ($((deadline-now))s left)"
      last_msg=$now
    fi
    sleep 5
  done
  return 1
}

exec_ps_encoded_with_retries() {
  local vmid="$1"
  local ps_script="$2"

  local b64
  if ! b64="$(ps_to_b64 "$ps_script")"; then
    echo "ERROR: iconv/base64 not available; cannot safely run PowerShell encoded command." >&2
    return 1
  fi

  local attempt=1
  while (( attempt <= CMD_RETRIES )); do
    if (( DRY_RUN )); then
      echo "+ qm guest exec $vmid --timeout $CMD_TIMEOUT_SEC -- powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand <base64:${#b64}chars>"
      return 0
    fi

    if qm guest exec "$vmid" --timeout "$CMD_TIMEOUT_SEC" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$b64" >/dev/null; then
      return 0
    fi

    echo "VMID $vmid: apply-changes failed (attempt $attempt/$CMD_RETRIES)."
    if (( attempt < CMD_RETRIES )); then
      echo "VMID $vmid: sleeping ${CMD_RETRY_SLEEP_SEC}s and retrying..."
      sleep "$CMD_RETRY_SLEEP_SEC"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

echo "Node: $NODE_NAME"
echo "Service: $SERVICE_NAME"
if (( ALL == 1 )); then
  echo "Mode: ALL local VMs (templates skipped)"
else
  echo "Mode: only VMs with name containing: \"$NAME_CONTAINS\" (templates skipped)"
fi
echo "GA timeout: $GA_TIMEOUT_SEC s | Settle: $SETTLE_SEC s | Cmd timeout: $CMD_TIMEOUT_SEC s | Cmd retries: $CMD_RETRIES"
echo "Reboot wait: $REBOOT_WAIT_SEC s"
echo "Dry run: $DRY_RUN"
echo

mapfile -t ALL_VMIDS < <(qm list | awk 'NR>1 {print $1}' | sort -n)
if [[ "${#ALL_VMIDS[@]}" -eq 0 ]]; then
  echo "No local QEMU VMs found on this node."
  exit 0
fi

# Build match list
declare -A VMNAME_BY_ID=()
MATCHED_VMIDS=()

for vmid in "${ALL_VMIDS[@]}"; do
  if is_template "$vmid"; then
    continue
  fi

  vmname="$(get_vm_name "$vmid")"
  vmname="${vmname:-}"

  if (( ALL == 0 )); then
    if [[ -z "$vmname" || "$vmname" != *"$NAME_CONTAINS"* ]]; then
      continue
    fi
  fi

  VMNAME_BY_ID["$vmid"]="$vmname"
  MATCHED_VMIDS+=("$vmid")
done

if [[ "${#MATCHED_VMIDS[@]}" -eq 0 ]]; then
  echo "No matching VMs found on this node."
  exit 0
fi

echo "Matched VMIDs: ${MATCHED_VMIDS[*]}"
echo

# -----------------------
# Phase 1: Start all VMs in parallel
# -----------------------
echo "=== Phase 1/5: Start all matching VMs (parallel with ${START_DELAY_SEC}s delay) ==="
START_PIDS=()
VM_COUNT=0
for vmid in "${MATCHED_VMIDS[@]}"; do
  status="$(qm status "$vmid" 2>/dev/null || true)"
  if echo "$status" | grep -q "stopped"; then
    echo "VMID $vmid: starting (background)..."
    if (( DRY_RUN )); then
      echo "+ qm start $vmid"
    else
      qm start "$vmid" &
      START_PIDS+=("$!")
    fi
    VM_COUNT=$((VM_COUNT + 1))
    # Add delay between starts to prevent resource spikes
    if (( VM_COUNT < ${#MATCHED_VMIDS[@]} )) && (( START_DELAY_SEC > 0 )); then
      sleep "$START_DELAY_SEC"
    fi
  else
    echo "VMID $vmid: already running."
  fi
done

# Wait for all start commands to complete
if [[ "${#START_PIDS[@]}" -gt 0 ]]; then
  echo "Waiting for ${#START_PIDS[@]} VM start command(s) to complete..."
  for pid in "${START_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

echo

# --------------------------------------------
# Phase 2: Wait for guest agent on all VMs
# --------------------------------------------
echo "=== Phase 2/5: Wait for guest agent ==="
READY_VMIDS=()
for vmid in "${MATCHED_VMIDS[@]}"; do
  echo "VMID $vmid: waiting for guest agent..."
  if wait_for_guest_agent "$vmid"; then
    echo "VMID $vmid: guest agent OK"
    READY_VMIDS+=("$vmid")
  else
    echo "WARNING: VMID $vmid: guest agent not responding after ${GA_TIMEOUT_SEC}s. Skipping this VM." >&2
  fi
done
echo

if [[ "${#READY_VMIDS[@]}" -eq 0 ]]; then
  echo "No VMs became ready (guest agent). Nothing to do."
  exit 1
fi

# -------------------------------
# Phase 3: Global settle wait (already done in Phase 1)
# -------------------------------
echo "=== Phase 3/5: Settle ==="
sleep 20
echo

# -----------------------------
# Phase 4: Apply changes in parallel
# -----------------------------
echo "=== Phase 4/5: Apply changes in guest (parallel) ==="

# Function to apply changes to a single VM
apply_changes_to_vm() {
  local vmid="$1"
  local vmname="${VMNAME_BY_ID[$vmid]:-}"
  local desired_hostname="${NODE_NAME}-${vmid}"
  local vmname_to_write="${vmname:-$desired_hostname}"

  echo "VMID $vmid (${vmname:-<no name>}): applying changes..."
  echo "  Hostname -> $desired_hostname"
  echo "  vm-name.txt -> $vmname_to_write"

  local esc_host="$(ps_escape_single_quotes "$desired_hostname")"
  local esc_vmname="$(ps_escape_single_quotes "$vmname_to_write")"
  local esc_service="$(ps_escape_single_quotes "$SERVICE_NAME")"

  local ps_script=$(cat <<PS
\$NewHost = '$esc_host'
\$ProxmoxVmName = '$esc_vmname'

# Rename host if needed
if (\$env:COMPUTERNAME -ne \$NewHost) {
  Rename-Computer -NewName \$NewHost -Force -ErrorAction Stop
}

# Write Proxmox VM name
Set-Content -LiteralPath 'C:\\vm-name.txt' -Value \$ProxmoxVmName -Encoding ASCII

# Delete runner settings
Remove-Item -LiteralPath 'C:\\arcware-runner\\RunnerSettingsMS.json' -Force -ErrorAction SilentlyContinue

# Ensure service autostart with delayed start
try {
  Set-Service -Name '$esc_service' -StartupType Automatic -ErrorAction Stop
  # Set delayed auto-start using sc.exe
  \$result = sc.exe config '$esc_service' start=delayed-auto
  if (\$LASTEXITCODE -ne 0) {
    Write-Output "WARN: Could not set delayed start for service '$esc_service'."
  }
} catch {
  Write-Output "WARN: Service '$esc_service' not found or cannot be modified."
}
PS
)

  if exec_ps_encoded_with_retries "$vmid" "$ps_script"; then
    echo "$vmid" >> "/tmp/initialize_dogs_applied_$$.txt"
    echo "VMID $vmid: changes applied."
  else
    echo "WARNING: VMID $vmid: failed to apply changes after ${CMD_RETRIES} attempts. Skipping reboot for this VM." >&2
  fi
}

# Export functions and variables needed by subshells
export -f apply_changes_to_vm
export -f exec_ps_encoded_with_retries
export -f ps_to_b64
export -f ps_escape_single_quotes
export -f ga_ok
export -f run
export NODE_NAME SERVICE_NAME CMD_TIMEOUT_SEC CMD_RETRIES CMD_RETRY_SLEEP_SEC DRY_RUN
export VMNAME_BY_ID

# Create temporary file for tracking applied VMs
rm -f "/tmp/initialize_dogs_applied_$$.txt"
touch "/tmp/initialize_dogs_applied_$$.txt"

# Apply changes in parallel with job control
APPLY_PIDS=()
JOB_COUNT=0

for vmid in "${READY_VMIDS[@]}"; do
  # Wait if we've reached max parallel jobs
  while (( JOB_COUNT >= MAX_PARALLEL_JOBS )); do
    # Wait for any job to finish
    wait -n 2>/dev/null || true
    JOB_COUNT=$((JOB_COUNT - 1))
  done
  
  apply_changes_to_vm "$vmid" &
  APPLY_PIDS+=("$!")
  JOB_COUNT=$((JOB_COUNT + 1))
done

# Wait for all apply jobs to complete
echo "Waiting for all apply changes jobs to complete..."
for pid in "${APPLY_PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# Read results from temporary file
APPLIED_VMIDS=()
if [[ -f "/tmp/initialize_dogs_applied_$$.txt" ]]; then
  mapfile -t APPLIED_VMIDS < "/tmp/initialize_dogs_applied_$$.txt"
  rm -f "/tmp/initialize_dogs_applied_$$.txt"
fi

echo

if [[ "${#APPLIED_VMIDS[@]}" -eq 0 ]]; then
  echo "No VMs had changes applied successfully. Exiting."
  exit 1
fi

# -----------------------------
# Phase 5: Shutdown all (parallel, no wait)
# -----------------------------
echo "=== Phase 5/5: Shutdown all updated VMs (parallel with ${SHUTDOWN_DELAY_SEC}s delay) ==="

echo "Triggering shutdown on all updated VMs in parallel..."
SHUTDOWN_PIDS=()
VM_SHUTDOWN_COUNT=0
for vmid in "${APPLIED_VMIDS[@]}"; do
  (
    echo "VMID $vmid: shutting down..."
    if (( DRY_RUN )); then
      echo "+ qm shutdown $vmid"
    else
      if ! qm shutdown "$vmid" >/dev/null 2>&1; then
        echo "VMID $vmid: qm shutdown failed, trying guest Stop-Computer..."
        qm guest exec "$vmid" --timeout 60 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Stop-Computer -Force" >/dev/null 2>&1 || true
      fi
    fi
    echo "VMID $vmid: shutdown command sent."
  ) &
  SHUTDOWN_PIDS+=("$!")
  VM_SHUTDOWN_COUNT=$((VM_SHUTDOWN_COUNT + 1))
  
  # Add delay between shutdowns to prevent resource spikes
  if (( VM_SHUTDOWN_COUNT < ${#APPLIED_VMIDS[@]} )) && (( SHUTDOWN_DELAY_SEC > 0 )); then
    sleep "$SHUTDOWN_DELAY_SEC"
  fi
done

# Wait for all shutdown commands to be sent (not for the VMs to actually shutdown)
if [[ "${#SHUTDOWN_PIDS[@]}" -gt 0 ]]; then
  echo "Waiting for all shutdown commands to be sent..."
  for pid in "${SHUTDOWN_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
fi

echo
echo "All shutdown commands sent. VMs are shutting down in the background."
echo "All done."

# Ask if user wants to reboot the host
echo
if (( DRY_RUN )); then
  echo "DRY RUN: would ask about host reboot"
else
  read -r -p "Do you want to reboot the host now? [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY])
      echo "Rebooting host in 5 seconds... (Press Ctrl+C to cancel)"
      sleep 5
      echo "Rebooting now..."
      reboot
      ;;
    *)
      echo "Host reboot cancelled. Exiting."
      ;;
  esac
fi
