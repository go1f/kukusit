#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
pose_python="${1:-python3}"
"$pose_python" -c 'import sys; assert sys.version_info >= (3,11), "MediaPipe helper setup needs Python 3.11+"'
if [[ ! -x .venv-pose/bin/python ]]; then "$pose_python" -m venv .venv-pose; fi
.venv-pose/bin/python -m pip install -r pose-worker/requirements.txt
mkdir -p .local/models
pose_model=".local/models/pose_landmarker_full.task"
if [[ ! -f "$pose_model" ]]; then
  curl -fsSL --max-time 60 \
    'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task' \
    -o "$pose_model"
fi
.venv-pose/bin/python - <<'PY'
from pathlib import Path
import hashlib
import json
import mediapipe
root = Path.cwd()
model = root / '.local/models/pose_landmarker_full.task'
config = {'pythonExecutable': str(root / '.venv-pose/bin/python'),
          'modelFile': model.name, 'modelSHA256': hashlib.sha256(model.read_bytes()).hexdigest(),
          'packageVersion': mediapipe.__version__}
(root / '.local/pose-backend.json').write_text(json.dumps(config, indent=2) + '\n')
print('Local pose helper configured; frames will only travel through process pipes.')
PY
