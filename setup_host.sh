#!/usr/bin/env bash
# setup_host.sh
# Enables IOMMU & VFIO on a Proxmox/Debian host with an AMD CPU:
#   1. Edit /etc/default/grub to add "amd_iommu=on iommu=pt" to GRUB_CMDLINE_LINUX_DEFAULT
#   2. Run update-grub to apply the change
#   3. Load VFIO kernel modules (vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd) via /etc/modules
#   4. Create a Linux bridge ("repo", 10.200.0.1/24) on the host for the repository network
#   5. Install & configure Samba to share a "repository" folder over the network
#   6. Install & configure dnsmasq to serve DHCP on the "repo" bridge, then restart it
#   7. Tune the backing ZFS dataset for throughput (recordsize, compression, atime, xattr, dnodesize)
#   8. Optionally reboot to apply everything
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

SMB_CONF="/etc/samba/smb.conf"
SHARE_NAME="repository"
SHARE_PATH="/shared-repository"
SMB_USER="smbguest"
SMB_GROUP="nogroup"
ZFS_DATASET="shared-repository"

INTERFACES_FILE="/etc/network/interfaces"
BRIDGE_NAME="repo"
BRIDGE_CIDR="10.200.0.1/24"

DNSMASQ_CONF="/etc/dnsmasq.d/repo.conf"
DHCP_RANGE_START="10.200.0.100"
DHCP_RANGE_END="10.200.0.200"
DHCP_LEASE_TIME="12h"
DHCP_DNS_SERVERS="1.1.1.1,8.8.8.8"

DRY_RUN=0
DO_REBOOT=0
SKIP_SAMBA=0
SKIP_ZFS=0
SKIP_BRIDGE=0
SKIP_DHCP=0

usage() {
  cat <<EOF
Usage:
  sudo ./setup_host.sh [options]

Configures GRUB, kernel modules, Samba and ZFS to enable IOMMU & VFIO
passthrough plus a shared "repository" network folder on an AMD-CPU host,
following the documented setup steps:
  - GRUB_CMDLINE_LINUX_DEFAULT gets "${IOMMU_PARAMS}" appended (in ${GRUB_FILE})
  - update-grub is run to apply the change
  - vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd are added to ${MODULES_FILE}
  - A Linux bridge named "${BRIDGE_NAME}" is created with static address
    ${BRIDGE_CIDR}, no bridge ports, autostart enabled and VLAN-awareness
    disabled (in ${INTERFACES_FILE})
  - Samba is installed and a guest-accessible "${SHARE_NAME}" share is configured
    for ${SHARE_PATH} (in ${SMB_CONF}), served by the "${SMB_USER}" user
  - dnsmasq is installed and configured to serve DHCP (only) on the
    "${BRIDGE_NAME}" bridge (in ${DNSMASQ_CONF}), then restarted; the DHCP
    gateway/netmask are derived from ${BRIDGE_CIDR}, and the pool defaults to
    ${DHCP_RANGE_START}-${DHCP_RANGE_END}
  - The "${ZFS_DATASET}" ZFS dataset is tuned for throughput (recordsize,
    compression, atime, xattr, dnodesize)

Options:
  --reboot              Reboot the host automatically after applying changes.
  --dry-run             Print what would change, without modifying anything.
  --skip-samba          Do not install/configure Samba.
  --skip-zfs            Do not apply the ZFS tuning properties.
  --skip-bridge         Do not create/configure the "${BRIDGE_NAME}" Linux bridge.
  --skip-dhcp           Do not install/configure the dnsmasq DHCP server.
  --share-path PATH     Path to share via Samba (default: ${SHARE_PATH}).
  --zfs-dataset NAME    ZFS dataset to tune (default: ${ZFS_DATASET}).
  --bridge-name NAME    Name of the Linux bridge to create (default: ${BRIDGE_NAME}).
  --bridge-cidr CIDR    Static IPv4/CIDR for the bridge (default: ${BRIDGE_CIDR}).
                        Also used as the DHCP gateway/netmask; update
                        --dhcp-range-start/--dhcp-range-end to match if changed.
  --dhcp-range-start IP Start of the DHCP address pool (default: ${DHCP_RANGE_START}).
  --dhcp-range-end IP   End of the DHCP address pool (default: ${DHCP_RANGE_END}).
  --help, -h            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)           DO_REBOOT=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --skip-samba)       SKIP_SAMBA=1; shift ;;
    --skip-zfs)         SKIP_ZFS=1; shift ;;
    --skip-bridge)      SKIP_BRIDGE=1; shift ;;
    --skip-dhcp)        SKIP_DHCP=1; shift ;;
    --share-path)       SHARE_PATH="$2"; shift 2 ;;
    --zfs-dataset)      ZFS_DATASET="$2"; shift 2 ;;
    --bridge-name)      BRIDGE_NAME="$2"; shift 2 ;;
    --bridge-cidr)      BRIDGE_CIDR="$2"; shift 2 ;;
    --dhcp-range-start) DHCP_RANGE_START="$2"; shift 2 ;;
    --dhcp-range-end)   DHCP_RANGE_END="$2"; shift 2 ;;
    --help|-h)      usage; exit 0 ;;
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

