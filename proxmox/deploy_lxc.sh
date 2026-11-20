#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/deploy_lxc.sh
# Phase 1 & 2: Automasi Provisioning Multi-LXC Proxmox VE & Read-Only Bind Mount
# Target Host: Proxmox VE (172.16.10.1 / Subnet 172.16.10.0/24)
#
# Membuat 3 Linux Containers (LXC) terisolasi:
#   - CT 120 (ldkh-gis-db)       : PostgreSQL 16 + PostGIS 3 (172.16.10.120/24)
#   - CT 130 (ldkh-gis-backend)  : Python FastAPI Backend    (172.16.10.130/24)
#   - CT 140 (ldkh-gis-frontend) : Next.js 14 Web GIS UI     (172.16.10.140/24)
# Serta memasang Bind Mount dokumen PDF Synology DS218j secara Read-Only (ro=1)
# ke CT 130 (FastAPI Backend) dan CT 100 (vm-nginx).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  echo "[INFO] Menggunakan nilai default dari proxmox-env.example..."
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

# Ekstraksi otomatis IP Host Proxmox & Password dari proxmox-credential.md (jika ada)
# tanpa pernah mencetak kredensial sensitif ke layar (stdout/stderr).
CRED_FILE="${PROJECT_ROOT}/proxmox-credential.md"
if [ -f "$CRED_FILE" ]; then
  DETECTED_HOST_IP="$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$CRED_FILE" | head -n1 || true)"
  if [ -n "$DETECTED_HOST_IP" ]; then
    PROXMOX_HOST_IP="${PROXMOX_HOST_IP:-$DETECTED_HOST_IP}"
    GATEWAY_IP="${GATEWAY_IP:-$DETECTED_HOST_IP}"
  fi
  if [ "${LXC_ROOT_PASSWORD:-CHANGE_ME_TEMP_CT_PASSWORD}" = "CHANGE_ME_TEMP_CT_PASSWORD" ]; then
    DETECTED_PASS="$(sed -n 's/.*password[[:space:]]*:[[:space:]]*//Ip' "$CRED_FILE" | tr -d '\r\n' || true)"
    if [ -n "$DETECTED_PASS" ]; then
      LXC_ROOT_PASSWORD="$DETECTED_PASS"
    fi
  fi
fi

# Konfigurasi Jaringan & LXC Default (Subnet 172.16.10.0/24)
PROXMOX_HOST_IP="${PROXMOX_HOST_IP:-172.16.10.1}"
GATEWAY_IP="${GATEWAY_IP:-172.16.10.1}"
LAN_PREFIX="${LAN_PREFIX:-24}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
LXC_BRIDGE="${LXC_BRIDGE:-vmbr0}"
LXC_STORAGE="${LXC_STORAGE:-local-lvm}"
LXC_TEMPLATE="${LXC_TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"

# Alokasi CT 120: PostGIS Database
CT_DB_ID="${CT_DB_ID:-120}"
CT_DB_HOSTNAME="${CT_DB_HOSTNAME:-ldkh-gis-db}"
CT_DB_IP="${CT_DB_IP:-172.16.10.120}"
CT_DB_CORES="${CT_DB_CORES:-2}"
CT_DB_RAM_MB="${CT_DB_RAM_MB:-4096}"
CT_DB_DISK_GB="${CT_DB_DISK_GB:-32}"

# Alokasi CT 130: FastAPI Backend
CT_BACKEND_ID="${CT_BACKEND_ID:-130}"
CT_BACKEND_HOSTNAME="${CT_BACKEND_HOSTNAME:-ldkh-gis-backend}"
CT_BACKEND_IP="${CT_BACKEND_IP:-172.16.10.130}"
CT_BACKEND_CORES="${CT_BACKEND_CORES:-2}"
CT_BACKEND_RAM_MB="${CT_BACKEND_RAM_MB:-2048}"
CT_BACKEND_DISK_GB="${CT_BACKEND_DISK_GB:-16}"

# Alokasi CT 140: Next.js Frontend
CT_FRONTEND_ID="${CT_FRONTEND_ID:-140}"
CT_FRONTEND_HOSTNAME="${CT_FRONTEND_HOSTNAME:-ldkh-gis-frontend}"
CT_FRONTEND_IP="${CT_FRONTEND_IP:-172.16.10.140}"
CT_FRONTEND_CORES="${CT_FRONTEND_CORES:-2}"
CT_FRONTEND_RAM_MB="${CT_FRONTEND_RAM_MB:-2048}"
CT_FRONTEND_DISK_GB="${CT_FRONTEND_DISK_GB:-16}"

# CT 100 (vm-nginx) & Synology DS218j Mount Points
CT_NGINX_ID="${CT_NGINX_ID:-100}"
SYNOLOGY_IP="${SYNOLOGY_IP:-172.16.10.50}"
SYNOLOGY_NFS_EXPORT="${SYNOLOGY_NFS_EXPORT:-/volume1/LDKH-Documents}"
SYNOLOGY_BACKUP_EXPORT="${SYNOLOGY_BACKUP_EXPORT:-/volume1/Proxmox-Backup}"
HOST_SYNOLOGY_MOUNT="${HOST_SYNOLOGY_MOUNT:-/mnt/pve/synology-ldkh}"
HOST_BACKUP_MOUNT="${HOST_BACKUP_MOUNT:-/mnt/pve/synology-backup}"
CONTAINER_SYNOLOGY_MOUNT="${CONTAINER_SYNOLOGY_MOUNT:-/mnt/synology/LDKH-Documents}"

