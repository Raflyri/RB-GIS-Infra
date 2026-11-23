# Paket Connector Hermes GIS Guest Bridge (CT 101 · `10.10.10.167`)

Paket mandiri ini menghubungkan **GIS Backend (CT 400 · `172.16.10.130:8000`)** dengan **Hermes AI Agent / WhatsApp Bridge (CT 101 · `10.10.10.167:8787`)** melalui jalur privat **ZeroTier Tunnel** yang dirutekan oleh MikroTik.

---

## 1. Prasyarat Jaringan & Proxmox Firewall (CT 101 `net0`)

Karena **Proxmox Firewall aktif pada `CT 101`** dan antarmuka `eth0` menggunakan `mtu 1280`, pastikan aturan firewall berikut dibuka pada **Proxmox Node `10.10.10.150` → CT 101 → Firewall**:

- **Inbound (di CT 101 `net0`):**
  - `IN ACCEPT -p tcp -dport 8787 -source 172.16.10.130` *(mengizinkan webhook `POST /webhook/gis-guest` dari GIS Backend saja)*
- **Outbound (di CT 101 `net0`):**
  - `OUT ACCEPT -p tcp -dport 8000 -dest 172.16.10.130` *(mengizinkan callback keputusan & recovery polling ke GIS Backend)*
- **Di sisi GIS Backend (CT 400 `172.16.10.130`):**
  - Pastikan UFW / Proxmox Firewall mengizinkan `10.10.10.167` mengakses port `8000/tcp`.

Contoh perintah di Proxmox Host `10.10.10.150` (`/etc/pve/firewall/101.fw`):
```ini
[RULES]
IN ACCEPT -p tcp -dport 8787 -source 172.16.10.130 -log nolog # GIS Backend Webhook
OUT ACCEPT -p tcp -dport 8000 -dest 172.16.10.130 -log nolog # GIS Backend Decision API
```

---

## 2. Langkah Deployment di CT 101 (`10.10.10.167`)

1. **Salin seluruh folder `integrations/hermes-guest-bridge/` ke `/opt/hermes-guest-bridge` di CT 101:**
   ```bash
   mkdir -p /opt/hermes-guest-bridge
   # Salin gis_hermes_bridge.py, requirements.txt, .env.example, hermes-gis-bridge.service
   ```
2. **Buat virtualenv & instal dependensi ringan:**
   ```bash
   cd /opt/hermes-guest-bridge
   python3 -m venv .venv
   /opt/hermes-guest-bridge/.venv/bin/pip install -r requirements.txt
   ```
3. **Konfigurasi `.env`:**
   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env
   ```
   - Generate shared secret 64 hex dengan: `openssl rand -hex 32`
   - Samakan nilai `HERMES_SHARED_SECRET` di `.env` CT 101 dan `backend/.env` di CT 400 (`172.16.10.130`).
   - Isi `ALLOWED_OWNER_WA_NUMBER` dengan nomor WhatsApp Owner (misal `6281234567890`).
4. **Daftarkan & jalankan service `systemd`:**
   ```bash
   cp /opt/hermes-guest-bridge/hermes-gis-bridge.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable hermes-gis-bridge.service
   systemctl start hermes-gis-bridge.service
   systemctl status hermes-gis-bridge.service --no-pager
   ```
5. **Integrasikan Tools & System Prompt ke Hermes Agent (`RBot`):**
   - Daftarkan fungsi dari `gemini_tool_spec.json` dan instruksi dari `HERMES_SYSTEM_PROMPT.md` ke konfigurasi Hermes AI Agent.

---

## 3. Uji Koneksi Privat ZeroTier (`curl`)

1. **Dari CT 101 (`10.10.10.167`) ke Bridge Lokal:**
   ```bash
   curl -s http://127.0.0.1:8787/health
   ```
2. **Dari CT 400 (`172.16.10.130`) ke Bridge CT 101 (`10.10.10.167:8787`):**
   ```bash
   curl -s http://10.10.10.167:8787/health
   ```
3. **Dari CT 101 (`10.10.10.167`) menguji signature HMAC ke GIS Backend (`172.16.10.130:8000`):**
   ```bash
   /opt/hermes-guest-bridge/.venv/bin/python /opt/hermes-guest-bridge/gis_hermes_bridge.py --action LIST
   ```
4. **Verifikasi Blokir Publik di Nginx (`https://gis.rbeverything.com/`):**
   ```bash
   curl -i https://gis.rbeverything.com/api/v1/auth/guest/hermes/pending
   # Harus mengembalikan HTTP/2 403 Forbidden
   ```
