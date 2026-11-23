# Blueprint Arsitektur: Just-in-Time (JIT) Guest Access Approval via Hermes AI Agent (WhatsApp) & Strict Read-Only PDF Viewer

Dokumen ini mendefinisikan arsitektur teknis, topologi jaringan privat ZeroTier, skema database, kontrol keamanan berlapis, serta alur integrasi end-to-end untuk fitur **JIT Guest Access Approval** melalui **Hermes AI Agent (RBot / WhatsApp)** dan **Strict Read-Only Canvas PDF Viewer** pada Sistem Web GIS Digitalisasi Tanah LDKH (`https://gis.rbeverything.com/`).

---

## 1. Hasil Audit Infrastruktur & Komponen Eksisting

Berdasarkan audit langsung pada repositori `rb-gis` dan konfigurasi deployment produksi Proxmox VE:

| Komponen | Lokasi / Kode Sumber | Kondisi Eksisting | Kebutuhan Penyesuaian Enhancement |
| :--- | :--- | :--- | :--- |
| **Backend FastAPI** | `backend/app/main.py`, `infra/proxmox/systemd/ldkh-backend.service` | Berjalan dengan Uvicorn di port **`8000`** (`0.0.0.0:8000`, `--workers 2`, `--proxy-headers`). Middleware `reverse_proxy_guard_middleware` mengizinkan trafik hanya dari `TRUSTED_PROXY_IPS` (`127.0.0.1`, `::1`, `172.16.10.133`, `172.16.10.131`) atau header `x-forwarded-by-nginx: true`. | Izinkan trafik langsung via ZeroTier dari `HERMES_ALLOWED_IPS` (`10.10.10.167`) khusus rute `/api/v1/auth/guest/hermes/*`, dan tolak jika melewati Nginx publik. |
| **Autentikasi & RBAC** | `backend/app/core/security.py`, `backend/app/models/enums.py` | Menggunakan JWT HS256 (`scope: "ldkh:auth"`) via `Authorization: Bearer` dan cookie `HttpOnly` bernama `ldkh_access_token`. Role eksisting: `ADMIN`, `AUDITOR`, `VIEWER`. Beberapa endpoint mutasi masih memakai `require_editor` (`AUDITOR` + `ADMIN`). | Tambahkan role `GUEST` pada `UserRole`, validasi tabel `guest_sessions` (3 jam + cek `revoked_at`) di `get_current_user` (kembalikan `401 GUEST_SESSION_EXPIRED`), dan kunci **seluruh** endpoint mutasi (`POST/PUT/PATCH/DELETE`) ke `require_admin`. |
| **Nginx Reverse Proxy** | `infra/proxmox/nginx/nginx.conf`, `infra/nginx/nginx.conf` | Nginx CT Nginx (`172.16.10.133`) menerima trafik dari Cloudflare Tunnel (`cloudflared`) dan meneruskan `/api/` -> `172.16.10.130:8000`, `/` -> `172.16.10.131:3000`, serta `/internal-pdf/` via `X-Accel-Redirect`. | Tambahkan blok `location ^~ /api/v1/auth/guest/hermes/ { return 403; }` sebelum `location /api/` agar endpoint internal Hermes tidak dapat diakses dari internet publik, serta perketat header cache/inline `/internal-pdf/`. |
| **Streaming PDF** | `backend/app/api/endpoints/files.py`, `backend/app/core/pdf_security.py` | Menggunakan short-lived signed JWT (`scope: "pdf:stream"`) dengan header `Content-Disposition: inline` dan `Cache-Control: private, no-store`. | Tambahkan header lengkap `Cache-Control: no-store, no-cache, must-revalidate, private`, `Pragma: no-cache`, dan `X-Content-Type-Options: nosniff` di seluruh jalur respons (`accel`, `FileResponse`, fallback), serta pastikan tidak ada eksposur path `/mnt/...`. |
| **Frontend Login & UI** | `frontend/src/components/auth/LoginPage.tsx`, `Dashboard.tsx` | Halaman login dirender di `Dashboard.tsx` saat `!currentUser` (belum ada route `/login` khusus maupun `/guest-approval/[token]`). | Tambahkan tombol **Login as Guest**, dialog permintaan akses, **Waiting Room** (polling 3 detik + auto-redirect 5 detik saat ditolak/expired), route `/login` & `/guest-approval/[token]`, mode strict read-only, serta banner countdown 3 jam di desktop & mobile. |
| **Frontend PDF Viewer** | `frontend/src/components/pdf/DocumentViewerPanel.tsx` | Merender `<iframe src={pdfUrl} />` untuk semua role; toolbar bawaan browser menampilkan tombol Download & Print. `pdfjs-dist` v3.11.174 & `/pdf.worker.min.js` sudah terpasang di proyek. | Khusus `role === "GUEST"`, ganti `<iframe>` dengan **Canvas PDF Viewer** (`pdfjs-dist`) ber-watermark diagonal, tanpa tombol Download/Print, blokir klik kanan & `Ctrl/Cmd+S/P`, serta proteksi `@media print`. |

