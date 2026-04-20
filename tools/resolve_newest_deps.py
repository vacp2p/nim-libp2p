#!/usr/bin/env python3
"""Resolve newest dependency commits used by downstream nim-libp2p consumers."""

import base64
import configparser
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, List, Optional
from urllib.parse import quote

try:
    import requests
except ImportError:
    print("ERROR: Python package 'requests' is required", file=sys.stderr)
    sys.exit(1)


GITHUB_API = "https://api.github.com"
TIMEOUT = 10

NIMBLE_LOCK_SOURCES = [
    {
        "repo": "logos-messaging/logos-delivery",
        "ref": "master",
        "file": "nimble.lock",
    },
]

SUBMODULE_SOURCES = [
    {"repo": "status-im/nimbus-eth2", "ref": "unstable"},
    {"repo": "codex-storage/nim-codex", "ref": "master"},
]


@dataclass(frozen=True)
class Candidate:
    url: str
    sha: str
    source: str


def log(message: str) -> None:
    print(message, file=sys.stderr)


def get_headers() -> Dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_get(url: str) -> requests.Response:
    response = requests.get(url, headers=get_headers(), timeout=TIMEOUT)
    response.raise_for_status()
    return response


def normalize_url(url: str) -> str:
    """Normalize a GitHub repository URL for cross-source comparisons."""
    normalized = url.strip()
    if normalized.startswith("git+"):
        normalized = normalized[4:]
    if normalized.startswith("git@github.com:"):
        normalized = "https://github.com/" + normalized.split(":", 1)[1]
    elif normalized.startswith("ssh://git@github.com/"):
        normalized = "https://github.com/" + normalized[len("ssh://git@github.com/") :]
    elif normalized.startswith("git://github.com/"):
        normalized = "https://github.com/" + normalized[len("git://github.com/") :]

    normalized = normalized.lower().rstrip("/")
    if normalized.endswith(".git"):
        normalized = normalized[:-4]
    return normalized


