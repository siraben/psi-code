#!/usr/bin/env python3
import csv
import os
import re
import subprocess
import sys
from pathlib import Path


VULN_CSV_HEADER = [
    "vuln_id",
    "url",
    "package",
    "version_local",
    "severity",
    "grype",
    "osv",
    "vulnix",
    "sum",
    "sortcol",
    "whitelist",
    "whitelist_comment",
]


def env_flag(name, default):
    value = os.environ.get(name, default)
    return value != "0"


def target_name(target):
    if target.startswith(".#"):
        attr = target[2:]
        if attr.startswith("psi-"):
            return attr
        return f"psi-{attr}"

    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", target).strip("_")
    return name or "target"


def run(args):
    subprocess.run(args, check=True)


def section(message):
    print(message, flush=True)


def ensure_vuln_csv(path):
    if path.exists():
        return
    with path.open("w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(VULN_CSV_HEADER)


def vulnscan(target, output, whitelist_args, extra_args=None):
    output.unlink(missing_ok=True)
    run(["vulnxscan", target, "-o", str(output), *(extra_args or []), *whitelist_args])
    ensure_vuln_csv(output)


def gate_runtime_findings(path, threshold):
    bad = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("whitelist", "").strip().lower() == "true":
                continue
            severity = row.get("severity", "").strip()
            if not severity:
                continue
            try:
                score = float(severity)
            except ValueError:
                continue
            if score >= threshold:
                bad.append((row.get("vuln_id", ""), row.get("package", ""), severity))

    if bad:
        print(
            f"runtime vulnerability threshold failed: "
            f"{len(bad)} unwhitelisted findings >= {threshold:g}"
        )
        for vuln_id, package, severity in bad:
            print(f"  {vuln_id} {package} severity={severity}")
        return 1

    print(f"runtime vulnerability threshold passed: no unwhitelisted findings >= {threshold:g}")
    return 0


def main(argv):
    target = argv[1] if len(argv) > 1 else ".#default"
    out_dir = Path(argv[2] if len(argv) > 2 else "sbom")
    fail_on = float(os.environ.get("PSI_SBOM_FAIL_ON", "7"))
    run_triage = env_flag("PSI_SBOM_TRIAGE", "1")
    run_buildtime = env_flag("PSI_SBOM_BUILDTIME", "0")
    whitelist = Path(os.environ.get("PSI_SBOM_WHITELIST", "sbom/vulnxscan.whitelist.csv"))

    out_dir.mkdir(parents=True, exist_ok=True)
    prefix = out_dir / target_name(target)
    whitelist_args = ["--whitelist", str(whitelist)] if whitelist.is_file() else []

    section(f"== runtime SBOM: {target} ==")
    run([
        "sbomnix",
        target,
        "--cdx",
        f"{prefix}-runtime.cdx.json",
        "--spdx",
        f"{prefix}-runtime.spdx.json",
        "--csv",
        f"{prefix}-runtime.csv",
        "--include-vulns",
    ])

    section(f"== runtime SBOM without heuristic CPE matching: {target} ==")
    run([
        "sbomnix",
        target,
        "--cdx",
        f"{prefix}-runtime-no-cpe-heuristics.cdx.json",
        "--spdx",
        f"{prefix}-runtime-no-cpe-heuristics.spdx.json",
        "--csv",
        f"{prefix}-runtime-no-cpe-heuristics.csv",
        "--exclude-cpe-matching",
        "--include-vulns",
    ])

    section(f"== runtime vulnerability scan: {target} ==")
    runtime_vulns = Path(f"{prefix}-runtime-vulns.csv")
    vulnscan(target, runtime_vulns, whitelist_args)

    if run_triage:
        section(f"== runtime vulnerability triage: {target} ==")
        triage_base = Path(f"{prefix}-runtime-vulns-triage-base.csv")
        Path(f"{prefix}-runtime-vulns-triage-base.triage.csv").unlink(missing_ok=True)
        vulnscan(target, triage_base, whitelist_args, ["--triage"])

    if run_buildtime:
        section(f"== build-time SBOM: {target} ==")
        run([
            "sbomnix",
            target,
            "--buildtime",
            "--cdx",
            f"{prefix}-buildtime.cdx.json",
            "--spdx",
            f"{prefix}-buildtime.spdx.json",
            "--csv",
            f"{prefix}-buildtime.csv",
            "--include-vulns",
        ])

        section(f"== build-time vulnerability scan: {target} ==")
        buildtime_vulns = Path(f"{prefix}-buildtime-vulns.csv")
        vulnscan(target, buildtime_vulns, whitelist_args, ["--buildtime"])

    return gate_runtime_findings(runtime_vulns, fail_on)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
