#!/usr/bin/env python3
"""Inline `<link rel=stylesheet href=*.css>` and `<script src=*.js>` tags
into a single self-contained HTML file.

The firmware build embeds one HTML blob; the same source page is served
in split form by the host frontend (which keeps chat.css / chat.js as
separate static files). This script bridges the two: the page lives as
a normal HTML file with external references during development, and the
firmware bundles everything down to one document at build time.

Limitations on purpose:
- only resolves relative paths (no http(s) URLs)
- only handles tags that occur on a single line
- does no minification — html-minifier runs after this in the firmware
  derivation
"""
import argparse
import re
import sys
from pathlib import Path


LINK_RE = re.compile(
    r'<link\s+[^>]*?rel\s*=\s*"stylesheet"[^>]*?href\s*=\s*"([^":/?#]+\.css)"[^>]*?>',
    re.IGNORECASE,
)
SCRIPT_RE = re.compile(
    r'<script\s+[^>]*?src\s*=\s*"([^":/?#]+\.js)"[^>]*?>\s*</script>',
    re.IGNORECASE,
)


def inline(html_text: str, base: Path) -> str:
    def css_sub(match: re.Match) -> str:
        path = base / match.group(1)
        body = path.read_text(encoding="utf-8")
        return "<style>\n" + body + "\n</style>"

    def js_sub(match: re.Match) -> str:
        path = base / match.group(1)
        body = path.read_text(encoding="utf-8")
        return "<script>\n" + body + "\n</script>"

    out = LINK_RE.sub(css_sub, html_text)
    out = SCRIPT_RE.sub(js_sub, out)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="source HTML (e.g. assets/web/index.html)")
    ap.add_argument("-o", "--output", required=True, help="bundled HTML path")
    args = ap.parse_args()

    src = Path(args.input)
    html = src.read_text(encoding="utf-8")
    bundled = inline(html, src.parent)
    Path(args.output).write_text(bundled, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
