#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  printf 'Usage: verify-relay.sh STACK\n' >&2
  exit 1
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
relay_exports=$("$script_dir/relay.sh" outputs "$1")
eval "$relay_exports"

# curl verifies the public chain and IP SAN using the machine's standard trust.
# No --insecure, private CA bundle, or hostname override.
for port in "${RELAY_TENANT_PORT_START:?}" "${RELAY_TENANT_PORT_END:?}"; do
  status=$(curl --silent --show-error --max-time 15 --noproxy '*' \
    --output /dev/null --write-out '%{http_code}' "https://${RELAY_IP:?}:$port/")
  [[ "$status" == 503 ]] || { printf 'Expected 503 on port %s, got %s.\n' "$port" "$status" >&2; exit 1; }
done
# An HTTPS proxy CONNECT must also be rejected, not forwarded to the website.
connect_status=$(curl --silent --max-time 15 --noproxy '' \
  --proxy "https://$RELAY_IP:$RELAY_TENANT_PORT_START" \
  --output /dev/null --write-out '%{http_connect}' https://example.com/ || true)
if [[ "$connect_status" != 503 ]]; then
  printf 'Expected CONNECT rejection with 503, got %s.\n' "$connect_status" >&2
  exit 1
fi
"$script_dir/relay-ssh.sh" "$1" sudo /usr/local/sbin/relay-health
printf 'Verified public TLS, empty-route rejection, and server health.\n'
