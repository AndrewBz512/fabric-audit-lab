#!/usr/bin/env python3
"""Scrub cleartext secrets from backup/sidecar files.

Motivated by the July 3 `.bak` incident: editor and tool backup files (`*.bak`
and siblings) captured cleartext credentials that were never meant to persist.
This tool finds those files, detects likely secrets inside them, and — by
default — only *reports*. Mutation (quarantine or delete) is opt-in.

Design invariants
-----------------
1. **Dry-run by default.** No file is moved or deleted unless the operator
   passes an explicit mutation flag. Discovery is always safe to run.
2. **Never print the secret.** Findings show the file, line, and a redacted
   fingerprint (matched pattern + a short prefix), never the full value.
3. **Self-checkable.** `--self-check` runs the detectors against an in-memory
   known-clean and known-dirty corpus and asserts the expected verdicts, so the
   detector logic can be tested without touching the filesystem (Playwright or
   CI can drive this mode against a fixed expectation).

Exit codes
----------
0  clean (no secrets found, or self-check passed)
1  secrets found (report mode) / mutation completed with findings
2  usage or runtime error
3  self-check FAILED
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# Backup / sidecar suffixes that should never contain live secrets.
BACKUP_SUFFIXES = (".bak", ".old", ".orig", ".save", ".swp", ".tmp", "~")
BACKUP_GLOB_HINTS = ("*.bak", "*.old", "*.orig", "*.save", "*.tmp", "*~")

# Secret detectors. Each is (name, compiled regex). Patterns are intentionally
# conservative: they target credential *shapes* with enough entropy/prefix to
# avoid matching ordinary prose. False negatives are safer than a tool that
# cries wolf and gets ignored.
_DETECTORS: tuple[tuple[str, "re.Pattern[str]"], ...] = (
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai-key", re.compile(r"sk-(?!ant-)[A-Za-z0-9]{20,}")),
    ("openrouter-key", re.compile(r"sk-or-v1-[A-Za-z0-9]{20,}")),
    ("aws-access-key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("slack-token", re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")),
    ("private-key-block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    # Generic assignment: KEY/TOKEN/SECRET/PASSWORD = <longish non-space value>.
    (
        "generic-secret-assignment",
        re.compile(
            r"(?i)\b(?:api[_-]?key|secret|token|passwd|password|access[_-]?key)\b"
            r"\s*[:=]\s*['\"]?([^\s'\"]{12,})"
        ),
    ),
)


@dataclass(frozen=True)
class Finding:
    path: Path
    line_no: int
    detector: str
    fingerprint: str  # redacted


def _redact(match_text: str) -> str:
    """Return a non-reversible fingerprint: first 4 chars + length, rest masked."""
    match_text = match_text.strip().strip("'\"")
    if len(match_text) <= 4:
        return "*" * len(match_text)
    return f"{match_text[:4]}…(+{len(match_text) - 4} chars)"


def scan_text(text: str) -> list[tuple[int, str, str]]:
    """Scan text; return (line_no, detector_name, redacted_fingerprint) tuples."""
    hits: list[tuple[int, str, str]] = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        for name, pattern in _DETECTORS:
            m = pattern.search(line)
            if m:
                # Prefer a captured group (the value) when present.
                raw = m.group(1) if m.groups() else m.group(0)
                hits.append((line_no, name, _redact(raw)))
    return hits


def is_backup_file(path: Path) -> bool:
    name = path.name
    return name.endswith(BACKUP_SUFFIXES)


def iter_backup_files(root: Path) -> "list[Path]":
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip VCS internals; they are not our concern and are noisy.
        dirnames[:] = [d for d in dirnames if d not in {".git", "__pycache__"}]
        for fn in filenames:
            p = Path(dirpath) / fn
            if is_backup_file(p):
                found.append(p)
    return found


def scan_file(path: Path) -> list[Finding]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except (OSError, UnicodeError):
        return []
    return [
        Finding(path=path, line_no=ln, detector=name, fingerprint=fp)
        for ln, name, fp in scan_text(text)
    ]


# --------------------------------------------------------------------------- #
# Self-check corpus — drives --self-check without touching the filesystem.
# --------------------------------------------------------------------------- #

_KNOWN_CLEAN = [
    "just some ordinary prose about tokens of appreciation",
    "hostname = spine1  # no secret here",
    "the password field label reads 'Password'",
    "sk- is a common prefix but this is too short",
    "ecmp_paths: 4",
]

_KNOWN_DIRTY = [
    "OPENROUTER_API_KEY=sk-or-v1-abcdef0123456789abcdef0123456789",
    "authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dOxxxxxxxxxxxxx",
    "aws_key = AKIAIOSFODNN7EXAMPLE",
    "password: hunter2isnotlongenoughbutthisis123",
    "-----BEGIN OPENSSH PRIVATE KEY-----",
]


def run_self_check() -> int:
    failures: list[str] = []

    for sample in _KNOWN_CLEAN:
        hits = scan_text(sample)
        if hits:
            failures.append(f"FALSE POSITIVE on clean sample: {sample!r} -> {hits}")

    for sample in _KNOWN_DIRTY:
        hits = scan_text(sample)
        if not hits:
            failures.append(f"FALSE NEGATIVE on dirty sample: {sample!r}")

    if failures:
        print("self-check FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 3

    print(
        f"self-check PASSED: {len(_KNOWN_CLEAN)} clean + {len(_KNOWN_DIRTY)} dirty "
        f"samples classified correctly."
    )
    return 0


# --------------------------------------------------------------------------- #
# Mutation
# --------------------------------------------------------------------------- #

def quarantine(path: Path, quarantine_dir: Path) -> Path:
    quarantine_dir.mkdir(parents=True, exist_ok=True)
    # Flatten the relative path into the filename to avoid collisions.
    safe_name = str(path).lstrip("/").replace(os.sep, "__")
    dest = quarantine_dir / safe_name
    path.rename(dest)
    return dest


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("root", nargs="?", default=".", help="Directory to scan (default: .)")
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="Run detectors against the built-in corpus and exit (no filesystem access).",
    )
    mut = parser.add_mutually_exclusive_group()
    mut.add_argument(
        "--quarantine",
        metavar="DIR",
        help="Move backup files that contain secrets into DIR (opt-in mutation).",
    )
    mut.add_argument(
        "--delete",
        action="store_true",
        help="Delete backup files that contain secrets (opt-in, irreversible).",
    )
    args = parser.parse_args(argv)

    if args.self_check:
        return run_self_check()

    root = Path(args.root)
    if not root.exists():
        print(f"error: root not found: {root}", file=sys.stderr)
        return 2

    backup_files = iter_backup_files(root)
    all_findings: list[Finding] = []
    dirty_files: set[Path] = set()

    for bf in backup_files:
        findings = scan_file(bf)
        if findings:
            all_findings.extend(findings)
            dirty_files.add(bf)

    # Report.
    if not all_findings:
        print(
            f"clean: scanned {len(backup_files)} backup file(s) under {root}, "
            f"no cleartext secrets detected."
        )
        return 0

    print(f"SECRETS FOUND in {len(dirty_files)} backup file(s):")
    for f in sorted(all_findings, key=lambda x: (str(x.path), x.line_no)):
        print(f"  {f.path}:{f.line_no}  [{f.detector}]  {f.fingerprint}")

    # Mutate only if explicitly asked.
    if args.quarantine:
        qdir = Path(args.quarantine)
        for df in sorted(dirty_files):
            dest = quarantine(df, qdir)
            print(f"quarantined: {df} -> {dest}")
    elif args.delete:
        for df in sorted(dirty_files):
            df.unlink()
            print(f"deleted: {df}")
    else:
        print("\n(report only — pass --quarantine DIR or --delete to act)")

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
