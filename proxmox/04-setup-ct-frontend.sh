#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/04-setup-ct-frontend.sh
# Phase 3: Build & Run Aplikasi Next.js di CT Frontend (CT 140)
#   1. Instalasi Node.js 20 LTS
#   2. Konfigurasi environment produksi (.env.local) menuju CT Backend (172.16.10.130:8000)
#   3. Eksekusi `npm run build`
#   4. Menjalankan service secara otomatis saat boot via systemd (default) atau PM2
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"
PROCESS_MANAGER="${PROCESS_MANAGER:-systemd}" # 'systemd' (default) atau 'pm2'

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

APP_REPO_DIR="${APP_REPO_DIR:-/opt/rb-gis}"
FRONTEND_DIR="${APP_REPO_DIR}/frontend"
CT_BACKEND_IP="${CT_BACKEND_IP:-172.16.10.130}"
CT_NGINX_IP="${CT_NGINX_IP:-172.16.10.133}"

if [ ! -d "$FRONTEND_DIR" ]; then
  echo "[ERROR] Direktori frontend tidak ditemukan di ${FRONTEND_DIR}."
  exit 1
fi

echo "==> [1/4] Instalasi Node.js 20 LTS..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl ca-certificates gnupg
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "==> [2/4] Menulis ${FRONTEND_DIR}/.env.local produksi..."
cat > "${FRONTEND_DIR}/.env.local" <<EOF
NEXT_PUBLIC_API_BASE_URL=/api/v1
BACKEND_INTERNAL_URL=http://${CT_BACKEND_IP}:8000
NEXT_TELEMETRY_DISABLED=1
EOF

echo "==> [3/4] Instalasi dependensi & eksekusi 'npm run build' Next.js..."
cd "$FRONTEND_DIR"
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
npm run build

echo "==> [4/4] Menyiapkan layanan otomatis (${PROCESS_MANAGER})..."
if [ "$PROCESS_MANAGER" = "pm2" ]; then
  npm install -g pm2
  pm2 delete ldkh-gis-frontend >/dev/null 2>&1 || true
  pm2 start "${FRONTEND_DIR}/ecosystem.config.cjs"
  pm2 save
  pm2 startup systemd -u root --hp /root | tail -n 1 | bash || true
  echo "[OK] CT GIS-Frontend aktif di port 3000 via PM2."
else
  cat > /etc/systemd/system/ldkh-frontend.service <<EOF
[Unit]
Description=LDKH Web GIS Next.js Production Frontend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${FRONTEND_DIR}
Environment=NODE_ENV=production
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
EnvironmentFile=${FRONTEND_DIR}/.env.local
ExecStart=/usr/bin/npm run start -- -H 0.0.0.0 -p 3000
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ldkh-frontend.service
  systemctl restart ldkh-frontend.service
  echo "[OK] CT GIS-Frontend aktif di port 3000 via systemd (ldkh-frontend.service)."
fi

# Rekomendasi Firewall LXC Frontend (UFW): hanya izinkan port 3000 dari CT Nginx
if command -v ufw >/dev/null 2>&1; then
  ufw allow from "${CT_NGINX_IP}" to any port 3000 proto tcp || true
  ufw deny 3000/tcp || true
fi
