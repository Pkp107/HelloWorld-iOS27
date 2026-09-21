#!/usr/bin/env python3
"""Small private IPA host for Workspace's HTTPS install handoff.

The process is intentionally separate from any other service on the Pi. A
Cloudflare tunnel can expose this listener without changing the existing
project's tunnel or port.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import secrets
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, urlparse


HOST = os.environ.get("WORKSPACE_HOST", "127.0.0.1")
PORT = int(os.environ.get("WORKSPACE_PORT", "8072"))
PUBLIC_BASE_URL = os.environ.get("WORKSPACE_PUBLIC_BASE_URL", "").rstrip("/")
TOKEN = os.environ.get("WORKSPACE_UPLOAD_TOKEN", "")
ROOT = Path(os.environ.get("WORKSPACE_STORAGE", str(Path.home() / "WorkspaceFiles")))
UPLOADS = ROOT / "Signed"
UPLOADS.mkdir(parents=True, exist_ok=True)


def safe_name(value: str) -> str:
    value = Path(value or "Workspace-signed.ipa").name
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")
    if not value.lower().endswith(".ipa"):
        value += ".ipa"
    return value or "Workspace-signed.ipa"


def safe_stem(value: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", Path(value or "Workspace-signed").name).strip(".-")
    return stem or "Workspace-signed"


def public_url(path: str) -> str:
    if not PUBLIC_BASE_URL:
        raise RuntimeError("WORKSPACE_PUBLIC_BASE_URL is not configured")
    return f"{PUBLIC_BASE_URL}/{quote(path.lstrip('/'))}"


class WorkspaceHandler(BaseHTTPRequestHandler):
    server_version = "WorkspacePi/1.0"

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} - {format % args}", flush=True)

    def send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status: int, value: dict) -> None:
        self.send_bytes(status, "application/json; charset=utf-8", json.dumps(value).encode())

    def authorized(self) -> bool:
        expected = f"Bearer {TOKEN}" if TOKEN else ""
        return bool(TOKEN) and secrets.compare_digest(self.headers.get("Authorization", ""), expected)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            self.send_json(HTTPStatus.OK, {"service": "workspace", "status": "ok"})
            return
        if path.startswith("/signed/"):
            filename = safe_name(path.removeprefix("/signed/"))
            file_path = UPLOADS / filename
            if not file_path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(file_path.stat().st_size))
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.end_headers()
            with file_path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    self.wfile.write(chunk)
            return
        if path.startswith("/manifests/") and path.endswith(".plist"):
            filename = safe_stem(path.removeprefix("/manifests/").removesuffix(".plist"))
            manifest_path = ROOT / "Manifests" / f"{filename}.plist"
            if not manifest_path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            self.send_bytes(HTTPStatus.OK, "application/xml", manifest_path.read_bytes())
            return
        body = b"Workspace IPA host is running."
        self.send_bytes(HTTPStatus.OK, "text/plain; charset=utf-8", body)

    def do_PUT(self) -> None:
        if urlparse(self.path).path != "/api/upload":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not self.authorized():
            self.send_error(HTTPStatus.UNAUTHORIZED)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2 * 1024 * 1024 * 1024:
                raise ValueError("invalid Content-Length")
            filename = safe_name(self.headers.get("X-Workspace-File-Name", "Workspace-signed.ipa"))
            if not filename.lower().endswith(".ipa"):
                raise ValueError("only IPA files are accepted")
            bundle_id = self.headers.get("X-Workspace-Bundle-ID", "com.pkp107.workspace.signed")
            version = self.headers.get("X-Workspace-Version", "1.0")
            display_name = self.headers.get("X-Workspace-Display-Name", filename.removesuffix(".ipa"))
            UPLOADS.mkdir(parents=True, exist_ok=True)
            manifests = ROOT / "Manifests"
            manifests.mkdir(parents=True, exist_ok=True)
            target = UPLOADS / filename
            with tempfile.NamedTemporaryFile(dir=UPLOADS, delete=False) as temporary:
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("request ended before Content-Length")
                    temporary.write(chunk)
                    remaining -= len(chunk)
                temporary_path = Path(temporary.name)
            temporary_path.replace(target)

            ipa_url = public_url(f"signed/{filename}")
            manifest_name = safe_stem(filename.removesuffix(".ipa"))
            manifest_path = manifests / f"{manifest_name}.plist"
            manifest = {
                "items": [{
                    "assets": [{"kind": "software-package", "url": ipa_url}],
                    "metadata": {
                        "bundle-identifier": bundle_id,
                        "bundle-version": version,
                        "kind": "software",
                        "title": display_name,
                    },
                }]
            }
            manifest_path.write_bytes(plistlib.dumps(manifest, fmt=plistlib.FMT_XML, sort_keys=False))
            manifest_url = public_url(f"manifests/{manifest_name}.plist")
            self.send_json(HTTPStatus.OK, {
                "ipaURL": ipa_url,
                "manifestURL": manifest_url,
                "otaURL": f"itms-services://?action=download-manifest&url={quote(manifest_url, safe='')}" ,
            })
        except Exception as error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})


if __name__ == "__main__":
    if not PUBLIC_BASE_URL:
        raise SystemExit("WORKSPACE_PUBLIC_BASE_URL is required")
    if not TOKEN:
        raise SystemExit("WORKSPACE_UPLOAD_TOKEN is required")
    print(f"Workspace Pi host listening on {HOST}:{PORT}; storage={ROOT}; public={PUBLIC_BASE_URL}", flush=True)
    ThreadingHTTPServer((HOST, PORT), WorkspaceHandler).serve_forever()
