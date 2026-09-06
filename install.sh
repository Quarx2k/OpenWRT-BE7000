#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12+ required"'
test -d .installer-venv || python3 -m venv .installer-venv
.installer-venv/bin/pip -q install -r installer/requirements.txt
exec .installer-venv/bin/python installer/install.py "$@"