---

## 2. Topologi Jaringan & Routing Komunikasi Privat ZeroTier

Kedua cluster Proxmox terhubung secara privat melalui **ZeroTier Tunnel yang dirutekan di MikroTik**, sehingga komunikasi server-to-server **GIS Backend <-> Hermes Bridge** berjalan langsung melalui IP privat tanpa melewati internet publik ataupun Cloudflare Tunnel.

```mermaid
flowchart LR
    subgraph Public["Internet Publik (HP Guest & HP Owner)"]
        GuestBrowser["Browser Guest<br/>(Desktop / Mobile)"]
        OwnerWA["WhatsApp Owner<br/>& Browser HP Owner"]
    end

    subgraph CF["Cloudflare Edge & Tunnel"]
        CFTunnel["gis.rbeverything.com<br/>(CF-Connecting-IP)"]
    end

    subgraph GISCluster["Cluster Web GIS (Proxmox 172.16.10.1 · Subnet 172.16.10.0/24)"]
        Nginx["Nginx Reverse Proxy<br/>(Blokir /api/v1/auth/guest/hermes/* -> 403)"]
        CT410["CT 410 GIS-Frontend<br/>172.16.10.131:3000 (Next.js)"]
        CT400["CT 400 GIS-Backend<br/>172.16.10.130:8000 (FastAPI)"]
        CT420["CT 420 GIS-Database<br/>172.16.10.132:5432 (PostgreSQL + PostGIS)"]
        Synology["Synology Vault<br/>192.168.18.130 (Mount Read-Only)"]
    end

    subgraph Tunnel["MikroTik ZeroTier Tunnel (Private L3 Routing)"]
        ZT["172.16.10.130 <-> 10.10.10.167"]
    end

    subgraph HermesCluster["Cluster Hermes AI Agent (Proxmox 10.10.10.150 · Subnet 10.10.10.0/24)"]
        CT101["CT 101 hermes-agent<br/>10.10.10.167 (mtu 1280, Proxmox FW)<br/>Bridge :8787 + WhatsApp + Gemini API"]
    end

    GuestBrowser -->|HTTPS| CFTunnel
    OwnerWA -->|HTTPS /guest-approval/token| CFTunnel
    CFTunnel --> Nginx
    Nginx -->|"/ (UI & Approval Page)"| CT410
    Nginx -->|"/api/* (kecuali /hermes/*)"| CT400
    CT400 --> CT420
    CT400 -.->|Read-Only| Synology

    CT400 -->|"POST http://10.10.10.167:8787/webhook/gis-guest<br/>(HMAC-SHA256 + Timestamp)"| ZT
    ZT --> CT101
    CT101 -->|"GET /pending & POST /decision<br/>http://172.16.10.130:8000/api/v1/auth/guest/hermes/*<br/>(IP Allowlist + HMAC-SHA256)"| ZT
    CT101 <-->|"Pesan WA & Balasan Yes/No/Cabut"| OwnerWA
```

### Aturan Routing Komunikasi

1. **GIS -> Hermes (Direct Push via ZeroTier):**
   - `CT 400` (`172.16.10.130`) mengirim webhook `POST` langsung ke `http://10.10.10.167:8787/webhook/gis-guest` (timeout 6 detik, retry 2x backoff 2 detik) dengan header `X-Hermes-Timestamp` dan `X-Hermes-Signature`.
