#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'Build this release on an Apple Silicon Mac.' >&2; exit 1
fi
runtime_sources="$(shasum -a 256 pose-worker/pose_worker.py pose-worker/requirements.txt pose-worker/build-requirements.txt)"
if [[ ! -x .local/frozen/pose-worker/pose-worker || ! -f .local/frozen/source.sha256 ]]    || [[ "$(cat .local/frozen/source.sha256)" != "$runtime_sources" ]]; then
  zsh scripts/build_pose_runtime.sh
fi
zsh scripts/build_app.sh
release_app="$project_root/release/Kukusit.app"
mkdir -p release
if [[ -d "$release_app" ]]; then mv "$release_app" "$project_root/.local/previous-release-app-$(date +%s)"; fi
ditto dist/PostureDiagnostics.app "$release_app"
ditto .local/frozen/pose-worker "$release_app/Contents/Resources/PoseRuntime"
.venv-pose/bin/python - <<'PY'
from pathlib import Path
import json
root=Path.cwd()
config=json.loads((root/'.local/pose-backend.json').read_text())
config.pop('pythonExecutable',None)
config['bundledExecutable']='Contents/Resources/PoseRuntime/pose-worker'
(root/'release/Kukusit.app/Contents/Resources/pose-backend.json').write_text(json.dumps(config,indent=2)+'\n')
PY
cp THIRD_PARTY_NOTICES.md "$release_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$release_app/Contents/Resources/ThirdPartyLicenses/Python"
cp App/Python-LICENSE.txt "$release_app/Contents/Resources/ThirdPartyLicenses/Python/LICENSE.txt"
.venv-pose/bin/python scripts/collect_licenses.py "$release_app/Contents/Resources/ThirdPartyLicenses"
zsh scripts/sign_app.sh "$release_app"
"$release_app/Contents/MacOS/PostureDiagnostics" --bridge-check
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"
archive="release/Kukusit-${version}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$release_app" "$archive"
(cd release && shasum -a 256 "$(basename "$archive")") > "${archive}.sha256"
printf 'Portable app: %s\nArchive: %s\n' "$release_app" "$archive"
