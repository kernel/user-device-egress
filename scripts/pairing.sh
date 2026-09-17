#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 2 ]] || { printf 'Usage: pairing.sh install STACK | issue STACK DEVICE OUTPUT_DIR\n' >&2; exit 1; }
action=$1 stack=$2
shift 2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$script_dir/.." && pwd)
case "$action" in
  install)
    [[ $# -eq 0 ]] || exit 1
    mkdir -p "$repo/.local/pairing-build"
    (cd "$repo" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o .local/pairing-build/relay-pairing ./cmd/relay-pairing)
    "$script_dir/relay-ssh.sh" "$stack" 'sudo install -d -m 0700 /var/lib/mac-egress-relay/pairing-upload && sudo tee /var/lib/mac-egress-relay/pairing-upload/server >/dev/null' < "$repo/.local/pairing-build/relay-pairing"
    "$script_dir/relay-ssh.sh" "$stack" 'sudo tee /var/lib/mac-egress-relay/pairing-upload/manager >/dev/null' < "$repo/infra/pairing-manager.py"
    "$script_dir/relay-ssh.sh" "$stack" 'sudo tee /var/lib/mac-egress-relay/pairing-upload/tenant >/dev/null' < "$repo/infra/tenant-manager.py"
    "$script_dir/relay-ssh.sh" "$stack" sudo bash -s < "$repo/infra/setup-pairing.sh"
    ;;
  issue)
    [[ $# -eq 2 && "$1" =~ ^[a-z][a-z0-9]{0,19}$ ]] || exit 1
    command -v xcrun >/dev/null || { printf 'QR rendering requires macOS with Xcode command-line tools.\n' >&2; exit 1; }
    umask 077
    mkdir -- "$2"
    "$script_dir/relay-ssh.sh" "$stack" sudo /usr/local/sbin/relay-pair issue "$1" > "$2/invitation.json"
    xcrun swift "$script_dir/render-pairing.swift" "$2/pairing.png" < "$2/invitation.json"
    printf 'Scan %s/pairing.png in the iPhone app. Expires in 10 minutes; keep it private.\n' "$2"
    ;;
  *) exit 1 ;;
esac
