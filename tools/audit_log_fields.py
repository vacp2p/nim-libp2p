#!/usr/bin/env python3
"""Reject unsafe Chronicle log fields and unhelpfully short field names."""

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
UNBOUNDED_FIELD = re.compile(
    r"\b(?:data|buffer|payload|encoded|certificate|ticket|signature|"
    r"advertisement|msg|message|request|response|record|addresses|addrs)\s*="
    r"\s*([^,\n]+)"
)
FIELD_ASSIGNMENT = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=")
FIELD_NAME = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)")
SHORTLOG_TYPE = re.compile(r"^func shortLog\*?\([^:]+:\s*([^)=]+)", re.MULTILINE)
FORMATIT = re.compile(
    r"chronicles\.formatIt\(([^)]+)\):\s*\n\s*(?:shortLog\(it\)|it\.shortLog)"
)
DECLARATION = re.compile(r"\b(?:let|var)\s+(\w+)\s*:\s*([^=\n]+)")
INFERRED_DECLARATION = re.compile(r"\b(?:let|var)\s+(\w+)\s*=\s*(\w+)\.")
PARAMETER = re.compile(r"\b(\w+)\s*:\s*([\w\[\], |]+)")
FIELD_DECLARATION = re.compile(
    r"^\s*(\w+)\*?\s*(?:\{[^}]+\})?\s*:\s*([^=\n]+)", re.MULTILINE
)
RETURN_TYPE = re.compile(r"\b(?:func|proc)\s+(\w+)\*?\([^)]*\)\s*:\s*([^=\n{]+)")

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


def normalized_type(type_name: str) -> str:
    return re.sub(r"\s+", "", type_name).split(",", 1)[0].rstrip("*")


def source_types(paths):
    """Return types with a compact Chronicles formatter and simple declarations.

    This deliberately handles only declarations visible in Nim source. If an
    expression cannot be resolved, the audit keeps requiring explicit
    ``shortLog`` rather than guessing from a field name.
    """
    shortlog_types = set()
    formatter_types = set()
    declarations = {}
    fields = {}
    returns = {}
    for path in paths:
        text = path.read_text()
        shortlog_types.update(normalized_type(t) for t in SHORTLOG_TYPE.findall(text))
        formatter_types.update(normalized_type(t) for t in FORMATIT.findall(text))
        for name, type_name in FIELD_DECLARATION.findall(text):
            fields.setdefault(name, set()).add(normalized_type(type_name))
        for name, type_name in RETURN_TYPE.findall(text):
            returns[name] = normalized_type(type_name)

    for path in paths:
        text = path.read_text()
        values = declarations.setdefault(path, {})
        for name, type_name in PARAMETER.findall(text):
            values.setdefault(name, set()).add(normalized_type(type_name))
        for name, type_name in DECLARATION.findall(text):
            values.setdefault(name, set()).add(normalized_type(type_name))
        for name, constructor in INFERRED_DECLARATION.findall(text):
            values.setdefault(name, set()).add(constructor)
        for name, expression in re.findall(r"\b(?:let|var)\s+(\w+)\s*=\s*([^\n]+)", text):
            for field_name in re.findall(r"\.(\w+)", expression):
                candidates = fields.get(field_name, set())
                if len(candidates) == 1:
                    values.setdefault(name, set()).add(next(iter(candidates)))
            callee = re.match(r"(?:await\s+)?(\w+)\(", expression.strip())
            if callee and callee.group(1) in returns:
                values.setdefault(name, set()).add(returns[callee.group(1)])

    return shortlog_types & formatter_types, declarations, fields


def has_compact_formatter(value: str, declarations, fields) -> bool:
    """Whether a simple log expression resolves to a compact formatter type."""
    value = value.strip()
    if value in declarations:
        if declarations[value] & COMPACT_FORMAT_TYPES:
            return True
    if value in fields:
        return bool(fields[value] & COMPACT_FORMAT_TYPES)
    if "addr" in value.lower():
        return "seq[MultiAddress]" in COMPACT_FORMAT_TYPES
    field_names = re.findall(r"\.(\w+)", value)
    if field_names:
        return any(fields.get(name, set()) & COMPACT_FORMAT_TYPES for name in field_names)
    return False


def main() -> int:
    violations = []
    paths = list(ROOT.joinpath("libp2p").rglob("*.nim"))
    global COMPACT_FORMAT_TYPES
    COMPACT_FORMAT_TYPES, declarations, fields = source_types(paths)
    for path in paths:
        for line, level, block in log_blocks(path):
            if EXCEPTION_ALIAS.search(block):
                violations.append(
                    f"{path.relative_to(ROOT)}:{line}: use err for exception text"
                )
            if level in {"warn", "error"} and PAYLOAD_FIELD.search(block):
                violations.append(
                    f"{path.relative_to(ROOT)}:{line}: elevated log contains payload field"
                )
            # Payloads and collections must be bounded even at trace/debug:
            # peers can otherwise make a single event arbitrarily large. This
            # is intentionally structural; it only checks field names that
            # conventionally carry byte arrays or unbounded protocol objects.
            for value in UNBOUNDED_FIELD.findall(block):
                if (
                    "shortLog" not in value
                    and ".len" not in value
                    and not has_compact_formatter(value, declarations[path], fields)
                ):
                    violations.append(
                        f"{path.relative_to(ROOT)}:{line}: potentially unbounded log field must use shortLog"
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
