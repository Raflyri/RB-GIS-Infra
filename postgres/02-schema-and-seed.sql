-- =============================================================================
-- Sistem Web GIS Digitalisasi Tanah LDKH - Schema DDL & Seed Data Sampel
-- Catatan: Identik dengan migrasi Alembic 0001_initial_ldkh_gis_schema.
-- Jika menginisialisasi DB via Docker entrypoint ini, jalankan:
--   alembic stamp 0001_initial_ldkh_gis_schema
-- agar histori Alembic sinkron dengan schema yang sudah terbentuk.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Fungsi normalisasi luasan tanah ke Meter Persegi (m2)
CREATE OR REPLACE FUNCTION normalize_area_to_m2(val NUMERIC, unit TEXT)
RETURNS NUMERIC AS $$
DECLARE
    normalized_unit TEXT;
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;

    normalized_unit := LOWER(TRIM(COALESCE(unit, 'm2')));

    RETURN CASE normalized_unit
        WHEN 'm2' THEN ROUND(val, 2)
        WHEN 'm²' THEN ROUND(val, 2)
        WHEN 'meter_persegi' THEN ROUND(val, 2)
        WHEN 'meter persegi' THEN ROUND(val, 2)
        WHEN 'sqm' THEN ROUND(val, 2)
        WHEN 'ha' THEN ROUND(val * 10000, 2)
        WHEN 'hektar' THEN ROUND(val * 10000, 2)
        WHEN 'hectare' THEN ROUND(val * 10000, 2)
        WHEN 'hectares' THEN ROUND(val * 10000, 2)
        WHEN 'are' THEN ROUND(val * 100, 2)
        WHEN 'a' THEN ROUND(val * 100, 2)
        WHEN 'bata' THEN ROUND(val * 14, 2)
        WHEN 'tumbak' THEN ROUND(val * 14, 2)
        WHEN 'ru' THEN ROUND(val * 14, 2)
        ELSE ROUND(val, 2)
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Pembuatan tipe ENUM secara idempotent
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'legal_status_enum') THEN
        CREATE TYPE legal_status_enum AS ENUM (
            'CLEAR',
            'SENGKETA',
            'BEDA_FISIK',
            'DISITA_BI',
            'RAMPASAN'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'document_type_enum') THEN
        CREATE TYPE document_type_enum AS ENUM (
            'SHM',
            'SHGB',
            'AJB',
            'GIRIK',
            'LETTER_C',
            'SPH',
            'PUTUSAN_PENGADILAN',
            'BERITA_ACARA_SITA',
            'LAINNYA'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'verification_status_enum') THEN
        CREATE TYPE verification_status_enum AS ENUM (
            'DRAFT_AI',
            'NEEDS_REVIEW',
            'VERIFIED'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'owner_type_enum') THEN
        CREATE TYPE owner_type_enum AS ENUM (
            'INDIVIDU',
            'KORPORASI',
            'INSTANSI_PEMERINTAH',
            'BANK_INDONESIA',
            'AHLI_WARIS'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role_enum') THEN
        CREATE TYPE user_role_enum AS ENUM (
            'ADMIN',
            'AUDITOR',
            'VIEWER',
            'GUEST'
        );
    END IF;
END
$$;

ALTER TYPE user_role_enum ADD VALUE IF NOT EXISTS 'GUEST';

-- 1. Tabel Spasial: parcels
CREATE TABLE IF NOT EXISTS parcels (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parcel_code VARCHAR(64) NOT NULL UNIQUE,
    name VARCHAR(255),
    desa_kelurahan VARCHAR(128),
    kecamatan VARCHAR(128),
    kabupaten_kota VARCHAR(128),
    provinsi VARCHAR(128) DEFAULT 'Jawa Barat',
    alamat_lengkap TEXT,
    legal_status legal_status_enum NOT NULL DEFAULT 'CLEAR',
    area_m2 NUMERIC(14, 2),
    gis_area_m2 NUMERIC(14, 2),
    original_area_value NUMERIC(14, 4),
    original_area_unit VARCHAR(32) DEFAULT 'm2',
    geom GEOMETRY(MULTIPOLYGON, 4326) NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_parcels_parcel_code ON parcels (parcel_code);
CREATE INDEX IF NOT EXISTS ix_parcels_desa_kelurahan ON parcels (desa_kelurahan);
CREATE INDEX IF NOT EXISTS ix_parcels_kecamatan ON parcels (kecamatan);
CREATE INDEX IF NOT EXISTS ix_parcels_kabupaten_kota ON parcels (kabupaten_kota);
CREATE INDEX IF NOT EXISTS ix_parcels_legal_status ON parcels (legal_status);
CREATE INDEX IF NOT EXISTS idx_parcels_geom ON parcels USING GIST (geom);

-- 2. Tabel Tabular: documents (mendukung orphaned records via parcel_id NULLABLE)
CREATE TABLE IF NOT EXISTS documents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parcel_id UUID REFERENCES parcels(id) ON DELETE SET NULL,
    document_number VARCHAR(128) NOT NULL,
    document_type document_type_enum NOT NULL,
    title VARCHAR(255),
    issue_date DATE,
    issuing_office VARCHAR(255),
    legal_status legal_status_enum NOT NULL DEFAULT 'CLEAR',
    stated_area_m2 NUMERIC(14, 2),
    original_area_value NUMERIC(14, 4),
    original_area_unit VARCHAR(32) DEFAULT 'm2',
    synology_file_path VARCHAR(512) NOT NULL,
    nextcloud_file_id VARCHAR(128),
    file_checksum_sha256 VARCHAR(64),
    verification_status verification_status_enum NOT NULL DEFAULT 'DRAFT_AI',
    verified_by VARCHAR(128),
    verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_documents_parcel_id ON documents (parcel_id);
CREATE INDEX IF NOT EXISTS ix_documents_document_number ON documents (document_number);
CREATE INDEX IF NOT EXISTS ix_documents_legal_status ON documents (legal_status);
CREATE INDEX IF NOT EXISTS ix_documents_verification_status ON documents (verification_status);

-- 3. Tabel Tabular: owners (riwayat kepemilikan berantai)
CREATE TABLE IF NOT EXISTS owners (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parcel_id UUID REFERENCES parcels(id) ON DELETE SET NULL,
    document_id UUID REFERENCES documents(id) ON DELETE CASCADE,
    owner_name VARCHAR(255) NOT NULL,
    owner_type owner_type_enum NOT NULL DEFAULT 'INDIVIDU',
    identity_number VARCHAR(64),
    sequence_order INTEGER NOT NULL DEFAULT 1,
    is_current_owner BOOLEAN NOT NULL DEFAULT TRUE,
    acquisition_type VARCHAR(64),
    acquisition_date DATE,
    transfer_notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_owners_parcel_id ON owners (parcel_id);
CREATE INDEX IF NOT EXISTS ix_owners_document_id ON owners (document_id);
CREATE INDEX IF NOT EXISTS ix_owners_owner_name ON owners (owner_name);
CREATE INDEX IF NOT EXISTS ix_owners_is_current_owner ON owners (is_current_owner);

-- 4. Tabel Tabular: ocr_raw_data (ekstraksi Claude AI & verifikasi HITL)
CREATE TABLE IF NOT EXISTS ocr_raw_data (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id UUID NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
    ocr_engine VARCHAR(64) NOT NULL DEFAULT 'claude-3-5-sonnet',
    raw_text TEXT,
    extracted_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    reviewed_json JSONB,
    confidence_score NUMERIC(5, 4),
    verification_status verification_status_enum NOT NULL DEFAULT 'DRAFT_AI',
    review_notes TEXT,
    reviewed_by VARCHAR(128),
    reviewed_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_ocr_raw_data_document_id ON ocr_raw_data (document_id);
CREATE INDEX IF NOT EXISTS ix_ocr_raw_data_verification_status ON ocr_raw_data (verification_status);
CREATE INDEX IF NOT EXISTS idx_ocr_raw_data_extracted_json ON ocr_raw_data USING GIN (extracted_json);

-- 5. Tabel Autentikasi & RBAC: users
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) NOT NULL UNIQUE,
    full_name VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role user_role_enum NOT NULL DEFAULT 'VIEWER',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_users_email ON users (email);
CREATE INDEX IF NOT EXISTS ix_users_role ON users (role);

-- 6. Tabel Guest Access JIT & Sesi Guest (Hermes AI Agent WhatsApp)
CREATE TABLE IF NOT EXISTS guest_access_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    short_code VARCHAR(12) NOT NULL UNIQUE,
    confirm_token_hash VARCHAR(64) NOT NULL UNIQUE,
    wait_token_hash VARCHAR(64) NOT NULL UNIQUE,
    guest_name VARCHAR(100),
    ip_address VARCHAR(64) NOT NULL,
    user_agent TEXT NOT NULL,
    device_summary VARCHAR(160) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'PENDING',
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    request_expires_at TIMESTAMPTZ NOT NULL,
    decided_at TIMESTAMPTZ,
    decided_via VARCHAR(32),
    hermes_notified_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_guest_access_requests_short_code ON guest_access_requests (short_code);
CREATE INDEX IF NOT EXISTS ix_guest_access_requests_confirm_token_hash ON guest_access_requests (confirm_token_hash);
CREATE INDEX IF NOT EXISTS ix_guest_access_requests_wait_token_hash ON guest_access_requests (wait_token_hash);
CREATE INDEX IF NOT EXISTS ix_guest_access_requests_ip_address ON guest_access_requests (ip_address);
CREATE INDEX IF NOT EXISTS ix_guest_access_requests_status ON guest_access_requests (status);
CREATE INDEX IF NOT EXISTS ix_guest_access_requests_requested_at ON guest_access_requests (requested_at);

CREATE TABLE IF NOT EXISTS guest_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id UUID NOT NULL UNIQUE REFERENCES guest_access_requests(id) ON DELETE CASCADE,
    ip_address VARCHAR(64) NOT NULL,
    device_summary VARCHAR(160) NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_guest_sessions_request_id ON guest_sessions (request_id);
CREATE INDEX IF NOT EXISTS ix_guest_sessions_expires_at ON guest_sessions (expires_at);

-- =============================================================================
-- SEED DATA SAMPEL DESA SUKAHARJA (JABODETABEK)
-- =============================================================================

INSERT INTO parcels (
    id, parcel_code, name, desa_kelurahan, kecamatan, kabupaten_kota, provinsi,
    alamat_lengkap, legal_status, area_m2, gis_area_m2, original_area_value, original_area_unit,
    geom, notes
) VALUES
(
    '11111111-1111-4111-8111-111111111101',
    'LDKH-SKH-001',
    'Persil Kebun Sukaharja Blok A1',
    'Sukaharja',
    'Sukamakmur',
    'Kabupaten Bogor',
    'Jawa Barat',
    'Blok Pasir Angin RT 02/01, Desa Sukaharja, Kec. Sukamakmur, Kab. Bogor',
    'CLEAR',
    normalize_area_to_m2(2500, 'm2'),
    2500.00,
    2500.0000,
    'm2',
    ST_GeomFromText('MULTIPOLYGON(((106.9500 -6.5800, 106.9505 -6.5800, 106.9505 -6.5795, 106.9500 -6.5795, 106.9500 -6.5800)))', 4326),
    'Aset berstatus Clear, sertifikat SHM terverifikasi.'
),
(
    '11111111-1111-4111-8111-111111111102',
    'LDKH-SKH-002',
    'Persil Sengketa Batas Blok B2',
    'Sukaharja',
    'Sukamakmur',
    'Kabupaten Bogor',
    'Jawa Barat',
    'Kampung Cibeureum, Desa Sukaharja, Kec. Sukamakmur, Kab. Bogor',
    'BEDA_FISIK',
    normalize_area_to_m2(1.2, 'Ha'),
    9850.00,
    1.2000,
    'Ha',
    ST_GeomFromText('MULTIPOLYGON(((106.9510 -6.5805, 106.9522 -6.5805, 106.9522 -6.5796, 106.9510 -6.5796, 106.9510 -6.5805)))', 4326),
    'Selisih luas dokumen (12.000 m2) vs pengukuran fisik GIS (9.850 m2); terdapat klaim batas warga.'
),
(
    '11111111-1111-4111-8111-111111111103',
    'LDKH-SKH-003',
    'Eks Lahan Jaminan BLBI Blok C3',
    'Sukaharja',
    'Sukamakmur',
    'Kabupaten Bogor',
    'Jawa Barat',
    'Jalan Raya Sukaharja KM 4, Desa Sukaharja, Kec. Sukamakmur, Kab. Bogor',
    'DISITA_BI',
    normalize_area_to_m2(4.5, 'Ha'),
    45000.00,
    4.5000,
    'Ha',
    ST_GeomFromText('MULTIPOLYGON(((106.9530 -6.5820, 106.9552 -6.5820, 106.9552 -6.5800, 106.9530 -6.5800, 106.9530 -6.5820)))', 4326),
    'Objek sitaan Bank Indonesia / Satgas BLBI berdasarkan Berita Acara Sita.'
)
ON CONFLICT (parcel_code) DO NOTHING;

-- Dokumen terkait 3 persil + 1 Orphaned Record (parcel_id = NULL)
INSERT INTO documents (
    id, parcel_id, document_number, document_type, title, issue_date, issuing_office,
    legal_status, stated_area_m2, original_area_value, original_area_unit,
    synology_file_path, nextcloud_file_id, verification_status, verified_by, verified_at
) VALUES
(
    '22222222-2222-4222-8222-222222222201',
    '11111111-1111-4111-8111-111111111101',
    'SHM-10.22.04.01.1.00412',
    'SHM',
    'Sertifikat Hak Milik Desa Sukaharja No. 412',
    '1998-06-15',
    'BPN Kabupaten Bogor',
    'CLEAR',
    normalize_area_to_m2(2500, 'm2'),
    2500.0000,
    'm2',
    'Sukaharja/SHM/SHM-00412-Sukaharja.pdf',
    'nc-file-00412',
    'VERIFIED',
    'admin_ldkh',
    NOW()
),
(
    '22222222-2222-4222-8222-222222222202',
    '11111111-1111-4111-8111-111111111102',
    'AJB-593/PPAT-SKM/1995',
    'AJB',
    'Akta Jual Beli Tanah Cibeureum Blok B2',
    '1995-11-20',
    'PPAT Kec. Sukamakmur',
    'BEDA_FISIK',
    normalize_area_to_m2(1.2, 'Ha'),
    1.2000,
    'Ha',
    'Sukaharja/AJB/AJB-593-1995.pdf',
    'nc-file-00593',
    'NEEDS_REVIEW',
    NULL,
    NULL
),
(
    '22222222-2222-4222-8222-222222222203',
    '11111111-1111-4111-8111-111111111103',
    'BA-SITA-BI/08/2003',
    'BERITA_ACARA_SITA',
    'Berita Acara Penyitaan Aset Bank Indonesia Blok C3',
    '2003-04-08',
    'Bank Indonesia / BPPN',
    'DISITA_BI',
    normalize_area_to_m2(4.5, 'Ha'),
    4.5000,
    'Ha',
    'Sukaharja/Sitaan-BI/BA-SITA-BI-08-2003.pdf',
    'nc-file-00803',
    'VERIFIED',
    'legal_auditor',
    NOW()
),
(
    '22222222-2222-4222-8222-222222222204',
    NULL,
    'LDKH-DOC-ORPHAN-001',
    'GIRIK',
    'Girik C No. 1147 Persil 28 D.III (Lokasi Fisik Belum Ditemukan)',
    '1984-03-12',
    'Kantor Desa Sukaharja',
    'BEDA_FISIK',
    normalize_area_to_m2(350, 'bata'),
    350.0000,
    'bata',
    'Orphaned/Sukaharja/GIRIK-1147-Orphan.pdf',
    'nc-file-01147',
    'DRAFT_AI',
    NULL,
    NULL
)
ON CONFLICT (id) DO NOTHING;

-- Riwayat Kepemilikan Berantai
INSERT INTO owners (
    id, parcel_id, document_id, owner_name, owner_type, sequence_order,
    is_current_owner, acquisition_type, acquisition_date, transfer_notes
) VALUES
(
    '33333333-3333-4333-8333-333333333301',
    '11111111-1111-4111-8111-111111111101',
    '22222222-2222-4222-8222-222222222201',
    'H. Endang Suryana',
    'INDIVIDU',
    1,
    FALSE,
    'WARIS',
    '1982-01-10',
    'Pemilik asal sebelum pelepasan hak ke LDKH.'
),
(
    '33333333-3333-4333-8333-333333333302',
    '11111111-1111-4111-8111-111111111101',
    '22222222-2222-4222-8222-222222222201',
    'Lee Darmawan Kertaraharja',
    'INDIVIDU',
    2,
    TRUE,
    'JUAL_BELI',
    '1998-06-15',
    'Pembelian sah tercatat pada SHM No. 412.'
),
(
    '33333333-3333-4333-8333-333333333303',
    '11111111-1111-4111-8111-111111111102',
    '22222222-2222-4222-8222-222222222202',
    'Lee Darmawan Kertaraharja',
    'INDIVIDU',
    1,
    TRUE,
    'JUAL_BELI',
    '1995-11-20',
    'Tercatat dalam AJB 593/PPAT-SKM/1995, perlu verifikasi ulang batas fisik.'
),
(
    '33333333-3333-4333-8333-333333333304',
    '11111111-1111-4111-8111-111111111103',
    '22222222-2222-4222-8222-222222222203',
    'Bank Indonesia (Eks Aset Sitaan)',
    'BANK_INDONESIA',
    1,
    TRUE,
    'SITA_BI',
    '2003-04-08',
    'Dalam penguasaan/sitaan Bank Indonesia.'
),
(
    '33333333-3333-4333-8333-333333333305',
    NULL,
    '22222222-2222-4222-8222-222222222204',
    'Ahli Waris M. Kartawijaya',
    'AHLI_WARIS',
    1,
    TRUE,
    'GIRIK_ASAL',
    '1984-03-12',
    'Orphaned record: pemilik tercantum di Girik, lokasi persil belum dipetakan di QGIS.'
)
ON CONFLICT (id) DO NOTHING;

-- Metadata OCR & Status Human-in-the-Loop
INSERT INTO ocr_raw_data (
    id, document_id, ocr_engine, raw_text, extracted_json, reviewed_json,
    confidence_score, verification_status, review_notes, reviewed_by, reviewed_at
) VALUES
(
    '44444444-4444-4444-8444-444444444401',
    '22222222-2222-4222-8222-222222222201',
    'claude-3-5-sonnet',
    'SERTIFIKAT HAK MILIK NO. 412 DESA SUKAHARJA LUAS 2.500 M2 ATAS NAMA LEE DARMAWAN KERTARAHARJA',
    '{"document_number": "SHM-10.22.04.01.1.00412", "area_value": 2500, "area_unit": "m2", "owner": "Lee Darmawan Kertaraharja", "desa": "Sukaharja"}'::jsonb,
    '{"document_number": "SHM-10.22.04.01.1.00412", "area_value": 2500, "area_unit": "m2", "owner": "Lee Darmawan Kertaraharja", "desa": "Sukaharja"}'::jsonb,
    0.9750,
    'VERIFIED',
    'Data teks sesuai dengan hasil scan PDF asli.',
    'admin_ldkh',
    NOW()
),
(
    '44444444-4444-4444-8444-444444444402',
    '22222222-2222-4222-8222-222222222202',
    'claude-3-5-sonnet',
    'AKTA JUAL BELI NO. 593/PPAT-SKM/1995 LUAS TANAH KURANG LEBIH 1,2 HA KAMPUNG CIBEUREUM',
    '{"document_number": "AJB-593/PPAT-SKM/1995", "area_value": 1.2, "area_unit": "Ha", "location": "Kampung Cibeureum, Sukaharja"}'::jsonb,
    NULL,
    0.8420,
    'NEEDS_REVIEW',
    'Tulisan tangan pada batas sebelah utara agak pudar, butuh verifikasi surveyor.',
    NULL,
    NULL
),
(
    '44444444-4444-4444-8444-444444444403',
    '22222222-2222-4222-8222-222222222203',
    'claude-3-5-sonnet',
    'BERITA ACARA PENYITAAN NO. BA-SITA-BI/08/2003 OBJEK TANAH 4,5 HEKTAR SUKAHARJA',
    '{"document_number": "BA-SITA-BI/08/2003", "area_value": 4.5, "area_unit": "Ha", "status": "DISITA_BI"}'::jsonb,
    '{"document_number": "BA-SITA-BI/08/2003", "area_value": 4.5, "area_unit": "Ha", "status": "DISITA_BI"}'::jsonb,
    0.9610,
    'VERIFIED',
    'Tervalidasi dengan arsip BPPN/BI.',
    'legal_auditor',
    NOW()
),
(
    '44444444-4444-4444-8444-444444444404',
    '22222222-2222-4222-8222-222222222204',
    'claude-3-5-sonnet',
    'PETIKAN BUKU LETTER C / GIRIK NO 1147 PERSIL 28 D.III LUAS 350 BATA DESA SUKAHARJA',
    '{"document_number": "LDKH-DOC-ORPHAN-001", "girik_no": "1147", "persil_no": "28 D.III", "area_value": 350, "area_unit": "bata", "area_m2_estimate": 4900, "location_hint": "Blok Timur Desa Sukaharja"}'::jsonb,
    NULL,
    0.7850,
    'DRAFT_AI',
    'Menunggu tim lapangan & QGIS untuk memetakan poligon persil.',
    NULL,
    NULL
)
ON CONFLICT (document_id) DO NOTHING;

-- Seed akun Admin default untuk pengembangan lokal
INSERT INTO users (
    id, email, full_name, password_hash, role, is_active
) VALUES (
    '76f6ca9d-59b3-44bc-afa0-af4b6329e763',
    'rafly.rizky@rbeverything.com',
    'Rafly Rizky (Admin LDKH)',
    'pbkdf2_sha256$310000$c0e81d0d18857bec38933fdb5bf2900f$01ea8c62e14f91673d69efa79276d852bdbd90bb1a03da89271ebcb338efedbd',
    'ADMIN',
    TRUE
)
ON CONFLICT (email) DO NOTHING;