# Converts a CIDR prefix length (e.g. 24) to a dotted-decimal netmask (e.g. 255.255.255.0).
prefix_to_netmask() {
  local prefix="$1" octets=() i
  for ((i = 0; i < 4; i++)); do
    if (( prefix >= 8 )); then
      octets+=(255)
      prefix=$((prefix - 8))
    elif (( prefix > 0 )); then
      octets+=($((256 - 2 ** (8 - prefix))))
      prefix=0
    else
      octets+=(0)
    fi
  done
  echo "${octets[0]}.${octets[1]}.${octets[2]}.${octets[3]}"
}

# ----------------------------
# 1) Edit GRUB: ensure GRUB_CMDLINE_LINUX_DEFAULT contains amd_iommu=on iommu=pt
# ----------------------------
[[ -f "$GRUB_FILE" ]] || { echo "ERROR: ${GRUB_FILE} not found. Is this a Debian/Proxmox host?" >&2; exit 1; }

echo "== Step 1/7: Configuring GRUB (${GRUB_FILE}) =="

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
echo "== Step 2/7: Configuring VFIO kernel modules (${MODULES_FILE}) =="

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

# ----------------------------
# 3) Create a Linux bridge for the repository network
# ----------------------------
if (( SKIP_BRIDGE )); then
  echo
  echo "== Step 3/7: Linux bridge configuration skipped (--skip-bridge) =="
else
  echo
  echo "== Step 3/7: Configuring Linux bridge '${BRIDGE_NAME}' (${BRIDGE_CIDR}) =="

  [[ -f "$INTERFACES_FILE" ]] || { echo "ERROR: ${INTERFACES_FILE} not found. Is this a Debian/Proxmox host?" >&2; exit 1; }

  BRIDGE_BEGIN="# BEGIN ${BRIDGE_NAME} bridge (managed by setup_host.sh)"
  BRIDGE_END="# END ${BRIDGE_NAME} bridge (managed by setup_host.sh)"
  bridge_block="$(cat <<EOF
