#!/usr/bin/env python3
"""Reject deprecated Chronicle error fields, unsafe elevated payload logs and
log fields whose names are too short to be useful (single/two characters)."""

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
FIELD_ASSIGNMENT = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=")
FIELD_NAME = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)")

# These established identifiers are clearer than a longer expansion in their
# logging contexts. Every other log field name must be at least three
# characters long.
SHORT_FIELD_EXCEPTIONS = {"id", "ip"}


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


def short_positional_fields(block: str):
    """Field names that chronicles derives from bare (positional) selectors,
    e.g. the ``s`` in ``trace "...", s``.

    Bare selectors have no ``name = value`` pair, so they are invisible to the
    FIELD_ASSIGNMENT check above and need dedicated handling. We take the text
    after the quoted event message, keep only selectors that sit at the top
    nesting level and treat the plain identifiers (no ``=``) as field names.
    """
    # A single chronicles statement may wrap over several lines.
    text = re.sub(r"\s#.*$", "", block)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s*,\s*", ",", text)
    # Drop the leading log level and the quoted event message.
    body = re.sub(
        r"^\s*(?:trace|debug|info|notice|warn|error|fatal)\s+\"(?:\\.|[^\"])*\"",
        "",
        text,
        count=1,
    )

    names = []
    depth = 0
    in_str = False
    i = 0
    start = -1
    while i < len(body):
        ch = body[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            i += 1
            continue
        if ch in "([{":
            depth += 1
            start = -1
            i += 1
            continue
        if ch in ")]}":
            depth -= 1
            start = -1
            i += 1
            continue
        if ch == ",":
            if depth == 0 and start >= 0:
                names.append(body[start:i])
            start = -1
            i += 1
            continue
        if depth == 0:
            if start < 0:
                start = i
        i += 1
    if depth == 0 and start >= 0:
        names.append(body[start:])

    for selector in names:
        if "=" in selector:
            # `name = value` selectors are handled by FIELD_ASSIGNMENT above.
            continue
        name = selector.strip()
        if FIELD_NAME.fullmatch(name) and len(name) < 3:
            yield name


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
            # Structured `name = value` fields ...
            for field_name in FIELD_ASSIGNMENT.findall(block):
                if len(field_name) < 3 and field_name not in SHORT_FIELD_EXCEPTIONS:
                    violations.append(
                        f"{path.relative_to(ROOT)}:{line}: field '{field_name}' is too short (needs to be at least 3 characters long)"
                    )
            # ... and chronicles fields passed as bare/positional selectors.
            for field_name in short_positional_fields(block):
                if field_name not in SHORT_FIELD_EXCEPTIONS:
                    violations.append(
                        f"{path.relative_to(ROOT)}:{line}: bare field '{field_name}' is too short (needs to be at least 3 characters long)"
                    )
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
