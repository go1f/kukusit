#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release --build-system native --product PostureDiagnostics
swift build -c release --build-system native --product KukusitUpdateInstaller
binary_dir="$(swift build -c release --build-system native --show-bin-path)"
app_path="$project_root/dist/PostureDiagnostics.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/PostureDiagnostics" "$app_path/Contents/MacOS/PostureDiagnostics"
# Discard the unused Sparkle framework from earlier development builds.
if [[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]]; then
  mv "$app_path/Contents/Frameworks/Sparkle.framework" "$project_root/.local/unused-Sparkle-$(date +%s).framework"
fi
mkdir -p "$app_path/Contents/Helpers"
cp "$binary_dir/KukusitUpdateInstaller" "$app_path/Contents/Helpers/KukusitUpdateInstaller"
cp "$project_root/App/Info.plist" "$app_path/Contents/Info.plist"
iconset_path="$project_root/.local/icons/Kukusit.iconset"
swift "$project_root/scripts/build_icons.swift" "$project_root/App/Assets/AppIcon.png" "$iconset_path" light
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/Kukusit.icns"
for appearance in Light Dark; do
  variant_iconset="$project_root/.local/icons/Kukusit${appearance}.iconset"
  swift "$project_root/scripts/build_icons.swift" "$project_root/App/Assets/AppIcon.png" "$variant_iconset" "${appearance:l}"
  iconutil -c icns "$variant_iconset" -o "$app_path/Contents/Resources/Kukusit${appearance}.icns"
done
cp "$project_root/App/Assets/SeatedMascot.svg" "$app_path/Contents/Resources/SeatedMascot.svg"
# Discard the superseded generated menu icon; the mascot is now an opt-in easter egg.
rm -f "$app_path/Contents/Resources/StatusIcon.svg"
if [[ -f "$project_root/.local/pose-backend.json" ]]; then
  cp "$project_root/.local/pose-backend.json" "$app_path/Contents/Resources/pose-backend.json"
  cp "$project_root/pose-worker/pose_worker.py" "$app_path/Contents/Resources/pose_worker.py"
  cp "$project_root/.local/models/pose_landmarker_full.task" "$app_path/Contents/Resources/pose_landmarker_full.task"
fi
zsh "$project_root/scripts/sign_app.sh" "$app_path"
printf 'Built: %s\n' "$app_path"
if [[ "${1:-}" == "--run" ]]; then
  open "$app_path"
elif [[ "${1:-}" == "--demo" ]]; then
  open "$app_path" --args --demo
fi
