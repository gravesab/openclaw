#!/usr/bin/env python3
"""Generate QR code PNG labels for PropertyManager assets.

Usage:
  python3 tools/property_manager/generate_asset_qr.py --api http://127.0.0.1:5062 --out /tmp/asset-qr
  python3 tools/property_manager/generate_asset_qr.py --dashboard-base http://<dashboard-host>:5000

--dashboard-base is required: it is printed into physical labels, so the
operator must choose the DEV or PROD dashboard explicitly.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path


def auth_headers() -> dict[str, str]:
    """PropertyManager reads require the API key or operator PIN."""
    api_key = os.environ.get("PROPERTYMANAGER_API_KEY", "").strip()
    pin = os.environ.get("PROPERTYMANAGER_OPERATOR_PIN", "").strip()
    if api_key:
        return {"Authorization": f"Bearer {api_key}"}
    if pin:
        return {"X-Operator-PIN": pin}
    raise SystemExit("Set PROPERTYMANAGER_API_KEY or PROPERTYMANAGER_OPERATOR_PIN to read assets.")


def fetch_assets(api_base: str) -> list[dict]:
    url = api_base.rstrip("/") + "/v1/assets"
    request = urllib.request.Request(url, headers=auth_headers(), method="GET")
    with urllib.request.urlopen(request, timeout=30) as resp:
        payload = json.loads(resp.read().decode())
    if not isinstance(payload, list):
        raise RuntimeError("Expected list from /v1/assets")
    return payload


def qr_png(url: str, out_path: Path) -> None:
    try:
        import qrcode
    except ImportError:
        raise SystemExit("Install qrcode: pip install qrcode[pil]")

    img = qrcode.make(url)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api", default="http://127.0.0.1:5062", help="PropertyManager API base URL")
    parser.add_argument(
        "--dashboard-base",
        required=True,
        help="Dashboard base URL encoded in QR codes (required; no default target)",
    )
    parser.add_argument("--out", type=Path, default=Path("reports/asset-qr"), help="Output directory")
    parser.add_argument("--meter-only", action="store_true", help="Skip assets with meter_type=none")
    args = parser.parse_args()

    assets = fetch_assets(args.api)
    generated = 0
    for asset in assets:
        meter = asset.get("meter") or {}
        meter_type = meter.get("meter_type") or "none"
        if args.meter_only and meter_type == "none":
            continue
        qr_token = asset.get("qr_token")
        if not qr_token:
            continue
        name = str(asset.get("name") or asset.get("external_id") or "asset")
        slug = "".join(c if c.isalnum() else "-" for c in name).strip("-")[:40] or "asset"
        page_url = args.dashboard_base.rstrip("/") + f"/pm/asset/{qr_token}"
        out_file = args.out / f"{slug}-{qr_token[:8]}.png"
        qr_png(page_url, out_file)
        print(f"{name}: {page_url} -> {out_file}")
        generated += 1

    print(f"Generated {generated} QR label(s) in {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
