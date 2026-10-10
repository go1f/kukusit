#!/bin/zsh
set -euo pipefail
probe_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$probe_root/.build"
xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" \
  "$probe_root/probes/capability_probe.swift" \
  -o "$probe_root/.build/capability-probe"
exec "$probe_root/.build/capability-probe" "$@"
