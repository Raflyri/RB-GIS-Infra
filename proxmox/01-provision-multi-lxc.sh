#!/usr/bin/env bash
# ==============================================================================
# 01-provision-multi-lxc.sh
# Dijalankan sebagai root di Proxmox VE Host untuk:
#   1. Mount NFS Synology DS218j di host Proxmox (/mnt/pve/synology-ldkh)
#   2. Provisioning LXC (GIS-Database, GIS-Backend, GIS-Frontend)
#   3. Bind Mount Synology Read-Only (ro=1) ke CT GIS-Backend & CT 100 (vm-nginx)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] File environment tidak ditemukan: $ENV_FILE"
  echo "Salin ${SCRIPT_DIR}/proxmox-env.example menjadi ${SCRIPT_DIR}/.env.proxmox lalu sesuaikan nilainya."
  exit 1
fi

# shellcheck source=/dev/null
. "$ENV_FILE"

if ! command -v pct >/dev/null 2>&1; then
  echo "[ERROR] Perintah 'pct' tidak ditemukan. Jalankan script ini di node Proxmox VE Host."
  exit 1
fi

echo "==> [1/4] Menyiapkan NFS client & mount Synology DS218j di Proxmox Host..."
if ! command -v mount.nfs >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y nfs-common
fi

mkdir -p "$HOST_SYNOLOGY_MOUNT" "$HOST_BACKUP_MOUNT"

FSTAB_DOCS="${SYNOLOGY_IP}:${SYNOLOGY_NFS_EXPORT} ${HOST_SYNOLOGY_MOUNT} nfs defaults,_netdev,noatime,soft,timeo=30 0 0"
FSTAB_BACKUP="${SYNOLOGY_IP}:${SYNOLOGY_BACKUP_EXPORT} ${HOST_BACKUP_MOUNT} nfs defaults,_netdev,noatime,soft,timeo=30 0 0"

if ! grep -Fq "$HOST_SYNOLOGY_MOUNT" /etc/fstab; then
  echo "$FSTAB_DOCS" >> /etc/fstab
fi
if ! grep -Fq "$HOST_BACKUP_MOUNT" /etc/fstab; then
  echo "$FSTAB_BACKUP" >> /etc/fstab
fi

mount -a
echo "[OK] NFS Synology ter-mount di $HOST_SYNOLOGY_MOUNT dan $HOST_BACKUP_MOUNT"

create_lxc_if_missing() {
  local ctid="$1"
  local hostname="$2"
  local ip="$3"
  local cores="$4"
  local memory="$5"
  local disk="$6"

  if pct status "$ctid" >/dev/null 2>&1; then
    echo "[SKIP] CT $ctid ($hostname) sudah ada."
    return 0
  fi

  echo "==> Membuat LXC CT $ctid ($hostname) IP ${ip}/${LAN_PREFIX}..."
  pct create "$ctid" "$LXC_TEMPLATE" \
    --hostname "$hostname" \
    --cores "$cores" \
    --memory "$memory" \
    --swap 512 \
    --rootfs "${LXC_STORAGE}:${disk}" \
    --net0 "name=eth0,bridge=${LXC_BRIDGE},ip=${ip}/${LAN_PREFIX},gw=${GATEWAY_IP}" \
    --nameserver "$DNS_SERVER" \
    --unprivileged 1 \
    --features "nesting=1" \
    --onboot 1 \
    --password "$LXC_ROOT_PASSWORD"

  pct start "$ctid"
  echo "[OK] CT $ctid ($hostname) aktif."
}

echo "==> [2/4] Provisioning LXC Containers GIS (DB, Backend, Frontend)..."
create_lxc_if_missing "$CT_DB_ID" "ldkh-gis-db" "$CT_DB_IP" "$CT_DB_CORES" "$CT_DB_RAM_MB" "$CT_DB_DISK_GB"
create_lxc_if_missing "$CT_BACKEND_ID" "ldkh-gis-backend" "$CT_BACKEND_IP" "$CT_BACKEND_CORES" "$CT_BACKEND_RAM_MB" "$CT_BACKEND_DISK_GB"
create_lxc_if_missing "$CT_FRONTEND_ID" "ldkh-gis-frontend" "$CT_FRONTEND_IP" "$CT_FRONTEND_CORES" "$CT_FRONTEND_RAM_MB" "$CT_FRONTEND_DISK_GB"

echo "==> [3/4] Memasang Bind Mount Synology Read-Only (ro=1) untuk Viewer & Proxy..."
# CT GIS-Backend hanya membutuhkan akses baca (ro=1) ke PDF legal
pct set "$CT_BACKEND_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"
echo "[OK] CT $CT_BACKEND_ID (gis-backend): $CONTAINER_SYNOLOGY_MOUNT terpasang (ro=1)"

# CT 100 (vm-nginx) membutuhkan akses baca (ro=1) untuk Nginx X-Accel-Redirect
if pct status "$CT_NGINX_ID" >/dev/null 2>&1; then
  pct set "$CT_NGINX_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"
  pct set "$CT_NGINX_ID" -mp1 "${HOST_BACKUP_MOUNT},mp=${CONTAINER_BACKUP_MOUNT},ro=0"
  echo "[OK] CT $CT_NGINX_ID (vm-nginx): $CONTAINER_SYNOLOGY_MOUNT (ro=1) & $CONTAINER_BACKUP_MOUNT (ro=0) terpasang"
else
  echo "[WARN] CT $CT_NGINX_ID (vm-nginx) tidak ditemukan; lewati mount mp0/mp1."
fi

# CT Nextcloud membutuhkan akses baca-tulis (ro=0) untuk manajemen arsip PDF
if pct status "$CT_NEXTCLOUD_ID" >/dev/null 2>&1; then
  pct set "$CT_NEXTCLOUD_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=0"
  echo "[OK] CT $CT_NEXTCLOUD_ID (nextcloud): $CONTAINER_SYNOLOGY_MOUNT terpasang (ro=0)"
fi

echo "==> [4/4] Provisioning Proxmox Multi-LXC selesai."
echo "Langkah berikutnya: salin repo rb-gis ke /opt/rb-gis di CT Backend & Frontend, lalu jalankan script 02 s.d. 05."