${BRIDGE_BEGIN}
auto ${BRIDGE_NAME}
iface ${BRIDGE_NAME} inet static
    address ${BRIDGE_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware no
${BRIDGE_END}
EOF
)"

  bridge_changed=0
  if grep -qF "$BRIDGE_BEGIN" "$INTERFACES_FILE" 2>/dev/null; then
    existing_block="$(sed -n "/^${BRIDGE_BEGIN//\//\\/}\$/,/^${BRIDGE_END//\//\\/}\$/p" "$INTERFACES_FILE")"
    if [[ "$existing_block" == "$bridge_block" ]]; then
      echo "Linux bridge '${BRIDGE_NAME}' already up to date in ${INTERFACES_FILE}."
    else
      backup_file "$INTERFACES_FILE"
      if (( DRY_RUN )); then
        echo "+ (would update) '${BRIDGE_NAME}' bridge block in ${INTERFACES_FILE}"
      else
        awk -v b="$BRIDGE_BEGIN" -v e="$BRIDGE_END" -v block="$bridge_block" '
          $0==b {print block; skip=1; next}
          skip && $0==e {skip=0; next}
          skip {next}
          {print}
        ' "$INTERFACES_FILE" > "${INTERFACES_FILE}.tmp" && mv "${INTERFACES_FILE}.tmp" "$INTERFACES_FILE"
      fi
      echo "Updated '${BRIDGE_NAME}' bridge block in ${INTERFACES_FILE}."
      bridge_changed=1
    fi
  else
    backup_file "$INTERFACES_FILE"
    if (( DRY_RUN )); then
      echo "+ (would append) '${BRIDGE_NAME}' bridge block to ${INTERFACES_FILE}"
    else
      { echo; echo "$bridge_block"; } >> "$INTERFACES_FILE"
    fi
    echo "Added '${BRIDGE_NAME}' bridge block to ${INTERFACES_FILE}."
    bridge_changed=1
  fi

  if (( bridge_changed )) && ! (( DRY_RUN )); then
    if command -v ifreload >/dev/null 2>&1; then
      run ifreload -a
      echo "Applied networking changes with ifreload."
    else
      echo "NOTE: 'ifreload' not found; run 'systemctl restart networking' (or reboot) to bring up '${BRIDGE_NAME}'." >&2
    fi
  fi

  echo "Linux bridge '${BRIDGE_NAME}' configured with ${BRIDGE_CIDR}."
fi

# ----------------------------
# 4) Install & configure Samba share for the repository folder
# ----------------------------
if (( SKIP_SAMBA )); then
  echo
  echo "== Step 4/7: Samba configuration skipped (--skip-samba) =="
else
  echo
  echo "== Step 4/7: Configuring Samba share '${SHARE_NAME}' (${SHARE_PATH}) =="

  if ! command -v smbd >/dev/null 2>&1 || ! command -v smbpasswd >/dev/null 2>&1; then
    echo "Installing samba..."
    run env DEBIAN_FRONTEND=noninteractive apt-get update -y
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y samba
  else
    echo "Samba already installed."
  fi

  if ! getent group "$SMB_GROUP" >/dev/null 2>&1; then
    echo "Creating group ${SMB_GROUP}..."
    run groupadd "$SMB_GROUP"
  else
    echo "Group already exists: ${SMB_GROUP}"
  fi

  if ! id -u "$SMB_USER" >/dev/null 2>&1; then
    echo "Creating guest user ${SMB_USER}..."
    run useradd --system --no-create-home --shell /usr/sbin/nologin -g "$SMB_GROUP" "$SMB_USER"
  else
    echo "User already exists: ${SMB_USER}"
  fi

  if [[ ! -d "$SHARE_PATH" ]]; then
    echo "Creating share directory ${SHARE_PATH}..."
    run mkdir -p "$SHARE_PATH"
  else
    echo "Share directory already exists: ${SHARE_PATH}"
  fi
  run chown "${SMB_USER}:${SMB_GROUP}" "$SHARE_PATH"
  run chmod 0777 "$SHARE_PATH"

  [[ -f "$SMB_CONF" ]] || run touch "$SMB_CONF"

  if ! grep -qE '^\s*map to guest\s*=' "$SMB_CONF" 2>/dev/null; then
    backup_file "$SMB_CONF"
    if (( DRY_RUN )); then
      echo "+ (would add) 'map to guest = Bad User' to [global] in ${SMB_CONF}"
    else
      if grep -qE '^\s*\[global\]' "$SMB_CONF" 2>/dev/null; then
        sed -i -E '0,/^\s*\[global\]/s//[global]\n   map to guest = Bad User/' "$SMB_CONF"
      else
        { echo "[global]"; echo "   map to guest = Bad User"; echo; cat "$SMB_CONF"; } > "${SMB_CONF}.tmp" && mv "${SMB_CONF}.tmp" "$SMB_CONF"
      fi
    fi
    echo "Ensured 'map to guest = Bad User' is set in [global]."
  else
    echo "'map to guest' already configured in [global]."
  fi

  SHARE_BEGIN="# BEGIN ${SHARE_NAME} share (managed by setup_host.sh)"
  SHARE_END="# END ${SHARE_NAME} share (managed by setup_host.sh)"
  share_block="$(cat <<EOF
${SHARE_BEGIN}
[${SHARE_NAME}]
   path = ${SHARE_PATH}

   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes

   force user = ${SMB_USER}
   force group = ${SMB_GROUP}

   create mask = 0777
   force create mode = 0111
   directory mask = 0777
   force directory mode = 0711

   inherit acls = yes
   ea support = yes
   store dos attributes = yes

   case sensitive = no
   preserve case = yes
   acl allow execute always = yes
${SHARE_END}
EOF
)"

  if grep -qF "$SHARE_BEGIN" "$SMB_CONF" 2>/dev/null; then
    existing_block="$(sed -n "/^${SHARE_BEGIN//\//\\/}\$/,/^${SHARE_END//\//\\/}\$/p" "$SMB_CONF")"
    if [[ "$existing_block" == "$share_block" ]]; then
      echo "Samba share '${SHARE_NAME}' already up to date in ${SMB_CONF}."
    else
      backup_file "$SMB_CONF"
      if (( DRY_RUN )); then
        echo "+ (would update) [${SHARE_NAME}] share block in ${SMB_CONF}"
      else
        awk -v b="$SHARE_BEGIN" -v e="$SHARE_END" -v block="$share_block" '
          $0==b {print block; skip=1; next}
          skip && $0==e {skip=0; next}
          skip {next}
          {print}
        ' "$SMB_CONF" > "${SMB_CONF}.tmp" && mv "${SMB_CONF}.tmp" "$SMB_CONF"
      fi
      echo "Updated [${SHARE_NAME}] share block in ${SMB_CONF}."
    fi
  else
    backup_file "$SMB_CONF"
    if (( DRY_RUN )); then
      echo "+ (would append) [${SHARE_NAME}] share block to ${SMB_CONF}"
    else
      { echo; echo "$share_block"; } >> "$SMB_CONF"
    fi
    echo "Added [${SHARE_NAME}] share block to ${SMB_CONF}."
  fi

  if ! (( DRY_RUN )) && command -v testparm >/dev/null 2>&1; then
    testparm -s "$SMB_CONF" >/dev/null || echo "WARNING: testparm reported issues with ${SMB_CONF}." >&2
  fi

  if ! (( DRY_RUN )) && command -v pdbedit >/dev/null 2>&1 && ! pdbedit -L 2>/dev/null | grep -q "^${SMB_USER}:"; then
    run smbpasswd -a -n "$SMB_USER"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run systemctl enable --now smbd
    run systemctl restart smbd
  fi

  echo "Samba share '${SHARE_NAME}' configured for ${SHARE_PATH}."
fi

# ----------------------------
# 5) Install & configure dnsmasq to provide DHCP on the repository bridge
# ----------------------------
if (( SKIP_DHCP )); then
  echo
  echo "== Step 5/7: dnsmasq DHCP configuration skipped (--skip-dhcp) =="
else
  echo
  echo "== Step 5/7: Configuring dnsmasq DHCP on '${BRIDGE_NAME}' (${DNSMASQ_CONF}) =="

  if ! command -v dnsmasq >/dev/null 2>&1; then
    echo "Installing dnsmasq..."
    run env DEBIAN_FRONTEND=noninteractive apt-get update -y
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
  else
    echo "dnsmasq already installed."
  fi

  run mkdir -p "$(dirname "$DNSMASQ_CONF")"

  DHCP_GATEWAY="${BRIDGE_CIDR%%/*}"
  bridge_prefix="${BRIDGE_CIDR##*/}"
  if [[ ! "$bridge_prefix" =~ ^[0-9]+$ ]] || (( bridge_prefix < 0 || bridge_prefix > 32 )); then
    echo "ERROR: invalid --bridge-cidr '${BRIDGE_CIDR}'; expected format like 10.200.0.1/24." >&2
    exit 1
  fi
  DHCP_NETMASK="$(prefix_to_netmask "$bridge_prefix")"

  dnsmasq_conf_content="$(cat <<EOF
# DHCP only; do not run DNS service on port 53
port=0

# Serve only the Proxmox VM bridge
interface=${BRIDGE_NAME}
bind-dynamic

# DHCP address pool
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_NETMASK},${DHCP_LEASE_TIME}

