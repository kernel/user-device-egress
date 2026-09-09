#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  printf 'Usage: configure-relay.sh STACK\n' >&2
  exit 1
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
relay_exports=$("$script_dir/relay.sh" outputs "$1")
eval "$relay_exports"
"$script_dir/relay-ssh.sh" "$1" sudo bash -s -- \
  "${RELAY_IP:?}" "${RELAY_TENANT_PORT_START:?}" "${RELAY_TENANT_PORT_END:?}" \
  < "$script_dir/../infra/setup-relay.sh"
