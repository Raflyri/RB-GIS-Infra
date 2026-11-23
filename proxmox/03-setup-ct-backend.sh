#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/03-setup-ct-backend.sh
# Phase 3: Deployment FastAPI Backend & Registrasi systemd di CT Backend (CT 130)
#   1. Instalasi Python 3 + pustaka spasial sistem (GDAL, GEOS, PROJ, libpq)
#   2. Verifikasi ketatnya mount Read-Only Synology (/mnt/synology/LDKH-Documents)
#   3. Setup virtualenv, install requirements.txt, & migrasi Alembic ke PostGIS
#   4. Registrasi & aktivasi service systemd ldkh-backend.service saat boot
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

APP_REPO_DIR="${APP_REPO_DIR:-/opt/rb-gis}"
BACKEND_DIR="${APP_REPO_DIR}/backend"
CONTAINER_SYNOLOGY_MOUNT="${CONTAINER_SYNOLOGY_MOUNT:-/mnt/synology/LDKH-Documents}"
CT_DB_IP="${CT_DB_IP:-172.16.10.120}"
CT_NGINX_IP="${CT_NGINX_IP:-172.16.10.100}"
CT_FRONTEND_IP="${CT_FRONTEND_IP:-172.16.10.140}"
POSTGRES_DB="${POSTGRES_DB:-ldkh_gis}"
POSTGRES_USER="${POSTGRES_USER:-ldkh_admin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ldkh_dev_secret}"
SECRET_KEY="${SECRET_KEY:-change-this-in-production-hmac-secret}"
PDF_TOKEN_EXPIRE_SECONDS="${PDF_TOKEN_EXPIRE_SECONDS:-900}"
CLOUDFLARE_TUNNEL_DOMAIN="${CLOUDFLARE_TUNNEL_DOMAIN:-gis.ldkh.internal}"

if [ ! -d "$BACKEND_DIR" ]; then
  echo "[ERROR] Direktori backend tidak ditemukan di ${BACKEND_DIR}."
  exit 1
fi

echo "==> [1/5] Instalasi Python 3 & pustaka spasial sistem..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y python3 python3-venv python3-dev build-essential libpq-dev gdal-bin libgeos-dev libproj-dev curl

echo "==> [2/5] Verifikasi mount Synology Read-Only (${CONTAINER_SYNOLOGY_MOUNT})..."
if [ ! -d "$CONTAINER_SYNOLOGY_MOUNT" ]; then
  echo "[ERROR] Mount point ${CONTAINER_SYNOLOGY_MOUNT} tidak ditemukan. Pastikan mp0 ro=1 sudah dipasang dari Proxmox Host."
  exit 1
fi
if touch "${CONTAINER_SYNOLOGY_MOUNT}/.ro_write_test" 2>/dev/null; then
  rm -f "${CONTAINER_SYNOLOGY_MOUNT}/.ro_write_test"
  echo "[ERROR] KEAMANAN: ${CONTAINER_SYNOLOGY_MOUNT} masih bisa ditulis! Ubah bind mount menjadi ro=1 sebelum melanjutkan."
  exit 1
else
  echo "[OK] Terverifikasi ${CONTAINER_SYNOLOGY_MOUNT} terkunci dalam mode Read-Only (ro)."
fi

