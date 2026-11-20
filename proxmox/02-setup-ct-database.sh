#!/usr/bin/env bash
# ==============================================================================
# infra/proxmox/02-setup-ct-database.sh
# Phase 2: Instalasi & Konfigurasi PostgreSQL 16 + PostGIS 3 di CT Database (CT 120)
# Mengikuti arsitektur PostGIS-LDKH-Architect:
#   - Pemisahan data spasial (parcels: MultiPolygon SRID 4326) & tabular (documents, owners, ocr_raw_data)
#   - Status hukum tanah: CLEAR, SENGKETA, BEDA_FISIK, DISITA_BI, RAMPASAN
#   - Dukungan Orphaned Records (documents.parcel_id NULLABLE)
#   - Normalisasi luasan otomatis ke Meter Persegi (area_m2)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env.proxmox}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
elif [ -f "${SCRIPT_DIR}/proxmox-env.example" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/proxmox-env.example"
fi

PROXMOX_HOST_IP="${PROXMOX_HOST_IP:-172.16.10.1}"
CT_NGINX_IP="${CT_NGINX_IP:-172.16.10.100}"
CT_DB_IP="${CT_DB_IP:-172.16.10.120}"
CT_BACKEND_IP="${CT_BACKEND_IP:-172.16.10.130}"
QGIS_SUBNET_CIDR="${QGIS_SUBNET_CIDR:-172.16.10.0/24}"
POSTGRES_DB="${POSTGRES_DB:-ldkh_gis}"
POSTGRES_USER="${POSTGRES_USER:-ldkh_admin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ldkh_dev_secret}"

echo "==> [1/5] Instalasi PostgreSQL 16 & PostGIS 3..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y gnupg2 lsb-release curl ca-certificates

# Pastikan repositori PostgreSQL/Debian menyediakan PostgreSQL 16 + PostGIS 3
if ! apt-cache show postgresql-16-postgis-3 >/dev/null 2>&1; then
  sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
  apt-get update -qq
fi

apt-get install -y postgresql-16 postgresql-contrib-16 postgis postgresql-16-postgis-3 postgresql-16-postgis-3-scripts

PG_VER="16"
PG_CONF="/etc/postgresql/${PG_VER}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"

echo "==> [2/5] Konfigurasi listen_addresses & pg_hba.conf (Isolasi Subnet Proxmox ${QGIS_SUBNET_CIDR})..."
sed -i "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" "$PG_CONF"

add_hba_rule() {
  local cidr="$1"
  local comment="$2"
  if ! grep -Fq "$cidr" "$PG_HBA"; then
    echo "# ${comment}" >> "$PG_HBA"
    echo "host    ${POSTGRES_DB}    ${POSTGRES_USER}    ${cidr}    scram-sha-256" >> "$PG_HBA"
  fi
}

add_hba_rule "${CT_BACKEND_IP}/32" "CT FastAPI Backend"
add_hba_rule "${PROXMOX_HOST_IP}/32" "Proxmox Host (Automated Daily Backup)"
add_hba_rule "${CT_NGINX_IP}/32" "CT 100 Nginx / Management"
add_hba_rule "${QGIS_SUBNET_CIDR}" "QGIS Desktop LAN Subnet"

systemctl enable postgresql
systemctl restart postgresql

echo "==> [3/5] Membuat role '${POSTGRES_USER}' dan database '${POSTGRES_DB}'..."
su - postgres -c "psql -v ON_ERROR_STOP=1" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
    CREATE ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  ELSE
    ALTER ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';
  END IF;
END
\$\$;
SQL

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1; then
  su - postgres -c "createdb -O ${POSTGRES_USER} ${POSTGRES_DB}"
fi

echo "==> [4/5] Mengaktifkan ekstensi PostGIS & menginisialisasi skema LDKH..."
su - postgres -c "psql -d ${POSTGRES_DB} -v ON_ERROR_STOP=1" <<SQL
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
SQL

SCHEMA_SQL="${PROJECT_ROOT}/infra/postgres/02-schema-and-seed.sql"
if [ -f "$SCHEMA_SQL" ]; then
  echo "==> [5/5] Menerapkan DDL Skema Spasial & Tabular (${SCHEMA_SQL})..."
  su - postgres -c "psql -d ${POSTGRES_DB} -v ON_ERROR_STOP=1 -f '${SCHEMA_SQL}'"
  su - postgres -c "psql -d ${POSTGRES_DB} -v ON_ERROR_STOP=1" <<SQL
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${POSTGRES_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${POSTGRES_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${POSTGRES_USER};
SQL
else
  echo "[INFO] File ${SCHEMA_SQL} tidak ditemukan; skema akan diinisialisasi via Alembic dari CT Backend."
fi

echo "[OK] PostgreSQL 16 + PostGIS 3 siap di ${CT_DB_IP}:5432 (DB: ${POSTGRES_DB})."
