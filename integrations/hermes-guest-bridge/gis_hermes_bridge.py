"""Bridge ringan Hermes AI Agent (CT 101) <-> Web GIS LDKH Backend (CT 400) via ZeroTier."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import json
import logging
import os
import re
import shlex
import subprocess
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any, Literal, Optional

import requests
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request, status
from pydantic import BaseModel, Field

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("gis_hermes_bridge")


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _normalize_phone_digits(raw: Optional[str]) -> str:
    if not raw:
        return ""
    local_part = raw.split("@", 1)[0].split(":", 1)[0]
    digits = re.sub(r"\D+", "", local_part)
    if digits.startswith("0") and len(digits) >= 9:
        digits = "62" + digits[1:]
    return digits


GIS_INTERNAL_API_URL = os.getenv(
    "GIS_INTERNAL_API_URL", "http://172.16.10.130:8000"
).rstrip("/")
ALLOWED_GIS_BACKEND_IPS = {
    ip.strip()
    for ip in os.getenv("ALLOWED_GIS_BACKEND_IP", "172.16.10.130").split(",")
    if ip.strip()
}
BRIDGE_HOST = os.getenv("BRIDGE_HOST", "0.0.0.0")
BRIDGE_PORT = int(os.getenv("BRIDGE_PORT", "8787"))
HERMES_SHARED_SECRET = os.getenv("HERMES_SHARED_SECRET", "")
ALLOWED_OWNER_WA_NUMBER = _normalize_phone_digits(
    os.getenv("ALLOWED_OWNER_WA_NUMBER", "")
)
HERMES_WA_BRIDGE_URL = os.getenv("HERMES_WA_BRIDGE_URL", "http://127.0.0.1:3000/send").strip()
HERMES_WA_WEBHOOK_URL = os.getenv("HERMES_WA_WEBHOOK_URL", "").strip()
HERMES_WA_SEND_CMD = os.getenv("HERMES_WA_SEND_CMD", "").strip()
ENABLE_RECOVERY_LOOP = _env_bool("ENABLE_RECOVERY_LOOP", True)
RECOVERY_POLL_SECONDS = max(10, int(os.getenv("RECOVERY_POLL_SECONDS", "30")))
MAX_SIGNATURE_DRIFT_SECONDS = 300


def compute_hmac_signature(secret: str, timestamp: str, raw_body: bytes) -> str:
    """Menghitung signature HMAC-SHA256 untuk '{timestamp}.{raw_body}'."""
    payload = f"{timestamp}.".encode("utf-8") + raw_body
    return hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()


def build_signed_headers(raw_body: bytes = b"") -> dict[str, str]:
    """Membuat header X-Hermes-Timestamp dan X-Hermes-Signature untuk panggilan ZeroTier ke GIS."""
    if not HERMES_SHARED_SECRET:
        raise RuntimeError("HERMES_SHARED_SECRET belum dikonfigurasi pada environment bridge.")
    ts_str = str(int(datetime.now(timezone.utc).timestamp()))
    sig = compute_hmac_signature(HERMES_SHARED_SECRET, ts_str, raw_body)
    return {
        "Content-Type": "application/json",
        "X-Hermes-Timestamp": ts_str,
        "X-Hermes-Signature": sig,
    }


def verify_owner_sender(sender_wa: Optional[str]) -> bool:
    """Memastikan pengirim perintah balasan WhatsApp adalah nomor Owner resmi."""
    if not ALLOWED_OWNER_WA_NUMBER:
        logger.warning("ALLOWED_OWNER_WA_NUMBER belum diisi; menolak validasi pengirim demi keamanan.")
        return False
    normalized_sender = _normalize_phone_digits(sender_wa)
    return bool(normalized_sender) and hmac.compare_digest(
        normalized_sender, ALLOWED_OWNER_WA_NUMBER
    )


def format_whatsapp_notification(payload: dict[str, Any]) -> str:
    """Memformat pesan notifikasi WhatsApp untuk Owner beserta kode #G-XXXX & Unique Approval URL."""
    short_code = str(payload.get("short_code") or "G-XXXX").lstrip("#")
    guest_name = payload.get("guest_name")
    device_summary = payload.get("device_summary") or "Perangkat Tidak Dikenal"
    ip_address = payload.get("ip_address") or "-"
    requested_at_wib = payload.get("requested_at_wib") or "-"
    approval_url = payload.get("approval_url") or ""
    target_url = payload.get("target_url") or "https://gis.rbeverything.com/"

    base_message = payload.get("message") or (
        f"Terdapat permintaan masuk baru dari device {device_summary} "
        f"dengan ip {ip_address} pada {requested_at_wib}. "
        "Mohon konfirmasi apakah diizinkan masuk atau tidak? Yes No"
    )

    lines = [
        "🔐 *PERMINTAAN AKSES GUEST WEB GIS LDKH*",
        f"Kode Permintaan: *#{short_code}*",
    ]
    if guest_name:
        lines.append(f"Nama / Instansi: *{guest_name}*")
    lines.extend(
        [
            f"Target: {target_url}",
            "",
            base_message,
        ]
    )
    if approval_url:
        lines.extend(
            [
                "",
                "🔗 *Konfirmasi Cepat (1-Klik dari HP):*",
                approval_url,
            ]
        )
    lines.extend(
        [
            "",
            "💬 *Atau balas langsung pesan ini:*",
            f"• Ketik *Yes* atau *Yes #{short_code}* untuk mengizinkan (akses Read-Only 3 jam)",
            f"• Ketik *No* atau *No #{short_code}* untuk menolak",
        ]
    )
    return "\n".join(lines)


