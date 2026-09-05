#!/usr/bin/env python3
"""Reject deprecated Chronicle error fields and unsafe elevated payload logs."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LOG_START = re.compile(r"^(\s*)(trace|debug|info|notice|warn|error|fatal)\s+\"")
EXCEPTION_ALIAS = re.compile(
    r"\b(?:description|error|message|msg)\s*=\s*"
    r"(?:getCurrentExceptionMsg\(\)|[A-Za-z_][\w.]*\.msg)"
)
PAYLOAD_FIELD = re.compile(
    r"\b(?:msg|message|buffer|record|reply|response|rpcMsg|data|encoded|"
    r"certificate|ticket|key)\s*="
)


def log_blocks(path: Path):
    lines = path.read_text().splitlines()
    line = 0
    while line < len(lines):
        match = LOG_START.match(lines[line])
        if not match:
            line += 1
            continue
        indent = len(match.group(1).expandtabs(2))
        end = line + 1
        while end < len(lines):
            text = lines[end]
            if not text.strip():
                end += 1
                continue
            if len(text) - len(text.lstrip(" \t")) <= indent:
                break
            end += 1
        yield line + 1, match.group(2), "\n".join(lines[line:end])
        line = end


def main() -> int:
    violations = []
    for path in ROOT.joinpath("libp2p").rglob("*.nim"):
        for line, level, block in log_blocks(path):
            if EXCEPTION_ALIAS.search(block):
                violations.append(
                    f"{path.relative_to(ROOT)}:{line}: use err for exception text"
                )
            if level in {"warn", "error"} and PAYLOAD_FIELD.search(block):
                violations.append(
                    f"{path.relative_to(ROOT)}:{line}: elevated log contains payload field"
                )
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
