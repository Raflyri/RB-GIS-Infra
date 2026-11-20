#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/05-setup-ct100-nginx-and-backup.sh
# Phase 4: Konfigurasi Nginx Reverse Proxy Produksi di CT 100 (vm-nginx)
#   1. Instalasi Nginx
#   2. Penerapan infra/proxmox/nginx/nginx.conf dengan substitusi IP CT Backend & Frontend
#   3. Verifikasi mount Read-Only Synology (/mnt/synology/LDKH-Documents) untuk X-Accel-Redirect
#   4. Opsional: memanggil setup_cloudflared.sh jika CLOUDFLARE_TUNNEL_TOKEN tersedia
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

CT_BACKEND_IP="${CT_BACKEND_IP:-172.16.10.130}"
CT_FRONTEND_IP="${CT_FRONTEND_IP:-172.16.10.140}"
CONTAINER_SYNOLOGY_MOUNT="${CONTAINER_SYNOLOGY_MOUNT:-/mnt/synology/LDKH-Documents}"
NGINX_SRC="${SCRIPT_DIR}/nginx/nginx.conf"

echo "==> [1/4] Instalasi Nginx..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y nginx curl

echo "==> [2/4] Memeriksa mount point Synology Read-Only (${CONTAINER_SYNOLOGY_MOUNT})..."
if [ ! -d "$CONTAINER_SYNOLOGY_MOUNT" ]; then
  echo "[ERROR] Mount point ${CONTAINER_SYNOLOGY_MOUNT} tidak ditemukan di CT 100. Pasang bind mount ro=1 dari Proxmox Host."
  exit 1
fi

echo "==> [3/4] Menerapkan konfigurasi produksi /etc/nginx/nginx.conf..."
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.bak ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
fi

if [ ! -f "$NGINX_SRC" ]; then
  echo "[ERROR] File ${NGINX_SRC} tidak ditemukan."
  exit 1
fi

cp "$NGINX_SRC" /etc/nginx/nginx.conf
sed -i "s|172\.16\.10\.130:8000|${CT_BACKEND_IP}:8000|g" /etc/nginx/nginx.conf
sed -i "s|172\.16\.10\.140:3000|${CT_FRONTEND_IP}:3000|g" /etc/nginx/nginx.conf
sed -i "s|/mnt/synology/LDKH-Documents/|${CONTAINER_SYNOLOGY_MOUNT}/|g" /etc/nginx/nginx.conf

nginx -t
systemctl enable nginx
systemctl restart nginx
echo "[OK] Nginx CT 100 aktif dan meneruskan /api/ -> ${CT_BACKEND_IP}:8000 dan / -> ${CT_FRONTEND_IP}:3000."

echo "==> [4/4] Memeriksa konfigurasi Cloudflare Tunnel (cloudflared)..."
if [ -f "${SCRIPT_DIR}/setup_cloudflared.sh" ]; then
  bash "${SCRIPT_DIR}/setup_cloudflared.sh" "$ENV_FILE"
fi