2. **Hermes -> GIS (Callback Keputusan & Recovery via ZeroTier):**
   - `CT 101` (`10.10.10.167`) memanggil langsung IP privat backend:
     - `GET http://172.16.10.130:8000/api/v1/auth/guest/hermes/pending`
     - `POST http://172.16.10.130:8000/api/v1/auth/guest/hermes/decision`
3. **Unique Approval URL (Untuk Dibuka Owner di HP):**
   - Menggunakan domain publik `https://gis.rbeverything.com/guest-approval/<confirm_token>`.
4. **Blokir Publik di Nginx:**
   - Rute `/api/v1/auth/guest/hermes/*` diblokir permanen (`403 Forbidden`) pada Nginx publik sehingga tidak pernah terekspos ke Cloudflare Tunnel / internet publik.

---

## 3. Alur Sekuensial Just-in-Time (JIT) Guest Access

```mermaid
sequenceDiagram
    autonumber
    actor Guest as Guest Browser
    participant FE as Next.js Frontend
    participant API as FastAPI Backend (172.16.10.130)
    participant DB as PostgreSQL (172.16.10.132)
    participant Bridge as Hermes Bridge CT 101 (10.10.10.167:8787)
    actor Owner as Owner WhatsApp

    Guest->>FE: Klik "Login as Guest" + Nama/Instansi (opsional)
    FE->>API: POST /api/v1/auth/guest/request
    API->>API: Ekstrak IP (CF-Connecting-IP), Rate Limit (3 req/15m), Parse Device & Waktu WIB
    API->>DB: Simpan guest_access_requests (PENDING, TTL 30 menit, SHA-256 token hash)
    API-->>FE: { short_code: "G-XXXX", wait_token, request_expires_at }
    FE-->>Guest: Masuk Waiting Room (Polling setiap 3 detik)

    API-)Bridge: Background POST /webhook/gis-guest (HMAC-SHA256)
    Bridge-->>API: 200 OK (Backend catat hermes_notified_at)
    Bridge->>Owner: Kirim pesan WA (#G-XXXX, Device, IP, WIB, Yes/No, Approval URL)

    alt Jalur A: Owner Balas via WhatsApp (Hermes AI Agent)
        Owner->>Bridge: Balas "Yes" atau "Yes #G-XXXX" (Validasi ALLOWED_OWNER_WA_NUMBER)
        Bridge->>API: POST /api/v1/auth/guest/hermes/decision (IP Allowlist + HMAC)
        API->>DB: Update status APPROVED, decided_via = WHATSAPP_HERMES
    else Jalur B: Owner Klik Unique Approval URL di HP
        Owner->>FE: Buka https://gis.rbeverything.com/guest-approval/<confirm_token>
        FE->>API: GET /api/v1/auth/guest/approval/{token}
        Owner->>FE: Klik "Izinkan Masuk (Yes)"
        FE->>API: POST /api/v1/auth/guest/approval/{token}
        API->>DB: Update status APPROVED, decided_via = APPROVAL_URL (single-use)
    end

    FE->>API: GET /api/v1/auth/guest/status?wait_token=...
    API-->>FE: { status: "APPROVED" }
    FE->>API: POST /api/v1/auth/guest/exchange { wait_token }
    API->>DB: Buat guest_sessions (expires_at = NOW + 3 jam)
    API-->>FE: Guest JWT (role: GUEST, sid, short_code) + HttpOnly Cookie
    FE-->>Guest: Redirect ke / (Mode Strict Read-Only + Countdown 3 Jam)
```

---

## 4. Skema Database (`guest_access_requests` & `guest_sessions`)

