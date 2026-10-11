#!/usr/bin/env python3
"""Select the newest installed Xcode numerically, or honor an explicit path."""
import argparse
from pathlib import Path
import re


def select_xcode(applications, requested=""):
    def installed(path):
        return path.is_dir() and (path / "Contents/Developer").is_dir()

    if requested:
        path = Path(requested)
        if not installed(path):
            raise ValueError(f"requested Xcode is not installed: {path}")
        return path

    candidates = [path for path in Path(applications).glob("Xcode*.app") if installed(path)]
    if not candidates:
        raise ValueError(f"no installed Xcode under {applications}")

    def version(path):
        match = re.match(r"Xcode_(\d+(?:\.\d+)*)", path.resolve().name)
        if not match:
            match = re.match(r"Xcode_(\d+(?:\.\d+)*)", path.name)
        numbers = tuple(map(int, match.group(1).split("."))) if match else ()
        return numbers, path.name

    return max(candidates, key=version)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--applications", default="/Applications")
    parser.add_argument("--requested", default="")
    arguments = parser.parse_args()
    try:
        print(select_xcode(arguments.applications, arguments.requested))
    except ValueError as error:
        parser.exit(1, f"error: {error}\n")
