from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from .probe import ProbeError, probe_target
from .transport import TransportError


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: probe-target.py TARGET FIREFOX", file=sys.stderr)
        return 2
    try:
        result = probe_target(sys.argv[1], Path(sys.argv[2]))
    except (ProbeError, TransportError, OSError, subprocess.SubprocessError) as error:
        print(f"probe failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