1. **`guest_access_requests`:**
   - `id` (`UUID` PK)
   - `short_code` (`VARCHAR(12)`, unique, format `G-XXXX`, huruf kapital tanpa karakter ambigu `O/0/I/1`)
   - `confirm_token_hash` (`VARCHAR(64)`, unique — SHA-256 dari `confirm_token` 256-bit)
   - `wait_token_hash` (`VARCHAR(64)`, unique — SHA-256 dari `wait_token` 256-bit)
   - `guest_name` (`VARCHAR(100)`, nullable)
   - `ip_address` (`VARCHAR(64)`, not null)
   - `user_agent` (`TEXT`, not null)
   - `device_summary` (`VARCHAR(160)`, not null)
   - `status` (`VARCHAR(24)`: `PENDING`, `APPROVED`, `REJECTED`, `EXPIRED`, `REVOKED`)
   - `requested_at` (`TIMESTAMPTZ`, default `NOW()`)
   - `request_expires_at` (`TIMESTAMPTZ` — `requested_at + 30 menit`)
   - `decided_at` (`TIMESTAMPTZ`, nullable)
   - `decided_via` (`VARCHAR(32)`, nullable — `WHATSAPP_HERMES` / `APPROVAL_URL`)
   - `hermes_notified_at` (`TIMESTAMPTZ`, nullable)

2. **`guest_sessions`:**
   - `id` (`UUID` PK — claim `sid` di JWT)
   - `request_id` (`UUID` FK -> `guest_access_requests.id`, unique)
   - `ip_address` (`VARCHAR(64)`)
   - `device_summary` (`VARCHAR(160)`)
   - `started_at` (`TIMESTAMPTZ`)
   - `expires_at` (`TIMESTAMPTZ` — `started_at + 3 jam`)
   - `revoked_at` (`TIMESTAMPTZ`, nullable)

---

## 5. Matriks Kontrol Keamanan Berlapis

| Layer Keamanan | Mekanisme Implementasi | Efek Penolakan |
| :--- | :--- | :--- |
| **Deteksi IP Publik Asli** | Prioritas `CF-Connecting-IP` -> `X-Forwarded-For` (IP pertama) -> `X-Real-IP` -> `request.client.host`. | Mencegah spoofing/akumulasi rate limit ke IP proxy Nginx. |
| **Anti-Spam Request** | Rate limiter sliding window: maks. **3 permintaan / IP / 15 menit** pada `POST /api/v1/auth/guest/request`. | `429 Too Many Requests` (Bahasa Indonesia). |
| **Isolasi Rute Hermes (Nginx)** | `location ^~ /api/v1/auth/guest/hermes/ { return 403; }` pada server block publik Nginx. | `403 Forbidden` dari internet publik / Cloudflare Tunnel. |
| **Double-Layer Hermes Verification** | 1) Cek `request.client.host` terhadap `HERMES_ALLOWED_IPS` (`10.10.10.167`) + tolak header proxy publik; 2) Validasi `X-Hermes-Timestamp` (maks selisih `<= 300` detik) & `X-Hermes-Signature` (`HMAC_SHA256(HERMES_SHARED_SECRET, f"{timestamp}.{raw_body}")`). | `403 Forbidden` (IP tidak diizinkan) / `401 Unauthorized` (Signature/Timestamp tidak valid). |
| **TTL & Single-Use Token** | Permintaan hangus otomatis setelah **30 menit** (`EXPIRED`). `confirm_token` & `wait_token` hanya dapat ditukar 1x (*single-use*). | `410 Gone` / `409 Conflict`. |
| **Session Expiry & Revoke** | `get_current_user` memeriksa `guest_sessions` (`revoked_at IS NULL` dan `NOW() < expires_at`) pada setiap request `GUEST`. | `401 Unauthorized` dengan kode `GUEST_SESSION_EXPIRED`. |
| **Strict Read-Only RBAC** | Seluruh endpoint mutasi (`POST`, `PUT`, `PATCH`, `DELETE` untuk parcels, documents, owners, upload PDF, import, OCR) dikunci dengan `require_admin`. | `403 Forbidden` untuk role `GUEST`. |
| **PDF Stream & Canvas Viewer** | Header `Content-Disposition: inline`, `Cache-Control: no-store, no-cache, must-revalidate, private`, `Pragma: no-cache`, `X-Content-Type-Options: nosniff`. UI Guest merender via `<canvas>` (`pdfjs-dist`), watermark diagonal dinamis, tanpa tombol Download/Print, blokir klik kanan & `Ctrl/Cmd+S/P`, serta `@media print`. | Mengurangi risiko unduh/cetak dokumen legal secara langsung oleh Guest. |
