#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.request


class ReusableHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path != "/anthropic":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            self.send_error(500, "ANTHROPIC_API_KEY is not set")
            return
        headers = {
            "content-type": "application/json",
            "anthropic-version": "2023-06-01",
            "x-api-key": api_key,
        }
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, context=ssl.create_default_context()) as resp:
                data = resp.read()
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            print("psi-reactos-http-proxy: status 200", flush=True)
        except urllib.error.HTTPError as exc:
            data = exc.read()
            self.send_response(exc.code)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            print(f"psi-reactos-http-proxy: status {exc.code}", flush=True)
            if data:
                print(data.decode("utf-8", errors="replace"), flush=True)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    server = ReusableHTTPServer((args.host, args.port), Handler)
    print(f"psi-reactos-http-proxy: listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
