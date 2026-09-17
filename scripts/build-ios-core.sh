#!/usr/bin/env bash
# Build the pinned in-process networking library for physical devices and simulators.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v go >/dev/null || { printf 'Install Go (automatic toolchain download must be enabled).\n' >&2; exit 1; }
mkdir -p .local/ios/bin
export GOBIN="$repo/.local/ios/bin"
export PATH="$GOBIN:$PATH"
go install golang.org/x/mobile/cmd/gobind
go tool gomobile bind -target=ios,iossimulator -iosversion=26.0 \
  -o "$repo/.local/ios/EgressCore.xcframework" ./mobile
printf 'Built .local/ios/EgressCore.xcframework. Open iOSEgress in Xcode and Run.\n'
