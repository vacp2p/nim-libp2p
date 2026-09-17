#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


OPERATORS = {
    "==": lambda comparison: comparison == 0,
    ">=": lambda comparison: comparison >= 0,
    "<=": lambda comparison: comparison <= 0,
    ">": lambda comparison: comparison > 0,
    "<": lambda comparison: comparison < 0,
}


def parse_version(value):
    if not re.fullmatch(r"\d+(?:\.\d+)*", value):
        raise ValueError(f"unsupported version {value!r}")
    return tuple(int(part) for part in value.split("."))


def compare_versions(left, right):
    length = max(len(left), len(right))
    left += (0,) * (length - len(left))
    right += (0,) * (length - len(right))
    return (left > right) - (left < right)


def package_name(requirement):
    name = re.split(r"\s+(?:==|>=|<=|>|<)\s+", requirement, maxsplit=1)[0]
    if name.startswith(("https://", "http://")):
        name = Path(urlparse(name).path).name.removesuffix(".git")
        name = name.removeprefix("nim-")
    return name


def read_requirements(path):
    lines = path.read_text().splitlines()
    requirements = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not re.match(r"^\s*requires(?:\s|$)", line):
            index += 1
            continue

        statement = line
        while statement.rstrip().endswith(","):
            index += 1
            if index >= len(lines):
                raise ValueError("unterminated requires statement")
            statement += "\n" + lines[index]
        requirements.extend(re.findall(r'"([^"\n]+)"', statement))
        index += 1
    return requirements


def satisfies(version, requirement):
    constraint_start = re.search(r"==|>=|<=|>|<", requirement)
    if constraint_start is None:
        return True

    constraints = []
    for constraint in requirement[constraint_start.start() :].split("&"):
        match = re.fullmatch(r"\s*(==|>=|<=|>|<)\s*(\d+(?:\.\d+)*)\s*", constraint)
        if match is None:
            raise ValueError(f"unsupported constraint {constraint!r}")
        constraints.append(match.groups())

    parsed = parse_version(version)
    return all(
        OPERATORS[operator](compare_versions(parsed, parse_version(required)))
        for operator, required in constraints
    )


def main():
    nimble_path = Path(sys.argv[1] if len(sys.argv) > 1 else "libp2p.nimble")
    lock_path = Path(sys.argv[2] if len(sys.argv) > 2 else "nix/libp2p.lock")
    packages = json.loads(lock_path.read_text())["packages"]
    errors = []

    for requirement in read_requirements(nimble_path):
        name = package_name(requirement)
        if name not in packages:
            errors.append(f"{name}: missing from {lock_path}")
            continue

        version = packages[name].get("version", "")
        try:
            matches = satisfies(version, requirement)
        except ValueError as error:
            errors.append(f"{name}: {error}")
            continue
        if not matches:
            errors.append(f"{name}: locked at {version}, requires {requirement}")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"All direct requirements in {nimble_path} are satisfied by {lock_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
