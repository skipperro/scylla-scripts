#!/usr/bin/env bash
# If someone runs: sh ./create_dogs.sh  -> re-run in bash automatically
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ----------------------------
# Defaults / CLI args
# ----------------------------
CORES_PER_GPU=0            # physical cores per VM (if set explicitly)
MAX_CORES_PER_GPU=16       # cap on physical cores per VM when CORES_PER_GPU is not set explicitly
RESERVED_CORES=16          # physical cores to keep unassigned (reserved for host) per NUMA node
HOST_RESERVED_RAM_PERCENT=20  # percent of total RAM to keep unassigned, reserved for the host
KENNEL_MEMORY_MB=8192      # RAM (MB) given to the kennel VM, always fixed regardless of host RAM size
FORMAT="human"

TEMPLATE_VMID=""
NAME_PREFIX="dog"
ENVIRONMENT="demuc01"         # <<< CHANGE THIS (e.g. dev/stage/prod/lab)
NODE_NAME_OVERRIDE=""      # override Proxmox node name (default: hostname -s)
TARGET_NODE=""             # qm clone --target NODE
STORAGE_ID=""              # qm clone --storage STORAGE
START_VMID=""              # start VMID, then increment
COUNT=""                   # limit number of VMs/GPUs
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  ./create_dogs.sh [options]

Core/GPU assignment options:
  --cores-per-gpu N      Physical cores per VM (SMT siblings included automatically).
                         Default: 0 = AUTO uniform mode (same for ALL VMs), capped by
                         --max-cores-per-gpu.
  --max-cores-per-gpu N  Maximum physical cores per VM when --cores-per-gpu is not set
                         explicitly (default: 16).
  --reserved-cores N     Physical cores to keep unassigned per NUMA node, reserved for
                         the host (default: 16). If the machine doesn't have enough
                         cores to honor both the reserved cores and the (max) cores per
                         GPU, cores assigned to each VM are reduced to keep the
                         reserved host cores at the configured level.
  --host-reserved-ram-percent N
                         Percent of total system RAM to keep unassigned, reserved for
                         the host (default: 20). The remaining RAM (minus the kennel
                         VM's fixed allocation) is distributed evenly across the GPU
                         (dog) VMs. The kennel VM always gets a fixed 8 GB regardless
                         of this setting.
  --format human|csv     Output format for the plan (default: human)

Proxmox clone/apply options (only used if --template-vmid is given):
  --template-vmid VMID   REQUIRED to create linked clones + write /etc/pve/qemu-server configs.
                         If omitted, defaults to the highest template VMID available on the node.
  --name-prefix STR      VM name prefix (default: dog)
  --node-name NAME       Override the Proxmox node name used in VM hostnames (default: hostname -s)
  --target-node NODE     qm clone --target NODE (optional)
  --storage STORAGE      qm clone --storage STORAGE (optional)
  --start-vmid VMID      Start VMIDs from this number (default: 1XXX00 where XXX is node number,
                         e.g. scylla3 -> 100300, scylla15 -> 101500; will increment, skipping existing)
  --count N              Only create/assign first N GPUs/VMs (optional)
  --dry-run              Print what would be executed, but do not change anything.

VM name format (when cloning):
  {proxmox-node-name}.{NAME_PREFIX}{i+1}.{ENVIRONMENT}.arcware.com
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cores-per-gpu|-c) CORES_PER_GPU="${2:-}"; shift 2 ;;
    --max-cores-per-gpu) MAX_CORES_PER_GPU="${2:-}"; shift 2 ;;
    --reserved-cores)   RESERVED_CORES="${2:-}"; shift 2 ;;
    --host-reserved-ram-percent) HOST_RESERVED_RAM_PERCENT="${2:-}"; shift 2 ;;
    --format|-f)        FORMAT="${2:-human}"; shift 2 ;;
    --template-vmid|-t) TEMPLATE_VMID="${2:-}"; shift 2 ;;
    --name-prefix)      NAME_PREFIX="${2:-}"; shift 2 ;;
    --node-name)        NODE_NAME_OVERRIDE="${2:-}"; shift 2 ;;
    --target-node)      TARGET_NODE="${2:-}"; shift 2 ;;
    --storage)          STORAGE_ID="${2:-}"; shift 2 ;;
    --start-vmid)       START_VMID="${2:-}"; shift 2 ;;
    --count)            COUNT="${2:-}"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --help|-h)          usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$CORES_PER_GPU" =~ ^[0-9]+$ ]]; then
  echo "--cores-per-gpu must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$MAX_CORES_PER_GPU" =~ ^[0-9]+$ ]] || (( MAX_CORES_PER_GPU < 1 )); then
  echo "--max-cores-per-gpu must be a positive integer" >&2
  exit 2
