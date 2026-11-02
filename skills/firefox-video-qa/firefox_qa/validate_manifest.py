from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from .manifest import ManifestError, parse_and_verify_manifest


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-manifest.py MANIFEST.json", file=sys.stderr)
        return 2
    try:
        manifest = parse_and_verify_manifest(Path(sys.argv[1]))
    except (ManifestError, OSError, subprocess.SubprocessError) as error:
        print(f"manifest invalid: {error}", file=sys.stderr)
        return 1
    output = {
        "schema_version": manifest.schema_version,
        "scenarios": [scenario.to_json() for scenario in manifest.scenarios],
    }
    print(json.dumps(output, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
