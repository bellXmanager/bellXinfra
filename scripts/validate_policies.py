#!/usr/bin/env python3
"""Validate IAM policy JSON files under bellXinfra/scripts/policies/. Run before provision-bellx-sa-east-1.ps1."""

from __future__ import annotations

import json
import sys
from pathlib import Path

POLICY_DIR = Path(__file__).resolve().parent / "policies"
REQUIRED = ("ecs-task-trust.json", "backend-secrets-read.json")


def main() -> int:
    missing = [n for n in REQUIRED if not (POLICY_DIR / n).is_file()]
    if missing:
        print("Missing files:", ", ".join(missing), file=sys.stderr)
        return 1
    for name in REQUIRED:
        path = POLICY_DIR / name
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"Invalid JSON {path}: {e}", file=sys.stderr)
            return 1
        if not isinstance(data, dict) or "Statement" not in data:
            print(f"Expected object with Statement: {path}", file=sys.stderr)
            return 1
    print("OK:", ", ".join(REQUIRED))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
