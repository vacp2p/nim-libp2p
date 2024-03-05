import re
from itertools import groupby

requires_pattern = r"(?P<requires>requires *)(?P<dependencies>(?P<dependecy>(?P<specification>\".*\")(?P<separators>,? *\n? *))*)"
file_path: str = "libp2p.nimble"


def get_dependencies_group(path: str) -> str:
    with open(path, "r") as file:
        match = re.search(requires_pattern, file.read())
        return match.group("dependencies")


def parse_group(_group: str) -> list[str]:
    return _group.replace(" ", "").replace("\n", "").split(",")


def clean_dependency(_dependency: str) -> str:
    return _dependency.replace("\"", "")


# Nimble symbols: <, <=, >, >=, ==, ~=, ^=, #
eq_symbols = ("#", "==")
def contains_eq_symbol(_dependency: str) -> bool:
    return any((eq_symbol in _dependency for eq_symbol in eq_symbols))


def classify_dependency(_dependency: str) -> str:
    if contains_eq_symbol(_dependency):
        return "eq"
    elif ">" in _dependency:
        return "gt"
    else:
        return ""


def classify_dependencies(_dependencies: list[str]) -> dict[str, list[str]]:
    d = {
        "eq": [],
        "gt": [],
        "": [],
    }
    for _dependency in _dependencies:
        d[classify_dependency(_dependency)].append(_dependency)
    return d


def parse_versions(_classified_dependencies: dict[str, list[str]]):
    eq, gt, nothing = _classified_dependencies["eq"], _classified_dependencies["gt"], _classified_dependencies[""]
    eq = [re.sub(r"#", "", eq_) for eq_ in eq]
    print(eq)


dependencies_group: str = get_dependencies_group(file_path)
dependencies: list[str] = [clean_dependency(dependency) for dependency in parse_group(dependencies_group)]
classified_dependencies: dict[str, list[str]] = classify_dependencies(dependencies)
asd = parse_versions(classified_dependencies)  # No classifier needed, just replace >= with ==, and remove second part if there is

print(asd)