if ! command -v pct >/dev/null 2>&1; then
  echo "[ERROR] CLI 'pct' tidak ditemukan. Jalankan script ini langsung sebagai root di Proxmox VE Host (${PROXMOX_HOST_IP})."
  exit 1
fi

echo "==> [1/4] Memastikan template LXC tersedia (${LXC_TEMPLATE})..."
if ! pveam list local 2>/dev/null | grep -Fq "$(basename "$LXC_TEMPLATE")"; then
  echo "[INFO] Mengunduh template LXC $(basename "$LXC_TEMPLATE")..."
  pveam update
  pveam download local "$(basename "$LXC_TEMPLATE")"
fi

echo "==> [2/4] Menyiapkan Mount NFS/SMB Synology DS218j (${SYNOLOGY_IP}) di Proxmox Host..."
if ! command -v mount.nfs >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y nfs-common cifs-utils
fi

mkdir -p "$HOST_SYNOLOGY_MOUNT" "$HOST_BACKUP_MOUNT"

FSTAB_DOCS="${SYNOLOGY_IP}:${SYNOLOGY_NFS_EXPORT} ${HOST_SYNOLOGY_MOUNT} nfs defaults,_netdev,noatime,soft,timeo=30 0 0"
FSTAB_BACKUP="${SYNOLOGY_IP}:${SYNOLOGY_BACKUP_EXPORT} ${HOST_BACKUP_MOUNT} nfs defaults,_netdev,noatime,soft,timeo=30 0 0"

grep -Fq "$HOST_SYNOLOGY_MOUNT" /etc/fstab || echo "$FSTAB_DOCS" >> /etc/fstab
grep -Fq "$HOST_BACKUP_MOUNT" /etc/fstab || echo "$FSTAB_BACKUP" >> /etc/fstab
mount -a || echo "[WARN] Mount NFS Synology belum aktif; pastikan NFS share di Synology DS218j (${SYNOLOGY_IP}) sudah diizinkan untuk ${PROXMOX_HOST_IP}."

provision_ct() {
  local ctid="$1"
  local hostname="$2"
  local ip="$3"
  local cores="$4"
  local ram="$5"
  local disk="$6"

  if pct status "$ctid" >/dev/null 2>&1; then
    echo "[SKIP] CT ${ctid} (${hostname}) sudah terdaftar di Proxmox."
  else
    echo "==> Membuat CT ${ctid} (${hostname}) dengan IP Statis ${ip}/${LAN_PREFIX} (Gateway ${GATEWAY_IP})..."
    pct create "$ctid" "$LXC_TEMPLATE" \
      --hostname "$hostname" \
      --cores "$cores" \
      --memory "$ram" \
      --swap 512 \
      --rootfs "${LXC_STORAGE}:${disk}" \
      --net0 "name=eth0,bridge=${LXC_BRIDGE},ip=${ip}/${LAN_PREFIX},gw=${GATEWAY_IP}" \
      --nameserver "$DNS_SERVER" \
      --unprivileged 1 \
      --features "nesting=1" \
      --onboot 1 \
      --password "$LXC_ROOT_PASSWORD"
  fi
}

echo "==> [3/4] Provisioning 3 LXC Containers (Database, Backend, Frontend)..."
provision_ct "$CT_DB_ID" "$CT_DB_HOSTNAME" "$CT_DB_IP" "$CT_DB_CORES" "$CT_DB_RAM_MB" "$CT_DB_DISK_GB"
provision_ct "$CT_BACKEND_ID" "$CT_BACKEND_HOSTNAME" "$CT_BACKEND_IP" "$CT_BACKEND_CORES" "$CT_BACKEND_RAM_MB" "$CT_BACKEND_DISK_GB"
provision_ct "$CT_FRONTEND_ID" "$CT_FRONTEND_HOSTNAME" "$CT_FRONTEND_IP" "$CT_FRONTEND_CORES" "$CT_FRONTEND_RAM_MB" "$CT_FRONTEND_DISK_GB"

echo "==> [4/4] Memasang Bind Mount PDF Synology Read-Only (ro=1) ke CT FastAPI Backend & CT Nginx..."
# KRUSIAL: ro=1 mengunci akses hanya-baca di level hypervisor LXC agar Backend tidak pernah bisa mengubah/menghapus PDF.
pct set "$CT_BACKEND_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"
echo "[OK] Bind mount Read-Only (ro=1) terpasang di CT ${CT_BACKEND_ID} (${CT_BACKEND_HOSTNAME}): ${CONTAINER_SYNOLOGY_MOUNT}"

if pct status "$CT_NGINX_ID" >/dev/null 2>&1; then
  pct set "$CT_NGINX_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"
  echo "[OK] Bind mount Read-Only (ro=1) terpasang di CT ${CT_NGINX_ID} (vm-nginx): ${CONTAINER_SYNOLOGY_MOUNT}"
fi

for ctid in "$CT_DB_ID" "$CT_BACKEND_ID" "$CT_FRONTEND_ID"; do
  if ! pct status "$ctid" | grep -q "running"; then
    pct start "$ctid"
  fi
done

echo "=============================================================================="
echo "[SUCCESS] Provisioning Multi-LXC selesai:"
echo "  - CT ${CT_DB_ID} (${CT_DB_HOSTNAME})       : ${CT_DB_IP}/${LAN_PREFIX}"
echo "  - CT ${CT_BACKEND_ID} (${CT_BACKEND_HOSTNAME})  : ${CT_BACKEND_IP}/${LAN_PREFIX} [Mount PDF: ro=1]"
echo "  - CT ${CT_FRONTEND_ID} (${CT_FRONTEND_HOSTNAME}) : ${CT_FRONTEND_IP}/${LAN_PREFIX}"
echo "=============================================================================="
