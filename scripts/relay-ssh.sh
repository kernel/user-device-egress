#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  printf 'Usage: relay-ssh.sh STACK [REMOTE_COMMAND ...]\n' >&2
  exit 1
fi
stack=$1
shift
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
command -v jq >/dev/null || { printf 'Install jq first.\n' >&2; exit 1; }
relay_exports=$("$script_dir/relay.sh" outputs "$stack")
eval "$relay_exports"

# AWS issues temporary credentials and supplies authenticated host keys.
# Never download the shared default private key or trust an unauthenticated scan.
umask 077
access_dir=$(mktemp -d)
trap 'rm -f "$access_dir/access.json" "$access_dir/key" "$access_dir/key-cert.pub" "$access_dir/known_hosts"; rmdir "$access_dir"' EXIT
AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off aws --region "${RELAY_REGION:?}" lightsail get-instance-access-details \
  --instance-name "${RELAY_INSTANCE:?}" --protocol ssh --output json > "$access_dir/access.json"
if ! jq -e --arg ip "${RELAY_IP:?}" --arg instance "$RELAY_INSTANCE" \
  '.accessDetails | .ipAddress == $ip and .instanceName == $instance and (.hostKeys | length > 0)' \
  "$access_dir/access.json" >/dev/null; then
  printf 'AWS has not supplied matching instance/host-key data yet; SSH was not attempted.\n' >&2
  exit 1
fi
jq -er '.accessDetails.privateKey' "$access_dir/access.json" > "$access_dir/key"
jq -er '.accessDetails.certKey' "$access_dir/access.json" > "$access_dir/key-cert.pub"
jq -er --arg ip "$RELAY_IP" \
  '.accessDetails.hostKeys[] | "\($ip) \(.algorithm) \(.publicKey)"' \
  "$access_dir/access.json" > "$access_dir/known_hosts"
ssh -F /dev/null -i "$access_dir/key" \
  -o "CertificateFile=$access_dir/key-cert.pub" \
  -o "UserKnownHostsFile=$access_dir/known_hosts" \
  -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes \
  -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "${RELAY_SSH_USER:?}@$RELAY_IP" "$@"