# Default gateway
dhcp-option=option:router,${DHCP_GATEWAY}

# DNS servers given to VMs
dhcp-option=option:dns-server,${DHCP_DNS_SERVERS}

# This must be the only DHCP server on ${BRIDGE_NAME}
dhcp-authoritative

log-dhcp
EOF
)"

  dnsmasq_conf_changed=1
  if [[ -f "$DNSMASQ_CONF" ]] && [[ "$(cat "$DNSMASQ_CONF")" == "$dnsmasq_conf_content" ]]; then
    echo "${DNSMASQ_CONF} already up to date."
    dnsmasq_conf_changed=0
  else
    backup_file "$DNSMASQ_CONF"
    if (( DRY_RUN )); then
      echo "+ (would write) ${DNSMASQ_CONF}"
    else
      printf '%s\n' "$dnsmasq_conf_content" > "$DNSMASQ_CONF"
    fi
    echo "Wrote ${DNSMASQ_CONF}."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run systemctl enable dnsmasq
    if (( dnsmasq_conf_changed )) || ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
      run systemctl restart dnsmasq
      echo "Restarted dnsmasq to apply DHCP configuration."
    else
      echo "dnsmasq configuration unchanged; service left running."
    fi
  else
    echo "NOTE: 'systemctl' not found; restart dnsmasq manually to apply DHCP configuration." >&2
  fi

  if (( dnsmasq_conf_changed )); then
    echo "dnsmasq DHCP configured on '${BRIDGE_NAME}' (${DNSMASQ_CONF} updated)."
  else
    echo "dnsmasq DHCP configured on '${BRIDGE_NAME}' (${DNSMASQ_CONF} unchanged)."
  fi
