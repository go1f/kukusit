#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ ! -x .venv-pose/bin/python ]]; then
  printf '%s\n' 'First run scripts/setup_pose_backend.sh with Python 3.11+.' >&2
  exit 1
fi
if ! .venv-pose/bin/python -c 'import PyInstaller; assert PyInstaller.__version__ == "6.16.0"' >/dev/null 2>&1; then
  .venv-pose/bin/python -m pip install -r pose-worker/build-requirements.txt
fi
.venv-pose/bin/python -m PyInstaller --noconfirm --clean --onedir \
  --name pose-worker --target-arch arm64 --collect-all mediapipe \
  --distpath .local/frozen --workpath .local/pyinstaller-build --specpath .local \
  pose-worker/pose_worker.py

shasum -a 256 pose-worker/pose_worker.py pose-worker/requirements.txt pose-worker/build-requirements.txt > .local/frozen/source.sha256
