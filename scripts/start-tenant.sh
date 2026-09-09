#!/usr/bin/env bash
# Foreground sharing session; stop with Ctrl-C. No AWS credentials required.
set -euo pipefail
[[ $# -ge 3 && $# -le 4 ]] || { printf 'Usage: start-tenant.sh MANIFEST SSH_PRIVATE_KEY NEW_SESSION_DIRECTORY [LOCAL_PORT]\n' >&2; exit 1; }
manifest=$1
key=$2
session=$3
port=${4:-18080}
[[ "$port" =~ ^[0-9]{4,5}$ && "$port" -le 65535 ]] || exit 1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$script_dir/.." && pwd)
umask 077
mkdir "$session"
session=$(cd "$session" && pwd)
go build -C "$repo" -o "$session/mac-proxy" ./cmd/mac-proxy
"$session/mac-proxy" -init -credentials "$session/credentials.json"
ip=$(jq -er .ip "$manifest")
ssh_port=$(jq -er .ssh_port "$manifest")
tunnel_port=$(jq -er .tunnel_port "$manifest")
ssh_user=$(jq -er .ssh_user "$manifest")
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$ssh_port" =~ ^4[0-9]{4}$ && "$tunnel_port" =~ ^3[0-9]{4}$ && "$ssh_user" =~ ^relay_[a-z][a-z0-9]{0,19}$ ]] || exit 1
jq -er '"[\(.ip)]:\(.ssh_port) \(.host_key)"' "$manifest" > "$session/known_hosts"
jq -r --slurpfile relay "$manifest" \
  '"proxy = \"https://\($relay[0].ip):\($relay[0].port)\"\nproxy-user = \"\(.username):\(.password)\"\nnoproxy = \"\"\n"' \
  "$session/credentials.json" > "$session/curl.conf"
proxy_pid=''
tunnel_pid=''
# Called by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  trap - EXIT INT TERM
  [[ -z "$tunnel_pid" ]] || kill "$tunnel_pid" 2>/dev/null || true
  [[ -z "$proxy_pid" ]] || kill "$proxy_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$session/mac-proxy" -credentials "$session/credentials.json" -listen "127.0.0.1:$port" \
  -allow "${RELAY_ALLOWED_HOSTS:-checkip.amazonaws.com,api.ipify.org,public-ping-bucket-kernel.s3.us-east-1.amazonaws.com}" &
proxy_pid=$!
ssh -F /dev/null -N -i "$key" -p "$ssh_port" \
  -o "UserKnownHostsFile=$session/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes \
  -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -R "127.0.0.1:$tunnel_port:127.0.0.1:$port" "$ssh_user@$ip" &
tunnel_pid=$!
printf 'Session starting. Test with: curl --config %q https://checkip.amazonaws.com/\n' "$session/curl.conf"
# Bash 3.2 on macOS has no wait -n. Watch both children so either failure stops sharing.
while kill -0 "$proxy_pid" 2>/dev/null && kill -0 "$tunnel_pid" 2>/dev/null; do sleep 1; done
printf 'Proxy or tunnel exited; stopping sharing.\n' >&2
exit 1