def send_whatsapp_to_owner(message: str, payload: Optional[dict[str, Any]] = None) -> bool:
    """Hook pengiriman pesan WhatsApp ke Owner melalui adapter WhatsApp Hermes CT 101.

    Urutan prioritas integrasi:
    1. `HERMES_WA_SEND_CMD` (jika memanggil script/CLI lokal Hermes)
    2. `HERMES_WA_WEBHOOK_URL` (jika memakai relay webhook kustom)
    3. `HERMES_WA_BRIDGE_URL` (endpoint HTTP lokal WhatsApp Bridge Baileys `127.0.0.1:3000/send`)
    """
    owner_digits = ALLOWED_OWNER_WA_NUMBER
    if not owner_digits:
        logger.error("ALLOWED_OWNER_WA_NUMBER belum diatur; pesan WhatsApp tidak dapat dikirim.")
        return False

    if HERMES_WA_SEND_CMD:
        cmd_parts = shlex.split(HERMES_WA_SEND_CMD) + [owner_digits, message]
        result = subprocess.run(cmd_parts, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            return True
        logger.error("HERMES_WA_SEND_CMD gagal (%s): %s", result.returncode, result.stderr)
        return False

    if HERMES_WA_WEBHOOK_URL:
        resp = requests.post(
            HERMES_WA_WEBHOOK_URL,
            json={"to": owner_digits, "message": message, "metadata": payload or {}},
            timeout=10,
        )
        if 200 <= resp.status_code < 300:
            return True
        logger.error("HERMES_WA_WEBHOOK_URL gagal (%s): %s", resp.status_code, resp.text)
        return False

    if HERMES_WA_BRIDGE_URL:
        chat_jid = f"{owner_digits}@s.whatsapp.net"
        resp = requests.post(
            HERMES_WA_BRIDGE_URL,
            json={
                "chatId": chat_jid,
                "message": message,
            },
            timeout=10,
        )
        if 200 <= resp.status_code < 300:
            return True
        logger.warning(
            "Bridge WhatsApp lokal (%s) merespons status %s: %s",
            HERMES_WA_BRIDGE_URL,
            resp.status_code,
            resp.text[:300],
        )
        return False

    logger.info("Mode log-only (adapter WA belum diset). Pesan untuk %s:\n%s", owner_digits, message)
    return True


def send_decision(
    action: Literal["APPROVE", "REJECT", "REVOKE"],
    short_code: Optional[str] = None,
    sender_wa: Optional[str] = None,
) -> dict[str, Any]:
    """Mengirim keputusan APPROVE / REJECT / REVOKE langsung ke GIS Backend via ZeroTier."""
    if sender_wa is not None and not verify_owner_sender(sender_wa):
        raise PermissionError(
            "Akses ditolak: hanya nomor WhatsApp Owner resmi yang berhak memberi keputusan."
        )

    body_obj: dict[str, Any] = {"action": action}
    if short_code:
        body_obj["short_code"] = short_code.strip().upper()
    raw_body = json.dumps(body_obj, separators=(",", ":")).encode("utf-8")
    headers = build_signed_headers(raw_body)

    url = f"{GIS_INTERNAL_API_URL}/api/v1/auth/guest/hermes/decision"
    resp = requests.post(url, data=raw_body, headers=headers, timeout=8)
    try:
        data = resp.json()
    except ValueError:
        data = {"detail": resp.text}

    return {
        "ok": 200 <= resp.status_code < 300,
        "status_code": resp.status_code,
        "data": data,
    }


def list_pending_guests(
    include_notified: bool = True,
    sender_wa: Optional[str] = None,
) -> dict[str, Any]:
    """Mengambil daftar permintaan akses Guest yang masih PENDING dari GIS Backend via ZeroTier."""
    if sender_wa is not None and not verify_owner_sender(sender_wa):
        raise PermissionError(
            "Akses ditolak: hanya nomor WhatsApp Owner resmi yang dapat melihat antrean Guest."
        )

    headers = build_signed_headers(b"")
    url = f"{GIS_INTERNAL_API_URL}/api/v1/auth/guest/hermes/pending"
    resp = requests.get(
        url,
        params={"include_notified": str(include_notified).lower()},
        headers=headers,
        timeout=8,
    )
    try:
        data = resp.json()
    except ValueError:
        data = {"detail": resp.text}

    return {
        "ok": 200 <= resp.status_code < 300,
        "status_code": resp.status_code,
        "data": data,
    }


async def _recovery_poll_loop() -> None:
    """Loop latar belakang opsional setiap 30 detik untuk mengambil permintaan PENDING yang terlewat."""
    logger.info(
        "Recovery polling loop aktif (interval %s detik -> %s).",
        RECOVERY_POLL_SECONDS,
        GIS_INTERNAL_API_URL,
    )
    while True:
        try:
            res = await asyncio.to_thread(list_pending_guests, False, None)
            if res["ok"]:
                items = res["data"].get("items") or []
                for item in items:
                    msg = format_whatsapp_notification(item)
                    await asyncio.to_thread(send_whatsapp_to_owner, msg, item)
            elif res["status_code"] not in (404,):
                logger.warning("Recovery polling HTTP %s: %s", res["status_code"], res["data"])
        except Exception as exc:
            logger.warning("Recovery polling gagal menghubungi GIS Backend: %s", exc)
        await asyncio.sleep(RECOVERY_POLL_SECONDS)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    task: Optional[asyncio.Task[None]] = None
    if ENABLE_RECOVERY_LOOP and HERMES_SHARED_SECRET:
        task = asyncio.create_task(_recovery_poll_loop())
    try:
        yield
    finally:
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass


app = FastAPI(
    title="Hermes GIS Guest Access Bridge",
    version="1.0.0",
    lifespan=lifespan,
)


class InternalDecisionInput(BaseModel):
    action: Literal["APPROVE", "REJECT", "REVOKE"]
    short_code: Optional[str] = Field(default=None, max_length=16)
    sender_wa: Optional[str] = Field(default=None, max_length=64)


async def _verify_gis_backend_webhook(request: Request) -> bytes:
    client_ip = request.client.host if request.client and request.client.host else ""
    if client_ip not in ALLOWED_GIS_BACKEND_IPS and client_ip not in ("127.0.0.1", "::1"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"IP pengirim {client_ip} tidak diizinkan mengakses webhook Hermes.",
        )

    ts_header = (request.headers.get("x-hermes-timestamp") or "").strip()
    sig_header = (request.headers.get("x-hermes-signature") or "").strip()
    if not ts_header or not sig_header:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Header X-Hermes-Timestamp dan X-Hermes-Signature wajib ada.",
        )

    try:
        req_ts = int(ts_header)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Format X-Hermes-Timestamp tidak valid.",
        ) from exc

    now_ts = int(datetime.now(timezone.utc).timestamp())
    if abs(now_ts - req_ts) > MAX_SIGNATURE_DRIFT_SECONDS:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Timestamp webhook kedaluwarsa.",
        )

    if not HERMES_SHARED_SECRET:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="HERMES_SHARED_SECRET belum dikonfigurasi.",
        )

    raw_body = await request.body()
    expected = compute_hmac_signature(HERMES_SHARED_SECRET, ts_header, raw_body)
    provided = sig_header.lower().removeprefix("sha256=")
    if not hmac.compare_digest(expected, provided):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Signature HMAC-SHA256 webhook tidak valid.",
        )
    return raw_body


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "service": "hermes-gis-guest-bridge",
        "gis_internal_api_url": GIS_INTERNAL_API_URL,
        "recovery_loop_enabled": ENABLE_RECOVERY_LOOP,
    }


