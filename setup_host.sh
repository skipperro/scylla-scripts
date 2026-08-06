#!/usr/bin/env bash
# setup_host.sh
# Enables IOMMU & VFIO on a Proxmox/Debian host with an AMD CPU:
#   1. Edit /etc/default/grub to add "amd_iommu=on iommu=pt" to GRUB_CMDLINE_LINUX_DEFAULT
#   2. Run update-grub to apply the change
#   3. Load VFIO kernel modules (vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd) via /etc/modules
#   4. Install & configure Samba to share a "repository" folder over the network
#   5. Tune the backing ZFS dataset for throughput (recordsize, compression, atime, xattr, dnodesize)
#   6. Optionally reboot to apply everything
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

DRY_RUN=0
DO_REBOOT=0
SKIP_SAMBA=0
SKIP_ZFS=0

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
  - Samba is installed and a guest-accessible "${SHARE_NAME}" share is configured
    for ${SHARE_PATH} (in ${SMB_CONF}), served by the "${SMB_USER}" user
  - The "${ZFS_DATASET}" ZFS dataset is tuned for throughput (recordsize,
    compression, atime, xattr, dnodesize)

Options:
  --reboot            Reboot the host automatically after applying changes.
  --dry-run           Print what would change, without modifying anything.
  --skip-samba        Do not install/configure Samba.
  --skip-zfs          Do not apply the ZFS tuning properties.
  --share-path PATH   Path to share via Samba (default: ${SHARE_PATH}).
  --zfs-dataset NAME  ZFS dataset to tune (default: ${ZFS_DATASET}).
  --help, -h          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reboot)       DO_REBOOT=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --skip-samba)   SKIP_SAMBA=1; shift ;;
    --skip-zfs)     SKIP_ZFS=1; shift ;;
    --share-path)   SHARE_PATH="$2"; shift 2 ;;
    --zfs-dataset)  ZFS_DATASET="$2"; shift 2 ;;
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

# ----------------------------
# 1) Edit GRUB: ensure GRUB_CMDLINE_LINUX_DEFAULT contains amd_iommu=on iommu=pt
# ----------------------------
[[ -f "$GRUB_FILE" ]] || { echo "ERROR: ${GRUB_FILE} not found. Is this a Debian/Proxmox host?" >&2; exit 1; }

echo "== Step 1/4: Configuring GRUB (${GRUB_FILE}) =="

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
echo "== Step 2/4: Configuring VFIO kernel modules (${MODULES_FILE}) =="

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
# 3) Install & configure Samba share for the repository folder
# ----------------------------
if (( SKIP_SAMBA )); then
  echo
  echo "== Step 3/4: Samba configuration skipped (--skip-samba) =="
else
  echo
  echo "== Step 3/4: Configuring Samba share '${SHARE_NAME}' (${SHARE_PATH}) =="

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
# 4) Tune ZFS dataset backing the repository for throughput
# ----------------------------
if (( SKIP_ZFS )); then
  echo
  echo "== Step 4/4: ZFS tuning skipped (--skip-zfs) =="
else
  echo
  echo "== Step 4/4: Tuning ZFS dataset '${ZFS_DATASET}' =="

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
