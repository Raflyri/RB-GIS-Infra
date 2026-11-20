#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/mount_synology_ro.sh
# Phase 2: Mounting Direktori Dokumen PDF Synology DS218j ke CT Backend (Read-Only)
# Mendukung protokol NFS maupun SMB/CIFS serta memastikan CT FastAPI Backend
# tidak pernah memiliki izin tulis/hapus (Read-Only) terhadap arsip PDF fisik.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"
MOUNT_PROTOCOL="${MOUNT_PROTOCOL:-nfs}" # 'nfs' (default) atau 'smb'

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

SYNOLOGY_IP="${SYNOLOGY_IP:-172.16.10.50}"
SYNOLOGY_NFS_EXPORT="${SYNOLOGY_NFS_EXPORT:-/volume1/LDKH-Documents}"
SYNOLOGY_SMB_SHARE="${SYNOLOGY_SMB_SHARE:-//172.16.10.50/LDKH-Documents}"
SYNOLOGY_SMB_CREDENTIALS="${SYNOLOGY_SMB_CREDENTIALS:-/etc/samba/.synology-ldkh.cred}"
HOST_SYNOLOGY_MOUNT="${HOST_SYNOLOGY_MOUNT:-/mnt/pve/synology-ldkh}"
CONTAINER_SYNOLOGY_MOUNT="${CONTAINER_SYNOLOGY_MOUNT:-/mnt/synology/LDKH-Documents}"
CT_BACKEND_ID="${CT_BACKEND_ID:-130}"
CT_NGINX_ID="${CT_NGINX_ID:-100}"

if command -v pct >/dev/null 2>&1; then
  echo "==> [Mode Proxmox Host] Menyiapkan mount Synology DS218j (${SYNOLOGY_IP}) via ${MOUNT_PROTOCOL^^}..."
  apt-get update -qq && apt-get install -y nfs-common cifs-utils
  mkdir -p "$HOST_SYNOLOGY_MOUNT"

  if [ "$MOUNT_PROTOCOL" = "smb" ]; then
    FSTAB_ENTRY="${SYNOLOGY_SMB_SHARE} ${HOST_SYNOLOGY_MOUNT} cifs credentials=${SYNOLOGY_SMB_CREDENTIALS},ro,iocharset=utf8,vers=3.0,_netdev,nofail 0 0"
  else
    FSTAB_ENTRY="${SYNOLOGY_IP}:${SYNOLOGY_NFS_EXPORT} ${HOST_SYNOLOGY_MOUNT} nfs defaults,_netdev,noatime,soft,timeo=30 0 0"
  fi

  grep -Fq "$HOST_SYNOLOGY_MOUNT" /etc/fstab || echo "$FSTAB_ENTRY" >> /etc/fstab
  mount -a

  echo "==> Memasang Bind Mount Read-Only (ro=1) ke CT ${CT_BACKEND_ID} (FastAPI Backend)..."
  pct set "$CT_BACKEND_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"

  if pct status "$CT_NGINX_ID" >/dev/null 2>&1; then
    echo "==> Memasang Bind Mount Read-Only (ro=1) ke CT ${CT_NGINX_ID} (vm-nginx) untuk X-Accel-Redirect..."
    pct set "$CT_NGINX_ID" -mp0 "${HOST_SYNOLOGY_MOUNT},mp=${CONTAINER_SYNOLOGY_MOUNT},ro=1"
  fi

  echo "==> Menguji proteksi Read-Only di dalam CT ${CT_BACKEND_ID}..."
  if pct exec "$CT_BACKEND_ID" -- sh -c "touch '${CONTAINER_SYNOLOGY_MOUNT}/.write_test' 2>/dev/null"; then
    pct exec "$CT_BACKEND_ID" -- rm -f "${CONTAINER_SYNOLOGY_MOUNT}/.write_test"
    echo "[ERROR] Mount di CT ${CT_BACKEND_ID} masih bisa ditulis! Periksa opsi ro=1."
    exit 1
  else
    echo "[OK] Terverifikasi: CT ${CT_BACKEND_ID} hanya memiliki akses Read-Only ke ${CONTAINER_SYNOLOGY_MOUNT}."
  fi
else
  echo "==> [Mode Dalam Container] Memverifikasi / memasang mount Read-Only di ${CONTAINER_SYNOLOGY_MOUNT}..."
  mkdir -p "$CONTAINER_SYNOLOGY_MOUNT"

  if ! mountpoint -q "$CONTAINER_SYNOLOGY_MOUNT"; then
    apt-get update -qq && apt-get install -y nfs-common cifs-utils
    if [ "$MOUNT_PROTOCOL" = "smb" ]; then
      FSTAB_ENTRY="${SYNOLOGY_SMB_SHARE} ${CONTAINER_SYNOLOGY_MOUNT} cifs credentials=${SYNOLOGY_SMB_CREDENTIALS},ro,iocharset=utf8,vers=3.0,_netdev,nofail 0 0"
    else
      FSTAB_ENTRY="${SYNOLOGY_IP}:${SYNOLOGY_NFS_EXPORT} ${CONTAINER_SYNOLOGY_MOUNT} nfs ro,defaults,_netdev,noatime,soft,timeo=30 0 0"
    fi
    grep -Fq "$CONTAINER_SYNOLOGY_MOUNT" /etc/fstab || echo "$FSTAB_ENTRY" >> /etc/fstab
    mount -a
  fi

  if touch "${CONTAINER_SYNOLOGY_MOUNT}/.write_test" 2>/dev/null; then
    rm -f "${CONTAINER_SYNOLOGY_MOUNT}/.write_test"
    echo "[ERROR] ${CONTAINER_SYNOLOGY_MOUNT} tidak dalam mode Read-Only!"
    exit 1
  fi
  echo "[OK] Terverifikasi: ${CONTAINER_SYNOLOGY_MOUNT} terpasang dalam mode Read-Only (ro)."
fi