@app.post("/webhook/gis-guest")
async def receive_gis_guest_webhook(request: Request) -> dict[str, Any]:
    """Menerima push permintaan Guest baru dari GIS Backend (CT 400) lalu kirim WA ke Owner."""
    raw_body = await _verify_gis_backend_webhook(request)
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Payload JSON webhook tidak valid.",
        ) from exc

    message = format_whatsapp_notification(payload)
    delivered = await asyncio.to_thread(send_whatsapp_to_owner, message, payload)
    if not delivered:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Gagal meneruskan notifikasi WhatsApp ke Owner.",
        )

    return {
        "status": "notified",
        "short_code": payload.get("short_code"),
    }


@app.post("/internal/decision")
def internal_decision_endpoint(
    payload: InternalDecisionInput,
    request: Request,
) -> dict[str, Any]:
    """Endpoint lokal (loopback-only) untuk dipanggil tool Hermes AI Agent (RBot)."""
    client_ip = request.client.host if request.client and request.client.host else ""
    if client_ip not in ("127.0.0.1", "::1"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Endpoint internal hanya dapat diakses dari localhost CT 101.",
        )
    try:
        return send_decision(
            action=payload.action,
            short_code=payload.short_code,
            sender_wa=payload.sender_wa,
        )
    except PermissionError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