def parse_pinned(path: str) -> "OrderedDict[str, Dict[str, str]]":
    deps: "OrderedDict[str, Dict[str, str]]" = OrderedDict()
    with open(path, encoding="utf-8") as pinned:
        for line_number, raw_line in enumerate(pinned, start=1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                name, url_sha = line.split(";", 1)
                url, sha = url_sha.rsplit("@#", 1)
            except ValueError as err:
                raise ValueError(f"{path}:{line_number}: invalid .pinned entry") from err
            deps[normalize_url(url)] = {"name": name, "url": url, "sha": sha}
    return deps


def fetch_github_file(repo: str, ref: str, filepath: str) -> str:
    encoded_path = quote(filepath)
    encoded_ref = quote(ref, safe="")
    url = f"{GITHUB_API}/repos/{repo}/contents/{encoded_path}?ref={encoded_ref}"
    data = github_get(url).json()
    if data.get("encoding") != "base64" or "content" not in data:
        raise ValueError(f"{repo}:{filepath}: unexpected GitHub contents response")
    return base64.b64decode(data["content"]).decode("utf-8")


def fetch_nimble_lock(
    repo: str, ref: str, filepath: str = "nimble.lock"
) -> Dict[str, Candidate]:
    content = fetch_github_file(repo, ref, filepath)
    lock = json.loads(content)
    packages = lock.get("packages", {})
    if not isinstance(packages, dict):
        raise ValueError(f"{repo}:{filepath}: expected packages object")

    deps: Dict[str, Candidate] = {}
    for info in packages.values():
        if not isinstance(info, dict):
            continue
        url = info.get("url", "")
        sha = info.get("vcsRevision", "")
        if url and sha:
            deps[normalize_url(url)] = Candidate(url=url, sha=sha, source=repo)
    return deps


def parse_gitmodules(content: str) -> Dict[str, str]:
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(content)

    modules: Dict[str, str] = {}
    for section in parser.sections():
        path = parser.get(section, "path", fallback="").strip()
        url = parser.get(section, "url", fallback="").strip()
        if path and url:
            modules[path] = url
    return modules


def fetch_submodule_deps(repo: str, ref: str) -> Dict[str, Candidate]:
    gitmodules_content = fetch_github_file(repo, ref, ".gitmodules")
    path_to_url = parse_gitmodules(gitmodules_content)

    encoded_ref = quote(ref, safe="")
    tree_url = f"{GITHUB_API}/repos/{repo}/git/trees/{encoded_ref}?recursive=1"
    tree = github_get(tree_url).json()

    path_to_sha = {}
    for entry in tree.get("tree", []):
        path = entry.get("path", "")
        if entry.get("type") == "commit" and path.startswith("vendor/"):
            path_to_sha[path] = entry.get("sha", "")

    deps: Dict[str, Candidate] = {}
    for path, url in path_to_url.items():
        sha = path_to_sha.get(path)
        if sha:
            deps[normalize_url(url)] = Candidate(url=url, sha=sha, source=repo)
    return deps


def owner_repo_from_url(url: str) -> Optional[str]:
    normalized = normalize_url(url)
    match = re.search(r"github\.com/([^/]+/[^/]+)$", normalized)
    if not match:
        return None
    return match.group(1)


def get_commit_date(owner_repo: str, sha: str) -> datetime:
    encoded_sha = quote(sha, safe="")
    url = f"{GITHUB_API}/repos/{owner_repo}/commits/{encoded_sha}"
    data = github_get(url).json()
    date_str = data["commit"]["committer"]["date"]
    return datetime.fromisoformat(date_str.replace("Z", "+00:00"))


def candidate_label(candidates: Iterable[Candidate]) -> str:
    return ", ".join(candidate.source for candidate in candidates)


def pick_newest(
    candidates_by_sha: "OrderedDict[str, List[Candidate]]", dep_url: str
) -> str:
    owner_repo = owner_repo_from_url(dep_url)
    if not owner_repo:
        sha = next(iter(candidates_by_sha))
        log(
            "  WARNING: could not extract GitHub owner/repo "
            f"from {dep_url}, using {sha[:12]}"
        )
        return sha

    best_sha: Optional[str] = None
    best_date: Optional[datetime] = None

    for sha, candidates in candidates_by_sha.items():
        try:
            date = get_commit_date(owner_repo, sha)
            log(f"  {candidate_label(candidates)}: {sha[:12]} ({date.isoformat()})")
        except Exception as err:
            log(f"  {candidate_label(candidates)}: {sha[:12]} - failed to get date: {err}")
            continue

        if best_date is None or date > best_date:
            best_date = date
            best_sha = sha

    if best_sha:
        return best_sha

    sha = next(iter(candidates_by_sha))
    log(f"  WARNING: all commit date lookups failed, using {sha[:12]}")
    return sha


def add_candidate(
    candidates: Dict[str, "OrderedDict[str, List[Candidate]]"],
    norm_url: str,
    candidate: Candidate,
) -> None:
    sha_map = candidates[norm_url]
    if candidate.sha not in sha_map:
        sha_map[candidate.sha] = []
    sha_map[candidate.sha].append(candidate)


def collect_nimble_lock_source(
    source: Dict[str, str],
    base_deps: "OrderedDict[str, Dict[str, str]]",
    candidates: Dict[str, "OrderedDict[str, List[Candidate]]"],
) -> None:
    log(f"Fetching nimble.lock from {source['repo']}...")
    lock_deps = fetch_nimble_lock(source["repo"], source["ref"], source["file"])
    matched = 0
    for norm_url, candidate in lock_deps.items():
        if norm_url in base_deps:
            add_candidate(candidates, norm_url, candidate)
            matched += 1
    log(f"  Matched {matched} deps")


def collect_submodule_source(
    source: Dict[str, str],
    base_deps: "OrderedDict[str, Dict[str, str]]",
    candidates: Dict[str, "OrderedDict[str, List[Candidate]]"],
) -> None:
    log(f"Fetching submodules from {source['repo']}...")
    sub_deps = fetch_submodule_deps(source["repo"], source["ref"])
    matched = 0
    for norm_url, candidate in sub_deps.items():
        if norm_url in base_deps:
            add_candidate(candidates, norm_url, candidate)
            matched += 1
    log(f"  Matched {matched} deps")


def resolve(pinned_path: str) -> List[str]:
    base_deps = parse_pinned(pinned_path)
    log(f"Loaded {len(base_deps)} deps from {pinned_path}")

    candidates: Dict[str, "OrderedDict[str, List[Candidate]]"] = defaultdict(OrderedDict)
    for norm_url, dep in base_deps.items():
        add_candidate(
            candidates,
            norm_url,
            Candidate(url=dep["url"], sha=dep["sha"], source="pinned"),
        )

    external_successes = 0

    for source in NIMBLE_LOCK_SOURCES:
        try:
            collect_nimble_lock_source(source, base_deps, candidates)
            external_successes += 1
        except Exception as err:
            log(f"  WARNING: Failed to fetch {source['repo']}: {err}")

    for source in SUBMODULE_SOURCES:
        try:
            collect_submodule_source(source, base_deps, candidates)
            external_successes += 1
        except Exception as err:
            log(f"  WARNING: Failed to fetch {source['repo']}: {err}")

    if external_successes == 0:
        raise RuntimeError("all external dependency sources failed")

    result: List[str] = []
    for norm_url, dep in base_deps.items():
        sha_map = candidates[norm_url]
        if len(sha_map) == 1:
            sha = next(iter(sha_map))
        else:
            log(f"Resolving {dep['name']} ({len(sha_map)} versions)...")
            sha = pick_newest(sha_map, dep["url"])
            log(f"  -> picked {sha[:12]}")
        result.append(f"{dep['url']}@#{sha}")
    return result


def main() -> int:
    pinned_path = sys.argv[1] if len(sys.argv) > 1 else ".pinned"

    try:
        resolved = resolve(pinned_path)
    except Exception as err:
        log(f"ERROR: {err}")
        return 1

    sys.stdout.buffer.write((" ".join(resolved) + "\n").encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