echo "==> [3/5] Menulis ${BACKEND_DIR}/.env produksi..."
cat > "${BACKEND_DIR}/.env" <<EOF
PROJECT_NAME=LDKH Web GIS API
API_V1_STR=/api/v1
DATABASE_URL=postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${CT_DB_IP}:5432/${POSTGRES_DB}
SYNOLOGY_MOUNT_PATH=${CONTAINER_SYNOLOGY_MOUNT}
UPLOAD_STORAGE_PATH=${BACKEND_DIR}/storage/uploads
NGINX_INTERNAL_PDF_PREFIX=/internal-pdf
SECRET_KEY=${SECRET_KEY}
PDF_TOKEN_EXPIRE_SECONDS=${PDF_TOKEN_EXPIRE_SECONDS}
ACCESS_TOKEN_EXPIRE_MINUTES=720
CF_ACCESS_TEAM_DOMAIN=${CF_ACCESS_TEAM_DOMAIN:-}
CF_ACCESS_AUD=${CF_ACCESS_AUD:-}
ENFORCE_REVERSE_PROXY=true
TRUSTED_PROXY_IPS=127.0.0.1,::1,${CT_NGINX_IP},${CT_FRONTEND_IP}
CORS_ORIGINS=https://${CLOUDFLARE_TUNNEL_DOMAIN},http://${CT_NGINX_IP},http://${CT_FRONTEND_IP}:3000
GEMINI_API_KEY=${GEMINI_API_KEY:-}
GEMINI_MODEL=${GEMINI_MODEL:-gemini-4-hydrogen}
APP_PUBLIC_URL=https://${CLOUDFLARE_TUNNEL_DOMAIN}
HERMES_SHARED_SECRET=${HERMES_SHARED_SECRET:-change-this-hermes-shared-secret-64-hex}
HERMES_WEBHOOK_URL=${HERMES_WEBHOOK_URL:-http://10.10.10.167:8787/webhook/gis-guest}
HERMES_ALLOWED_IPS=${HERMES_ALLOWED_IPS:-10.10.10.167,127.0.0.1}
GUEST_REQUEST_TTL_MINUTES=${GUEST_REQUEST_TTL_MINUTES:-30}
GUEST_SESSION_TTL_HOURS=${GUEST_SESSION_TTL_HOURS:-3}
EOF
chmod 600 "${BACKEND_DIR}/.env"
mkdir -p "${BACKEND_DIR}/storage/uploads"

# Rekomendasi Firewall LXC Backend (UFW): izinkan port 8000 dari CT Nginx, CT Frontend, & Hermes CT 101 (ZeroTier)
if command -v ufw >/dev/null 2>&1; then
  ufw allow from "${CT_NGINX_IP}" to any port 8000 proto tcp || true
  ufw allow from "${CT_FRONTEND_IP}" to any port 8000 proto tcp || true
  ufw allow from "10.10.10.167" to any port 8000 proto tcp || true
  ufw deny 8000/tcp || true
fi

echo "==> [4/5] Setup Python virtualenv & migrasi Alembic ke PostGIS..."
cd "$BACKEND_DIR"
python3 -m venv .venv
"${BACKEND_DIR}/.venv/bin/pip" install --upgrade pip
"${BACKEND_DIR}/.venv/bin/pip" install -r requirements.txt

# Jika skema awal sudah di-seed oleh 02-schema-and-seed.sql tanpa tabel alembic_version,
# sinkronkan versi migrasi awal sebelum menjalankan upgrade head.
if "${BACKEND_DIR}/.venv/bin/python" -c "
import os, sqlalchemy as sa
engine = sa.create_engine('postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${CT_DB_IP}:5432/${POSTGRES_DB}')
insp = sa.inspect(engine)
print('SYNC' if (insp.has_table('parcels') and not insp.has_table('alembic_version')) else 'OK')
" | grep -q "SYNC"; then
  "${BACKEND_DIR}/.venv/bin/alembic" stamp 0001_initial_ldkh_gis_schema
fi
"${BACKEND_DIR}/.venv/bin/alembic" upgrade head

echo "==> [5/5] Memasang & mengaktifkan layanan systemd ldkh-backend.service..."
cat > /etc/systemd/system/ldkh-backend.service <<EOF
[Unit]
Description=LDKH Web GIS FastAPI Backend (Uvicorn)
After=network-online.target
Wants=network-online.target
ConditionPathIsDirectory=${CONTAINER_SYNOLOGY_MOUNT}

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
EnvironmentFile=${BACKEND_DIR}/.env
ExecStart=${BACKEND_DIR}/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 --proxy-headers --forwarded-allow-ips="${CT_NGINX_IP},127.0.0.1"
Restart=always
RestartSec=5
TimeoutStopSec=30
ReadOnlyPaths=${CONTAINER_SYNOLOGY_MOUNT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ldkh-backend.service
systemctl restart ldkh-backend.service
sleep 3
curl -fsS http://127.0.0.1:8000/api/v1/health && echo ""
echo "[OK] CT GIS-Backend aktif di port 8000 dan terdaftar otomatis saat boot (systemd)."