fi
if ! [[ "$RESERVED_CORES" =~ ^[0-9]+$ ]]; then
  echo "--reserved-cores must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$HOST_RESERVED_RAM_PERCENT" =~ ^[0-9]+$ ]] || (( HOST_RESERVED_RAM_PERCENT > 100 )); then
  echo "--host-reserved-ram-percent must be an integer between 0 and 100" >&2
  exit 2
fi
if [[ -n "$TEMPLATE_VMID" ]] && ! [[ "$TEMPLATE_VMID" =~ ^[0-9]+$ ]]; then
  echo "--template-vmid must be numeric" >&2
  exit 2
fi
if [[ -n "$START_VMID" ]] && ! [[ "$START_VMID" =~ ^[0-9]+$ ]]; then
  echo "--start-vmid must be numeric" >&2
  exit 2
fi
if [[ -n "$COUNT" ]] && ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "--count must be numeric" >&2
  exit 2
fi

# Proxmox node name = hostname (this matches Proxmox node name in almost all setups)
# Can be overridden with --node-name
if [[ -n "$NODE_NAME_OVERRIDE" ]]; then
  PVE_NODE_NAME="$NODE_NAME_OVERRIDE"
else
  PVE_NODE_NAME="$(hostname -s 2>/dev/null || hostname)"
fi

# Auto-detect START_VMID from node name if not provided: 1XXX00 where XXX is 3-digit node number
# e.g. scylla3 -> 100300, scylla15 -> 101500
if [[ -z "$START_VMID" ]]; then
  _node_num="$(echo "$PVE_NODE_NAME" | sed -E 's/^[^0-9]*([0-9]+)$/\1/')"
  if [[ "$_node_num" =~ ^[0-9]+$ ]]; then
    START_VMID="$(printf "1%03d00" "$_node_num")"
    echo "Auto-detected start VMID from node name '${PVE_NODE_NAME}': $START_VMID"
  fi
fi

command -v lspci >/dev/null || { echo "Missing lspci (pciutils)" >&2; exit 1; }

# If cloning/applying:
if [[ -n "$TEMPLATE_VMID" ]]; then
  command -v qm >/dev/null || { echo "Missing qm (Proxmox CLI) - are you on a Proxmox node?" >&2; exit 1; }
  [[ -d /etc/pve/qemu-server ]] || { echo "Missing /etc/pve/qemu-server - are you on Proxmox?" >&2; exit 1; }
fi

# Auto-detect template VMID when not provided: use the highest template VMID available
if [[ -z "$TEMPLATE_VMID" ]] && command -v qm >/dev/null 2>&1 && [[ -d /etc/pve/qemu-server ]]; then
  mapfile -t _tmpl_ids < <(
    grep -rl 'template: 1' /etc/pve/qemu-server/ 2>/dev/null \
      | sed -E 's#.*/([0-9]+)\.conf#\1#' | sort -n
  )
  if [[ "${#_tmpl_ids[@]}" -ge 1 ]]; then
    TEMPLATE_VMID="${_tmpl_ids[-1]}"
    echo "Auto-detected template VMID (highest available): $TEMPLATE_VMID"
  fi
fi

run() {
  if (( DRY_RUN )); then
    echo "+ $*"
  else
    "$@"
  fi
}

# ----------------------------
# Helpers
# ----------------------------

expand_cpulist() {
  local s="$1" part
  local out=()
  IFS=',' read -r -a parts <<< "$s"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      local i
      for ((i=a; i<=b; i++)); do out+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("$part")
    fi
  done
  printf "%s\n" "${out[@]}"
}

