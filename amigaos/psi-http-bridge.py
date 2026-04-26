#!/usr/bin/env python3
"""Host-side HTTP bridge for psi-amigaos under vamos.

The m68k binary writes files named req-*.{url,headers,request,ready}
into a shared directory. This helper performs the HTTPS POST on the
host and writes req-*.body plus req-*.status for the Amiga process to
poll. It intentionally uses only Python's stdlib.
"""

from __future__ import annotations

import argparse
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def read_headers(path: Path) -> dict[str, str]:
    headers: dict[str, str] = {}
    if not path.exists():
        return headers
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip()] = value.strip()
    if headers.get("x-api-key") == "bridge":
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if api_key:
            headers["x-api-key"] = api_key
            print(
                f"psi-amiga-http-bridge: substituted bridge API key (len={len(api_key)})",
                file=sys.stderr,
            )
        else:
            print("psi-amiga-http-bridge: ANTHROPIC_API_KEY is not set", file=sys.stderr)
    return headers


def handle(prefix: Path) -> None:
    url = prefix.with_suffix(".url").read_text(encoding="utf-8").strip()
    body = prefix.with_suffix(".request").read_bytes()
    headers = read_headers(prefix.with_suffix(".headers"))
    body_path = prefix.with_suffix(".body")
    status_path = prefix.with_suffix(".status")
    tmp_body = prefix.with_suffix(".body.tmp")

    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    status = -1
    try:
        print(f"psi-amiga-http-bridge: POST {url}", file=sys.stderr)
        with urllib.request.urlopen(req, context=ssl.create_default_context()) as resp:
            status = int(resp.status)
            with tmp_body.open("wb") as out:
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    out.write(chunk)
                    out.flush()
        tmp_body.replace(body_path)
    except urllib.error.HTTPError as exc:
        status = int(exc.code)
        tmp_body.write_bytes(exc.read())
        tmp_body.replace(body_path)
    except Exception as exc:
        status = -1
        tmp_body.write_text(str(exc), encoding="utf-8")
        tmp_body.replace(body_path)
    status_path.write_text(f"{status}\n", encoding="ascii")
    print(f"psi-amiga-http-bridge: status {status}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bridge_dir")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    bridge = Path(args.bridge_dir)
    bridge.mkdir(parents=True, exist_ok=True)
    while True:
        ready_files = sorted(bridge.glob("req-*.ready"))
        did_work = False
        for ready in ready_files:
            prefix = ready.with_suffix("")
            status = prefix.with_suffix(".status")
            if status.exists():
                state = status.read_text(encoding="ascii", errors="replace").strip()
                if state and state != "0":
                    continue
            did_work = True
            handle(prefix)
        if args.once and (did_work or ready_files):
            return 0
        time.sleep(0.05)


if __name__ == "__main__":
    raise SystemExit(main())
