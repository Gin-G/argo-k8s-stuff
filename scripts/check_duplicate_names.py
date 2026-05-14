#!/usr/bin/env python3
"""Check for duplicate Argo CD Application names across all YAML files in the repo."""

import sys
from pathlib import Path
from collections import defaultdict

REPO_ROOT = Path(__file__).parent.parent


def extract_app_name(path: Path) -> str | None:
    """
    Return metadata.name if this file contains an Argo CD Application resource.

    Uses text-based parsing instead of a YAML parser so it works on
    Helm-templated files (which aren't valid YAML until rendered).
    """
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError):
        return None

    if "argoproj.io/v1alpha1" not in text:
        return None

    found_api = False
    found_kind = False
    in_metadata = False

    for line in text.splitlines():
        stripped = line.strip()

        if stripped == "---":
            found_api = found_kind = in_metadata = False
            continue

        if stripped == "apiVersion: argoproj.io/v1alpha1":
            found_api = True
            found_kind = in_metadata = False
        elif found_api and stripped == "kind: Application":
            found_kind = True
        elif found_kind and stripped == "metadata:":
            in_metadata = True
        elif in_metadata and stripped.startswith("name:"):
            name = stripped[len("name:"):].strip()
            # Skip Helm template expressions — those names are dynamic
            if name and not name.startswith("{{"):
                return name

    return None


def main() -> int:
    seen: defaultdict[str, list[Path]] = defaultdict(list)

    for path in sorted(REPO_ROOT.glob("**/*.yaml")):
        name = extract_app_name(path)
        if name:
            seen[name].append(path)

    for path in sorted(REPO_ROOT.glob("**/*.yml")):
        name = extract_app_name(path)
        if name:
            seen[name].append(path)

    duplicates = {name: paths for name, paths in seen.items() if len(paths) > 1}

    if not duplicates:
        print("OK: no duplicate Argo CD Application names found.")
        return 0

    print("FAIL: duplicate Argo CD Application names found:\n")
    for name, paths in sorted(duplicates.items()):
        print(f"  name: {name!r}")
        for p in paths:
            print(f"    {p.relative_to(REPO_ROOT)}")
        print()

    return 1


if __name__ == "__main__":
    sys.exit(main())
