#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/setup_cloudflared.sh
# Phase 4: Instalasi & Registrasi Cloudflare Tunnel (cloudflared) di CT 100 (vm-nginx)
# Menjembatani Nginx lokal (http://127.0.0.1:80) ke domain publik secara aman
# menggunakan Zero Trust tanpa membuka port router/ISP.
#
# Mendukung 2 mode:
#   Mode A (Direkomendasikan - Remotely-Managed Tunnel via Dashboard Token):
#     Set CLOUDFLARE_TUNNEL_TOKEN di .env.proxmox atau kirim sebagai argumen ke-2,
#     lalu script menjalankan `cloudflared service install <TOKEN>`.
#   Mode B (Interactive CLI Login - Locally-Managed Tunnel):
#     Jika CLOUDFLARE_TUNNEL_TOKEN kosong, script memandu login (`cloudflared tunnel login`),
#     membuat tunnel, menulis /etc/cloudflared/config.yml, dan mendaftarkan systemd service.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"
CLI_TOKEN="${2:-}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

CLOUDFLARE_TUNNEL_DOMAIN="${CLOUDFLARE_TUNNEL_DOMAIN:-gis.ldkh.internal}"
CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-ldkh-gis-tunnel}"
CLOUDFLARE_TUNNEL_TOKEN="${CLI_TOKEN:-${CLOUDFLARE_TUNNEL_TOKEN:-}}"

echo "==> [1/4] Memastikan paket prasyarat terpasang..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl gnupg lsb-release ca-certificates

echo "==> [2/4] Memasang repositori resmi Cloudflare & menginstal cloudflared..."
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
CODENAME="$(lsb_release -cs 2>/dev/null || echo bookworm)"
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${CODENAME} main" \
  > /etc/apt/sources.list.d/cloudflared.list

apt-get update -qq
apt-get install -y cloudflared
cloudflared --version

echo "==> [3/4] Memverifikasi Nginx lokal berjalan di http://127.0.0.1:80..."
if ! curl -fsSI http://127.0.0.1:80 >/dev/null 2>&1; then
  echo "[WARN] Nginx lokal di port 80 belum merespons. Pastikan nginx.conf sudah dipasang dan service nginx aktif."
fi

echo "==> [4/4] Registrasi & aktivasi layanan systemd cloudflared..."
if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  # Mode A: Headless / Zero-Touch dengan Tunnel Token dari Cloudflare Zero Trust Dashboard
  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    systemctl stop cloudflared
    cloudflared service uninstall || true
  fi
  cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN"
  systemctl enable cloudflared
  systemctl restart cloudflared
  systemctl status cloudflared --no-pager -l | head -n 15
  echo "[OK] cloudflared service terpasang dan aktif (Remotely-Managed Tunnel)."
  echo "Pastikan Public Hostname '${CLOUDFLARE_TUNNEL_DOMAIN}' di Cloudflare Zero Trust mengarah ke: http://127.0.0.1:80"
else
  echo "[INFO] CLOUDFLARE_TUNNEL_TOKEN belum diisi; menyiapkan konfigurasi Locally-Managed Tunnel..."
  mkdir -p /etc/cloudflared

  if [ ! -f /root/.cloudflared/cert.pem ]; then
    echo "------------------------------------------------------------------------------"
    echo "TINDAKAN MANUAL DIPERLUKAN (Mode B):"
    echo "1. Jalankan: cloudflared tunnel login"
    echo "2. Buat tunnel: cloudflared tunnel create ${CLOUDFLARE_TUNNEL_NAME}"
    echo "3. Dapatkan UUID tunnel lalu sesuaikan /etc/cloudflared/config.yml"
    echo "4. Hubungkan DNS: cloudflared tunnel route dns ${CLOUDFLARE_TUNNEL_NAME} ${CLOUDFLARE_TUNNEL_DOMAIN}"
    echo "5. Pasang service: cloudflared service install && systemctl enable --now cloudflared"
    echo "------------------------------------------------------------------------------"
  fi

  cat > /etc/cloudflared/config.yml.template <<EOF
# Template konfigurasi Locally-Managed Tunnel (/etc/cloudflared/config.yml)
tunnel: <TUNNEL-UUID>
credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: ${CLOUDFLARE_TUNNEL_DOMAIN}
    service: http://127.0.0.1:80
    originRequest:
      noTLSVerify: false
      connectTimeout: 10s
  - service: http_status:404
EOF
  echo "[OK] Template /etc/cloudflared/config.yml.template telah dibuat."
  echo "Atau isi CLOUDFLARE_TUNNEL_TOKEN lalu jalankan ulang: bash $0 $ENV_FILE <TOKEN>"
fi
