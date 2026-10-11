#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"
staging="$(mktemp -d "$project_root/.local/dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto release/Kukusit.app "$staging/Kukusit.app"
ln -s /Applications "$staging/Applications"
printf '%s\n' '将 Kukusit.app 拖到 Applications 文件夹，然后从“应用程序”或 Spotlight 启动。' \
  '首次开始监测需允许摄像头。图像在本机处理，不上传、不保存照片或录像。' \
  '本版是本地开发证书自签名，未进行 Apple 公证；按 macOS 的隐私与安全性提示手动允许。' > "$staging/安装说明.txt"
archive="release/Kukusit-${version}-macOS-arm64.dmg"
hdiutil create -volname Kukusit -srcfolder "$staging" -format UDZO -ov "$archive"
(cd release && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