fi

# ----------------------------
# 6) Tune ZFS dataset backing the repository for throughput
# ----------------------------
if (( SKIP_ZFS )); then
  echo
  echo "== Step 6/7: ZFS tuning skipped (--skip-zfs) =="
else
  echo
  echo "== Step 6/7: Tuning ZFS dataset '${ZFS_DATASET}' =="

  if ! command -v zfs >/dev/null 2>&1; then
    echo "WARNING: 'zfs' command not found; skipping ZFS tuning." >&2
  elif ! (( DRY_RUN )) && ! zfs list -H -o name "$ZFS_DATASET" >/dev/null 2>&1; then
    echo "WARNING: ZFS dataset '${ZFS_DATASET}' not found; skipping ZFS tuning." >&2
  else
    run zfs set recordsize=1M "$ZFS_DATASET"
    run zfs set compression=lz4 "$ZFS_DATASET"
    run zfs set atime=off "$ZFS_DATASET"
    run zfs set xattr=sa "$ZFS_DATASET"
    run zfs set dnodesize=auto "$ZFS_DATASET"
    echo "ZFS dataset '${ZFS_DATASET}' tuned for throughput."
  fi
fi

if (( DO_REBOOT )); then
  echo "Rebooting now to apply changes..."
  run reboot
else
  echo "A reboot is required for the changes to take effect. Run 'reboot' (or re-run with --reboot) when ready."
fi
