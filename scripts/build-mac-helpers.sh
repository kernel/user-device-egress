#!/usr/bin/env bash
# Xcode build phase: Go is needed on the build Mac only, never at app runtime.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$script_dir/.." && pwd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v go >/dev/null || { printf 'error: Install Go 1.24+ on the build Mac.\n' >&2; exit 1; }
destination="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}"
mkdir -p "$destination"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/mac-egress-build.XXXXXX")
trap 'rm -f "$temporary/mac-proxy-arm64" "$temporary/mac-proxy-amd64" "$temporary/mac-session-arm64" "$temporary/mac-session-amd64"; rmdir "$temporary"' EXIT
for helper in mac-proxy mac-session; do
  binaries=()
  for architecture in ${ARCHS:?}; do
    case "$architecture" in
      arm64) go_arch=arm64 ;;
      x86_64) go_arch=amd64 ;;
      *) printf 'error: Unsupported architecture %s\n' "$architecture" >&2; exit 1 ;;
    esac
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" go build -C "$repo" -trimpath \
      -o "$temporary/$helper-$go_arch" "./cmd/$helper"
    binaries+=("$temporary/$helper-$go_arch")
  done
  /usr/bin/lipo -create "${binaries[@]}" -output "$destination/$helper"
  chmod 755 "$destination/$helper"
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$destination/$helper"
done