@app.get("/internal/pending")
def internal_pending_endpoint(
    request: Request,
    sender_wa: Optional[str] = None,
) -> dict[str, Any]:
    """Endpoint lokal (loopback-only) untuk melihat permintaan Guest PENDING aktif."""
    client_ip = request.client.host if request.client and request.client.host else ""
    if client_ip not in ("127.0.0.1", "::1"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Endpoint internal hanya dapat diakses dari localhost CT 101.",
        )
    try:
        return list_pending_guests(include_notified=True, sender_wa=sender_wa)
    except PermissionError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


def _run_cli() -> None:
    parser = argparse.ArgumentParser(description="Hermes GIS Guest Access Bridge & CLI Tool")
    parser.add_argument(
        "--action",
        choices=["SERVE", "APPROVE", "REJECT", "REVOKE", "LIST"],
        default="SERVE",
        help="Mode eksekusi: SERVE (jalankan HTTP server) atau eksekusi aksi keputusan.",
    )
    parser.add_argument("--code", dest="short_code", default=None, help="Kode singkat G-XXXX")
    parser.add_argument("--sender", dest="sender_wa", default=None, help="Nomor WhatsApp pengirim")
    args = parser.parse_args()

    if args.action == "SERVE":
        uvicorn.run(app, host=BRIDGE_HOST, port=BRIDGE_PORT)
        return

    if args.action == "LIST":
        result = list_pending_guests(include_notified=True, sender_wa=args.sender_wa)
    else:
        result = send_decision(
            action=args.action,  # type: ignore[arg-type]
            short_code=args.short_code,
            sender_wa=args.sender_wa,
        )
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    _run_cli()
