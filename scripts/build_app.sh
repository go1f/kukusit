#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release --build-system native --product PostureDiagnostics
binary_dir="$(swift build -c release --build-system native --show-bin-path)"
app_path="$project_root/dist/PostureDiagnostics.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/PostureDiagnostics" "$app_path/Contents/MacOS/PostureDiagnostics"
cp "$project_root/App/Info.plist" "$app_path/Contents/Info.plist"
iconset_path="$project_root/.local/icons/Kukusit.iconset"
swift "$project_root/scripts/build_icons.swift" "$project_root/App/Assets/AppIcon.png" "$iconset_path"
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/Kukusit.icns"
cp "$project_root/App/Assets/StatusIcon.svg" "$app_path/Contents/Resources/StatusIcon.svg"
if [[ -f "$project_root/.local/pose-backend.json" ]]; then
  cp "$project_root/.local/pose-backend.json" "$app_path/Contents/Resources/pose-backend.json"
  cp "$project_root/pose-worker/pose_worker.py" "$app_path/Contents/Resources/pose_worker.py"
  cp "$project_root/.local/models/pose_landmarker_full.task" "$app_path/Contents/Resources/pose_landmarker_full.task"
fi
codesign --force --sign - --options runtime \
  --identifier com.kojyufu.posturediagnostics \
  --requirements '=designated => identifier "com.kojyufu.posturediagnostics"' \
  --entitlements "$project_root/App/Entitlements.plist" "$app_path"
codesign --verify --strict "$app_path"
printf 'Built: %s\n' "$app_path"
if [[ "${1:-}" == "--run" ]]; then
  open "$app_path"
elif [[ "${1:-}" == "--demo" ]]; then
  open "$app_path" --args --demo
fi
