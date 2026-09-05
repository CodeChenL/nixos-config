#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary="$(mktemp -d /tmp/chromium-qa-pytest.XXXXXXXXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
python3 -I -B -c '
import os
import sys
sys.path.extend(filter(None, os.environ.get("PYTHONPATH", "").split(os.pathsep)))
import pytest
raise SystemExit(pytest.main(sys.argv[1:]))
' -q -p no:cacheprovider --basetemp "$temporary/suite" \
  "$script_dir/test_observer.py"