to_ranges() {
  local csv="$1"
  mapfile -t nums < <(printf "%s" "$csv" | tr ',' '\n' | sed '/^$/d' | sort -n | uniq)
  if [[ "${#nums[@]}" -eq 0 ]]; then
    echo ""
    return
  fi
  local ranges=()
  local start="${nums[0]}"
  local prev="${nums[0]}"
  local i cur
  for ((i=1; i<${#nums[@]}; i++)); do
    cur="${nums[$i]}"
    if (( cur == prev + 1 )); then
      prev="$cur"
    else
      if [[ "$start" == "$prev" ]]; then ranges+=("$start"); else ranges+=("$start-$prev"); fi
      start="$cur"; prev="$cur"
    fi
  done
  if [[ "$start" == "$prev" ]]; then ranges+=("$start"); else ranges+=("$start-$prev"); fi
  (IFS=','; echo "${ranges[*]}")
}

# Count vCPUs from "a,b,c" list
count_csv_items() {
  local csv="$1"
  if [[ -z "$csv" ]]; then
    echo 0
    return
  fi
  local -a arr
  IFS=',' read -r -a arr <<< "$csv"
  echo "${#arr[@]}"
}

find_nvidia_audio_bdf() {
  local vga_bdf="$1"
  local slot="${vga_bdf%.*}"   # 0000:43:00
  lspci -Dnn | awk -v slot="$slot" '
    $1 ~ ("^"slot"\\.") && /10de:/ && /Audio device/ { print $1; exit }
  '
}

gpu_numa_node() {
  local bdf="$1"
  local node="-1"
  if [[ -r "/sys/bus/pci/devices/${bdf}/numa_node" ]]; then
    node="$(cat "/sys/bus/pci/devices/${bdf}/numa_node" 2>/dev/null || echo -1)"
  fi
  [[ "$node" == "-1" || -z "$node" ]] && node="0"
  echo "$node"
}

next_vmid() {
  local id
  if [[ -n "$START_VMID" ]]; then
    id="$START_VMID"
    while [[ -e "/etc/pve/qemu-server/${id}.conf" ]]; do
      id=$(( id + 1 ))
    done
    START_VMID=$(( id + 1 ))
    echo "$id"
    return
  fi

  if command -v pvesh >/dev/null; then
    id="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '\r\n')"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
      while [[ -e "/etc/pve/qemu-server/${id}.conf" ]]; do
        id=$(( id + 1 ))
      done
      echo "$id"
      return
    fi
  fi

  id="$(ls /etc/pve/qemu-server/*.conf 2>/dev/null | sed -E 's#.*/([0-9]+)\.conf#\1#' | sort -n | tail -n1)"
  [[ -z "$id" ]] && id=100
  echo $(( id + 1 ))
}

# Compute an updated net0 line, preserving all existing net0 parameters
# (model, mac, vlan tag, rate limit, multiqueue, firewall, ...) except the bridge.
set_net0_bridge() {
  local conf="$1"
  local bridge="$2"

  local line
  line="$(grep -m1 '^net0:' "$conf" 2>/dev/null || true)"

  local value
  if [[ -z "$line" ]]; then
    # Safeguard only: cloned VMs inherit net0 from the template, so this
    # should not normally happen. Default to virtio (matches template model).
    echo "net0: virtio,bridge=${bridge}"
    return
  fi

  value="${line#net0: }"
  if [[ "$value" == *"bridge="* ]]; then
    value="$(printf '%s' "$value" | sed -E "s/bridge=[^,]*/bridge=${bridge}/")"
  else
    value="${value},bridge=${bridge}"
  fi
  echo "net0: ${value}"
}

# Apply: affinity + hostpci + sockets/cores matching affinity + network bridge + memory
apply_vm_config() {
  local vmid="$1"
  local affinity_ranges="$2"
  local vcpus="$3"
  local gpu_vga="$4"
  local gpu_audio="${5:-}"
  local memory="${6:-}"

  local conf="/etc/pve/qemu-server/${vmid}.conf"
  [[ -f "$conf" ]] || { echo "ERROR: Missing config $conf" >&2; return 1; }

  # Compute updated net0 (dog VMs, i.e. VMs with GPU, use vmbr1) before the file is rewritten
  local new_net0
  new_net0="$(set_net0_bridge "$conf" "vmbr1")"

  local tmp="/etc/pve/qemu-server/.${vmid}.conf.tmp.$$"

  # Filter out old lines we control
  awk '
    !/^hostpci[0-9]+:/ &&
    !/^affinity:/ &&
    !/^cores:/ &&
    !/^sockets:/ &&
    !/^memory:/ &&
    !/^onboot:/ &&
    !/^net0:/ { print }
  ' "$conf" > "$tmp"

  # Ensure numa: 1 exists
  if ! grep -q '^numa:' "$tmp"; then
    echo "numa: 1" >> "$tmp"
  fi

  # Enable start on boot
  echo "onboot: 1" >> "$tmp"

  # Force sockets=1 so total vCPUs == cores
  echo "sockets: 1" >> "$tmp"
  echo "cores: ${vcpus}" >> "$tmp"

  if [[ -n "$memory" ]]; then
    echo "memory: ${memory}" >> "$tmp"
  fi

  echo "affinity: ${affinity_ranges}" >> "$tmp"

  echo "hostpci0: ${gpu_vga},pcie=1" >> "$tmp"
  if [[ -n "$gpu_audio" ]]; then
    echo "hostpci1: ${gpu_audio},pcie=1" >> "$tmp"
  fi

  # Dog VMs (with GPU) get vmbr1
  echo "$new_net0" >> "$tmp"

  if (( DRY_RUN )); then
    echo "+ (would write) $conf"
    rm -f "$tmp"
  else
    mv -f "$tmp" "$conf"
  fi
}

# ----------------------------
# 1) Build physical core pool per NUMA node via sysfs
#    key = node:pkg:core -> list of logical CPUs (SMT siblings)
#    pool entry format per node: "mincpu|label|cpu,cpu"
# ----------------------------
declare -A GROUP_CPUS
declare -A KEY_NODE

shopt -s nullglob
NODE_DIRS=(/sys/devices/system/node/node[0-9]*)
if [[ "${#NODE_DIRS[@]}" -eq 0 ]]; then
  echo "No NUMA nodes found in /sys/devices/system/node/. Is NUMA enabled?" >&2
  exit 1
fi

for nd in "${NODE_DIRS[@]}"; do
  node="${nd##*/node}"
  cpulist="$(<"$nd/cpulist")"
  mapfile -t cpus < <(expand_cpulist "$cpulist")

  for cpu in "${cpus[@]}"; do
    topo="/sys/devices/system/cpu/cpu${cpu}/topology"
    [[ -r "$topo/core_id" && -r "$topo/physical_package_id" ]] || continue
    core_id="$(<"$topo/core_id")"
    pkg_id="$(<"$topo/physical_package_id")"
    key="${node}:${pkg_id}:${core_id}"
    GROUP_CPUS["$key"]+="${GROUP_CPUS[$key]:+ }${cpu}"
    KEY_NODE["$key"]="$node"
  done
done

declare -A NODE_POOL
declare -A NODE_PHYS_COUNT

for key in "${!GROUP_CPUS[@]}"; do
  node="${KEY_NODE[$key]}"
  mapfile -t sorted_cpus < <(printf "%s\n" ${GROUP_CPUS[$key]} | sort -n)
  mincpu="${sorted_cpus[0]}"
  cpus_csv="$(printf "%s\n" "${sorted_cpus[@]}" | paste -sd, -)"
  label="${key#*:}"  # pkg:core (internal)
  NODE_POOL["$node"]+="${mincpu}|${label}|${cpus_csv}"$'\n'
done

for node in "${!NODE_POOL[@]}"; do
  mapfile -t entries < <(printf "%s" "${NODE_POOL[$node]}" | sed '/^$/d' | sort -n -t'|' -k1,1)
  NODE_POOL["$node"]="$(printf "%s\n" "${entries[@]}")"$'\n'
  NODE_PHYS_COUNT["$node"]="${#entries[@]}"
done

# ----------------------------
# 2) Detect NVIDIA GPUs and their NUMA node
# ----------------------------
mapfile -t GPU_BDFS < <(
  lspci -Dnn | awk '/10de:/ && ($0 ~ /VGA compatible controller/ || $0 ~ /3D controller/) {print $1}'
)

if [[ "${#GPU_BDFS[@]}" -eq 0 ]]; then
  echo "No NVIDIA VGA/3D controllers found." >&2
  exit 0
fi

declare -a GPU_DESC GPU_NODE GPU_AUDIO
for bdf in "${GPU_BDFS[@]}"; do
  GPU_DESC+=( "$(lspci -s "$bdf" 2>/dev/null || echo "NVIDIA device $bdf")" )
  GPU_NODE+=( "$(gpu_numa_node "$bdf")" )
  GPU_AUDIO+=( "$(find_nvidia_audio_bdf "$bdf")" )
done

# limit
if [[ -n "$COUNT" ]]; then
  if (( COUNT < ${#GPU_BDFS[@]} )); then
    GPU_BDFS=("${GPU_BDFS[@]:0:COUNT}")
    GPU_DESC=("${GPU_DESC[@]:0:COUNT}")
    GPU_NODE=("${GPU_NODE[@]:0:COUNT}")
    GPU_AUDIO=("${GPU_AUDIO[@]:0:COUNT}")
  fi
fi

# group GPU indices by node
declare -A NODE_GPUS
for i in "${!GPU_BDFS[@]}"; do
  NODE_GPUS["${GPU_NODE[$i]}"]+="$i "
done

# ----------------------------
# 3) Decide UNIFORM physical cores per VM
#
#    DESIRED_PHYS_PER_VM is the target cores/VM: the explicit --cores-per-gpu value
#    if given, otherwise --max-cores-per-gpu (default 16).
#
#    On each NUMA node, RESERVED_CORES physical cores are kept unassigned for the
#    host. If a node doesn't have enough cores to give every VM the desired amount
#    while keeping RESERVED_CORES free, the per-VM core count is reduced (never the
#    reserved amount) so the host still keeps its configured reserved cores.
# ----------------------------
if (( ${#NODE_GPUS[@]} == 0 )); then
  echo "ERROR: no NUMA node with a detected GPU; cannot compute cores per VM." >&2
  exit 1
fi

if (( CORES_PER_GPU > 0 )); then
  DESIRED_PHYS_PER_VM="$CORES_PER_GPU"
else
  DESIRED_PHYS_PER_VM="$MAX_CORES_PER_GPU"
fi

UNIFORM_PHYS_PER_VM=999999
for node in "${!NODE_GPUS[@]}"; do
  read -r -a gpu_idxs <<< "${NODE_GPUS[$node]}"
  gcount="${#gpu_idxs[@]}"
  (( gcount == 0 )) && continue
  phys_total="${NODE_PHYS_COUNT[$node]:-0}"

  available=$(( phys_total - RESERVED_CORES ))
  (( available < 0 )) && available=0

  node_max_per_vm=$(( available / gcount ))
  node_per_vm="$DESIRED_PHYS_PER_VM"
  if (( node_max_per_vm < node_per_vm )); then
    if (( CORES_PER_GPU > 0 )); then
      echo "WARNING: --cores-per-gpu=$CORES_PER_GPU requested, but NUMA node $node only has $phys_total physical cores for $gcount GPU(s) after reserving $RESERVED_CORES for the host. Reducing cores/VM on this node to $node_max_per_vm." >&2
    fi
    node_per_vm="$node_max_per_vm"
  fi

  if (( node_per_vm < 1 )); then
    echo "ERROR: NUMA node $node has $phys_total physical cores; cannot reserve $RESERVED_CORES for the host and still assign at least 1 core per VM to $gcount GPU(s) there." >&2
    exit 1
  fi

  (( node_per_vm < UNIFORM_PHYS_PER_VM )) && UNIFORM_PHYS_PER_VM="$node_per_vm"
done

if (( UNIFORM_PHYS_PER_VM == 999999 )); then
  echo "ERROR: cannot allocate at least 1 physical core per VM uniformly." >&2
  exit 1
fi

# ----------------------------
# 4) Assign exactly UNIFORM_PHYS_PER_VM physical cores per VM, per NUMA node
# ----------------------------
declare -a GPU_ASSIGNED_PHYS GPU_ASSIGNED_CPUS GPU_ASSIGNED_AFFINITY GPU_ASSIGNED_VCPUS
for ((i=0; i<${#GPU_BDFS[@]}; i++)); do
  GPU_ASSIGNED_PHYS[i]=""
  GPU_ASSIGNED_CPUS[i]=""
  GPU_ASSIGNED_AFFINITY[i]=""
  GPU_ASSIGNED_VCPUS[i]=0
done

for node in "${!NODE_GPUS[@]}"; do
  pool="${NODE_POOL[$node]:-}"
  [[ -z "$pool" ]] && { echo "Warning: no CPU pool for NUMA node $node; GPUs there get none." >&2; continue; }

  mapfile -t ENTRIES < <(printf "%s" "$pool" | sed '/^$/d')
  phys_total="${#ENTRIES[@]}"

  read -r -a gpu_idxs <<< "${NODE_GPUS[$node]}"
  gcount="${#gpu_idxs[@]}"
  need=$(( gcount * UNIFORM_PHYS_PER_VM ))
  if (( need > phys_total )); then
    echo "ERROR: internal: NUMA node $node pool has $phys_total phys cores but need $need" >&2
    exit 1
  fi

  cursor=0
  for gi in "${gpu_idxs[@]}"; do
    phys_list=""
    cpu_list=""

    for entry in "${ENTRIES[@]:cursor:UNIFORM_PHYS_PER_VM}"; do
      IFS='|' read -r mincpu _label cpus_csv <<< "$entry"
      phys_list+="${phys_list:+,}${mincpu}"
      cpu_list+="${cpu_list:+,}${cpus_csv}"
    done

    GPU_ASSIGNED_PHYS[$gi]="$phys_list"
    GPU_ASSIGNED_CPUS[$gi]="$cpu_list"
    GPU_ASSIGNED_AFFINITY[$gi]="$(to_ranges "$cpu_list")"
    GPU_ASSIGNED_VCPUS[$gi]="$(count_csv_items "$cpu_list")"

    cursor=$(( cursor + UNIFORM_PHYS_PER_VM ))
  done
done

# Safety: ensure no logical CPU is assigned more than once
all_cpus="$(printf "%s\n" "${GPU_ASSIGNED_CPUS[@]}" | tr ',' '\n' | sed '/^$/d')"
dups="$(printf "%s\n" "$all_cpus" | sort -n | uniq -d)"
if [[ -n "$dups" ]]; then
  echo "ERROR: CPU overlap detected! These CPUs are assigned more than once:" >&2
  echo "$dups" >&2
  exit 1
fi

# ----------------------------
# 5) Decide RAM per VM
#
#    HOST_RESERVED_RAM_PERCENT of total system RAM is kept unassigned for the host.
#    The kennel VM always gets a fixed KENNEL_MEMORY_MB (8 GB by default). Whatever
#    RAM remains after those two reservations is split evenly across all GPU (dog) VMs.
# ----------------------------
command -v free >/dev/null 2>&1 || { echo "Missing 'free' (procps) - needed to detect total RAM" >&2; exit 1; }

TOTAL_RAM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
if ! [[ "$TOTAL_RAM_MB" =~ ^[0-9]+$ ]] || (( TOTAL_RAM_MB <= 0 )); then
  echo "ERROR: could not determine total system RAM." >&2
  exit 1
fi

DOG_VM_COUNT="${#GPU_BDFS[@]}"
if (( DOG_VM_COUNT <= 0 )); then
  echo "ERROR: no GPU VMs to distribute RAM to." >&2
  exit 1
fi

HOST_RESERVED_RAM_MB=$(( TOTAL_RAM_MB * HOST_RESERVED_RAM_PERCENT / 100 ))
AVAILABLE_RAM_MB=$(( TOTAL_RAM_MB - HOST_RESERVED_RAM_MB - KENNEL_MEMORY_MB ))

if (( AVAILABLE_RAM_MB <= 0 )); then
  echo "ERROR: no RAM left for GPU VMs after reserving ${HOST_RESERVED_RAM_PERCENT}% (${HOST_RESERVED_RAM_MB} MB) for the host and ${KENNEL_MEMORY_MB} MB for the kennel VM (total RAM: ${TOTAL_RAM_MB} MB)." >&2
  exit 1
fi

PER_VM_MEMORY_MB=$(( AVAILABLE_RAM_MB / DOG_VM_COUNT ))

if (( PER_VM_MEMORY_MB < 1 )); then
  echo "ERROR: cannot allocate at least 1 MB of RAM per GPU VM ($DOG_VM_COUNT VMs, ${AVAILABLE_RAM_MB} MB available)." >&2
  exit 1
fi

# ----------------------------
# 6) Print plan
# ----------------------------
if [[ "$FORMAT" == "csv" ]]; then
  echo "gpu_index,pci_bdf,numa_node,phys_per_vm,physical_cores(primary_cpu_id),logical_cpus,vcpus,memory_mb,affinity_ranges,audio_bdf,description"
  for i in "${!GPU_BDFS[@]}"; do
    desc="${GPU_DESC[$i]//\"/\"\"}"
    echo "${i},${GPU_BDFS[$i]},${GPU_NODE[$i]},${UNIFORM_PHYS_PER_VM},\"${GPU_ASSIGNED_PHYS[$i]}\",\"${GPU_ASSIGNED_CPUS[$i]}\",${GPU_ASSIGNED_VCPUS[$i]},${PER_VM_MEMORY_MB},\"${GPU_ASSIGNED_AFFINITY[$i]}\",\"${GPU_AUDIO[$i]}\",\"${desc}\""
  done
else
  echo "Detected NVIDIA GPUs: ${#GPU_BDFS[@]}"
  echo
  for node in "${!NODE_PHYS_COUNT[@]}"; do
    echo "NUMA node $node: physical cores in pool = ${NODE_PHYS_COUNT[$node]}"
  done
  echo
  echo "Uniform physical cores per VM: $UNIFORM_PHYS_PER_VM (max-cores-per-gpu=$MAX_CORES_PER_GPU, reserved-cores=$RESERVED_CORES)"
  echo
  echo "Total system RAM: ${TOTAL_RAM_MB} MB"
  echo "Host reserved RAM: ${HOST_RESERVED_RAM_MB} MB (${HOST_RESERVED_RAM_PERCENT}%)"
  echo "Kennel VM RAM: ${KENNEL_MEMORY_MB} MB (fixed)"
  echo "RAM per GPU VM: ${PER_VM_MEMORY_MB} MB (evenly split across ${DOG_VM_COUNT} VMs)"
  echo

  for i in "${!GPU_BDFS[@]}"; do
    echo "GPU ${i}: ${GPU_DESC[$i]}"
    echo "  PCI BDF   : ${GPU_BDFS[$i]}"
    echo "  NUMA node : ${GPU_NODE[$i]}"
    echo "  Physical cores (primary CPU id) : ${GPU_ASSIGNED_PHYS[$i]:-(none)}"
    echo "  Logical CPUs (SMT siblings)     : ${GPU_ASSIGNED_CPUS[$i]:-(none)}"
    echo "  vCPUs (for Proxmox cores=)      : ${GPU_ASSIGNED_VCPUS[$i]}"
    echo "  Memory (for Proxmox memory=)    : ${PER_VM_MEMORY_MB} MB"
    echo "  Affinity (ranges)              : ${GPU_ASSIGNED_AFFINITY[$i]:-(none)}"
    echo "  GPU audio function (optional)  : ${GPU_AUDIO[$i]:-(none)}"
    echo
  done
fi

# ----------------------------
# 7) If template VMID given: clone VMs + apply affinity + GPU passthrough + vCPU count
# ----------------------------
if [[ -z "$TEMPLATE_VMID" ]]; then
  exit 0
fi

if (( EUID != 0 )); then
  echo "ERROR: cloning/editing /etc/pve requires root. Please run as root." >&2
  exit 1
fi

if ! qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  echo "ERROR: template VMID $TEMPLATE_VMID not found (qm status failed)." >&2
  exit 1
fi

echo
echo "=== APPLY MODE: creating linked clones from template VMID $TEMPLATE_VMID ==="
echo "Dry run: $DRY_RUN"
echo "Node name: $PVE_NODE_NAME"
echo "Environment: $ENVIRONMENT"
echo

# ----------------------------
# 7a) Create kennel VM (shared drive manager, no GPU, minimal resources)
# ----------------------------
KENNEL_CORES=8

kennel_id="$(next_vmid)"
kennel_name="${PVE_NODE_NAME}.kennel.${ENVIRONMENT}.arcware.com"

cmd=(qm clone "$TEMPLATE_VMID" "$kennel_id" --name "$kennel_name" --full 0)
[[ -n "$TARGET_NODE" ]] && cmd+=(--target "$TARGET_NODE")
[[ -n "$STORAGE_ID" ]] && cmd+=(--storage "$STORAGE_ID")

echo "Creating kennel VM $kennel_id with name=$kennel_name (no GPU, ${KENNEL_CORES} cores, ${KENNEL_MEMORY_MB}MB RAM)"
run "${cmd[@]}"

run qm unlock "$kennel_id" || true

# Apply minimal config for kennel (no GPU passthrough, no NUMA affinity, vmbr0 network)
apply_kennel_config() {
  local vmid="$1"
  local cores="$2"
  local memory="$3"

  local conf="/etc/pve/qemu-server/${vmid}.conf"
  [[ -f "$conf" ]] || { echo "ERROR: Missing config $conf" >&2; return 1; }

  # Compute updated net0 (kennel VM, i.e. no GPU, uses vmbr0) before the file is rewritten
  local new_net0
  new_net0="$(set_net0_bridge "$conf" "vmbr0")"

  local tmp="/etc/pve/qemu-server/.${vmid}.conf.tmp.$$"

  # Filter out old lines we control
  awk '
    !/^hostpci[0-9]+:/ &&
    !/^affinity:/ &&
    !/^cores:/ &&
    !/^sockets:/ &&
    !/^numa:/ &&
    !/^memory:/ &&
    !/^onboot:/ &&
    !/^net0:/ { print }
  ' "$conf" > "$tmp"

  echo "onboot: 1" >> "$tmp"
  echo "sockets: 1" >> "$tmp"
  echo "cores: ${cores}" >> "$tmp"
  echo "memory: ${memory}" >> "$tmp"

  # Kennel VM (no GPU) gets vmbr0
  echo "$new_net0" >> "$tmp"

  if (( DRY_RUN )); then
    echo "+ (would write) $conf"
    rm -f "$tmp"
  else
    mv -f "$tmp" "$conf"
  fi
}

apply_kennel_config "$kennel_id" "$KENNEL_CORES" "$KENNEL_MEMORY_MB"

echo "  -> VMID $kennel_id done (kennel: minimal config, no GPU)"
echo

# ----------------------------
# 7b) Create dog VMs with GPU passthrough
# ----------------------------
for i in "${!GPU_BDFS[@]}"; do
  aff="${GPU_ASSIGNED_AFFINITY[$i]}"
  vcpus="${GPU_ASSIGNED_VCPUS[$i]}"
  vga="${GPU_BDFS[$i]}"
  aud="${GPU_AUDIO[$i]:-}"

  if [[ -z "$aff" || "$vcpus" -le 0 ]]; then
    echo "WARNING: GPU $i has no computed affinity/vcpus; skipping." >&2
    continue
  fi

  newid="$(next_vmid)"
  idx=$(( i + 1 ))
  vmname="${PVE_NODE_NAME}.${NAME_PREFIX}${idx}.${ENVIRONMENT}.arcware.com"

  cmd=(qm clone "$TEMPLATE_VMID" "$newid" --name "$vmname" --full 0)
  [[ -n "$TARGET_NODE" ]] && cmd+=(--target "$TARGET_NODE")
  [[ -n "$STORAGE_ID" ]] && cmd+=(--storage "$STORAGE_ID")

  echo "Creating VM $newid for GPU $i ($vga) with name=$vmname vCPUs=$vcpus memory=${PER_VM_MEMORY_MB}MB affinity=$aff"
  run "${cmd[@]}"

  run qm unlock "$newid" || true

  apply_vm_config "$newid" "$aff" "$vcpus" "$vga" "$aud" "$PER_VM_MEMORY_MB"

  echo "  -> VMID $newid done (cores/sockets + memory + affinity + hostpci applied)"
  echo
done

echo "All done."
