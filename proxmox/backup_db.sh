#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/backup_db.sh
# Instruction 2 & Phase 2: Cron Job Script Backup Harian Database PostGIS
# Dieksekusi harian oleh Proxmox Host (atau CT Management) untuk mengekspor
# database PostGIS (ldkh_gis) menggunakan pg_dump dan menyimpannya langsung
# ke folder backup di NAS Synology DS218j (RAID 1).
#
# Penggunaan:
#   1. Jalankan backup manual : bash infra/proxmox/backup_db.sh
#   2. Pasang jadwal cron     : bash infra/proxmox/backup_db.sh --install-cron
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.proxmox"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

CT_DB_ID="${CT_DB_ID:-120}"
CT_DB_IP="${CT_DB_IP:-172.16.10.120}"
POSTGRES_DB="${POSTGRES_DB:-ldkh_gis}"
POSTGRES_USER="${POSTGRES_USER:-ldkh_admin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ldkh_dev_secret}"
SYNOLOGY_IP="${SYNOLOGY_IP:-172.16.10.50}"
SYNOLOGY_BACKUP_EXPORT="${SYNOLOGY_BACKUP_EXPORT:-/volume1/Proxmox-Backup}"
HOST_BACKUP_MOUNT="${HOST_BACKUP_MOUNT:-/mnt/pve/synology-backup}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}" # Setiap hari pukul 02:00 WIB

if [ "${1:-}" = "--install-cron" ]; then
  CRON_FILE="/etc/cron.d/ldkh-postgis-backup"
  SCRIPT_ABS_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  chmod 700 "$SCRIPT_ABS_PATH"
  cat > "$CRON_FILE" <<EOF
# Jadwal Backup Harian PostGIS LDKH ke NAS Synology DS218j (Setiap 02:00 WIB)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${CRON_SCHEDULE} root ${SCRIPT_ABS_PATH} >> /var/log/ldkh-postgis-backup.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
  echo "[OK] Cron job harian berhasil didaftarkan di ${CRON_FILE} (${CRON_SCHEDULE})."
  exit 0
fi

# Pastikan mount point backup Synology tersedia di Proxmox Host
mkdir -p "$HOST_BACKUP_MOUNT"
if ! mountpoint -q "$HOST_BACKUP_MOUNT" 2>/dev/null; then
  if command -v mount.nfs >/dev/null 2>&1; then
    mount -t nfs "${SYNOLOGY_IP}:${SYNOLOGY_BACKUP_EXPORT}" "$HOST_BACKUP_MOUNT" 2>/dev/null || true
  fi
fi

BACKUP_DIR="${HOST_BACKUP_MOUNT}/ldkh-postgis"
mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/ldkh_gis_${TIMESTAMP}.dump"
SQL_GZIP_FILE="${BACKUP_DIR}/ldkh_gis_${TIMESTAMP}.sql.gz"
CHECKSUM_FILE="${DUMP_FILE}.sha256"

echo "[$(date -Iseconds)] Memulai backup PostGIS database '${POSTGRES_DB}' ke Synology NAS (${BACKUP_DIR})..."

if command -v pct >/dev/null 2>&1 && pct status "$CT_DB_ID" >/dev/null 2>&1; then
  # Eksekusi langsung dari Proxmox VE Host melalui pct exec ke CT Database
  pct exec "$CT_DB_ID" -- su - postgres -c "pg_dump -Fc '${POSTGRES_DB}'" > "$DUMP_FILE"
  pct exec "$CT_DB_ID" -- su - postgres -c "pg_dump --clean --if-exists '${POSTGRES_DB}'" | gzip -9 > "$SQL_GZIP_FILE"
else
  # Fallback koneksi TCP menggunakan pg_dump ke IP CT Database
  export PGPASSWORD="$POSTGRES_PASSWORD"
  pg_dump -h "$CT_DB_IP" -p 5432 -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" -f "$DUMP_FILE"
  pg_dump -h "$CT_DB_IP" -p 5432 -U "$POSTGRES_USER" --clean --if-exists "$POSTGRES_DB" | gzip -9 > "$SQL_GZIP_FILE"
  unset PGPASSWORD
fi

sha256sum "$DUMP_FILE" "$SQL_GZIP_FILE" > "$CHECKSUM_FILE"
chmod 600 "$DUMP_FILE" "$SQL_GZIP_FILE" "$CHECKSUM_FILE"

# Retensi otomatis: hapus file backup yang lebih tua dari RETENTION_DAYS (default 30 hari)
find "$BACKUP_DIR" -type f \( -name "ldkh_gis_*.dump" -o -name "ldkh_gis_*.sql.gz" -o -name "ldkh_gis_*.sha256" \) -mtime +"$RETENTION_DAYS" -delete

echo "[$(date -Iseconds)] [OK] Backup selesai: ${DUMP_FILE} ($(du -h "$DUMP_FILE" | cut -f1))"
