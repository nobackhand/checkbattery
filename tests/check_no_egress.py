#!/usr/bin/env python3
"""
Privacy-promise guard for BatteryPill.

BatteryPill makes a hard privacy claim: it does no network I/O. This test
asserts that promise can't silently regress. It scans the PowerShell sources
for network-egress APIs and FAILs if any appear.

Scanned files:
  * BatteryWidget.ps1
  * CheckBattery.ps1

Flagged (programmatic egress):
  Invoke-WebRequest, Invoke-RestMethod, New-Object Net.WebClient,
  System.Net.WebClient, System.Net.Http(.*), System.Net.Sockets(.*),
  Resolve-DnsName, Test-Connection, Start-BitsTransfer.

Explicitly ALLOWED (not egress):
  Start-Process <url>  — user-initiated link opens in click handlers
                         (e.g. "open batterypill.com" / "buy me a coffee").
                         This launches the default browser; it is not the
                         widget phoning home, so it must NOT trip the check.

Comment lines (after stripping a leading '#') are ignored so that docs /
disclaimers mentioning these APIs don't cause false failures.

Exit non-zero if any egress API is found.
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = ["BatteryWidget.ps1", "CheckBattery.ps1"]

# Each pattern is (label, compiled regex). Patterns are matched case-insensitively
# against code with comments stripped.
EGRESS_PATTERNS = [
    ("Invoke-WebRequest", re.compile(r'\bInvoke-WebRequest\b', re.I)),
    ("Invoke-RestMethod", re.compile(r'\bInvoke-RestMethod\b', re.I)),
    # Net.WebClient / System.Net.WebClient (with or without System. prefix)
    ("Net.WebClient", re.compile(r'\b(?:System\.)?Net\.WebClient\b', re.I)),
    ("System.Net.Http", re.compile(r'\bSystem\.Net\.Http\b', re.I)),
    ("System.Net.Sockets", re.compile(r'\bSystem\.Net\.Sockets\b', re.I)),
    # Bare Net.Http / Net.Sockets type references
    ("Net.Http", re.compile(r'\bNet\.Http(?:Client|WebRequest)?\b', re.I)),
    ("Net.Sockets", re.compile(r'\bNet\.Sockets\b', re.I)),
    ("Resolve-DnsName", re.compile(r'\bResolve-DnsName\b', re.I)),
    ("Test-Connection", re.compile(r'\bTest-Connection\b', re.I)),
    ("Start-BitsTransfer", re.compile(r'\bStart-BitsTransfer\b', re.I)),
    # Generic downloaders that take URLs
    ("WebClient.DownloadString/File",
     re.compile(r'\.Download(?:String|File|Data)\b', re.I)),
]


def strip_comment(line):
    """Remove a PowerShell line comment, but be careful not to strip a '#'
    inside a quoted string. PowerShell uses '#' for comments; here we do a
    light-touch strip: find the first '#' that is not inside single/double
    quotes."""
    out = []
    in_single = False
    in_double = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "'" and not in_double:
            in_single = not in_single
        elif c == '"' and not in_single:
            in_double = not in_double
        elif c == "#" and not in_single and not in_double:
            break  # rest of line is a comment
        out.append(c)
        i += 1
    return "".join(out)


def scan_file(path):
    """Return list of (lineno, label, raw_line) for egress matches."""
    findings = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, start=1):
            code = strip_comment(raw)
            if not code.strip():
                continue
            for label, rx in EGRESS_PATTERNS:
                if rx.search(code):
                    findings.append((lineno, label, raw.rstrip("\n")))
    return findings


def main():
    print("=" * 64)
    print("no-network-egress guard (privacy promise)")
    print("=" * 64)

    any_fail = False
    missing = []
    for name in TARGETS:
        path = os.path.join(REPO_ROOT, name)
        if not os.path.isfile(path):
            missing.append(name)
            print(f"[WARN] {name}: not found, skipping")
            continue
        findings = scan_file(path)
        if findings:
            any_fail = True
            print(f"[FAIL] {name}: {len(findings)} egress API reference(s):")
            for lineno, label, raw in findings:
                print(f"        L{lineno} <{label}>: {raw.strip()}")
        else:
            print(f"[PASS] {name}: no programmatic network egress")

    print("-" * 64)
    print("note: user-initiated 'Start-Process <url>' in click handlers is")
    print("      allowed and intentionally NOT flagged.")
    print("-" * 64)

    if missing:
        # A missing target file is a real problem for a guard test — if the
        # file was renamed, the guard would silently stop protecting it.
        print(f"RESULT: FAIL — target file(s) missing: {', '.join(missing)}")
        print("=" * 64)
        return 1

    if any_fail:
        print("RESULT: FAIL — network egress API detected")
        print("=" * 64)
        return 1

    print("RESULT: PASS — privacy promise intact (no egress APIs)")
    print("=" * 64)
    return 0


if __name__ == "__main__":
    sys.exit(main())
