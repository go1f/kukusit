#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ ! -x .venv-pose/bin/python ]]; then
  printf '%s\n' 'First run scripts/setup_pose_backend.sh with Python 3.11+.' >&2
  exit 1
fi
.venv-pose/bin/python -m pip install -r pose-worker/build-requirements.txt
.venv-pose/bin/python -m PyInstaller --noconfirm --clean --onedir \
  --name pose-worker --target-arch arm64 --collect-all mediapipe \
  --distpath .local/frozen --workpath .local/pyinstaller-build --specpath .local \
  pose-worker/pose_worker.py
