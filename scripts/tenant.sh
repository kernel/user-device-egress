#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 2 ]] || { printf 'Usage: tenant.sh init|list|enroll|revoke STACK [ID PORT PUBLIC_KEY_FILE]\n' >&2; exit 1; }
action=$1
stack=$2
shift 2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "$action" in
  init)
    [[ $# -eq 0 ]] || exit 1
    relay_exports=$("$script_dir/relay.sh" outputs "$stack")
    eval "$relay_exports"
    [[ "${RELAY_TUNNEL_PORT_START:?Redeploy the current CloudFormation template first}" -eq $((RELAY_TENANT_PORT_START + 20000)) && "${RELAY_TUNNEL_PORT_END:?}" -eq $((RELAY_TENANT_PORT_END + 20000)) ]] || {
      printf 'SSH port range must equal the public TLS port range plus 20000.\n' >&2; exit 1;
    }
    "$script_dir/relay-ssh.sh" "$stack" 'sudo tee /usr/local/sbin/relay-tenant >/dev/null && sudo chmod 700 /usr/local/sbin/relay-tenant' < "$script_dir/../infra/tenant-manager.py"
    "$script_dir/relay-ssh.sh" "$stack" sudo /usr/local/sbin/relay-tenant init "${RELAY_IP:?}" "${RELAY_TENANT_PORT_START:?}" "${RELAY_TENANT_PORT_END:?}"
    ;;
  enroll|revoke)
    [[ ${1:-} =~ ^[a-z][a-z0-9]{0,19}$ ]] || { printf 'Invalid tenant ID.\n' >&2; exit 1; }
    if [[ "$action" == enroll ]]; then
      [[ $# -eq 3 && "$2" =~ ^2[0-9]{4}$ ]] || exit 1
      "$script_dir/relay-ssh.sh" "$stack" sudo /usr/local/sbin/relay-tenant enroll "$1" "$2" < "$3"
    else
      [[ $# -eq 1 ]] || exit 1
      "$script_dir/relay-ssh.sh" "$stack" sudo /usr/local/sbin/relay-tenant revoke "$1"
    fi
    ;;
  list)
    [[ $# -eq 0 ]] || exit 1
    "$script_dir/relay-ssh.sh" "$stack" sudo /usr/local/sbin/relay-tenant list
    ;;
  *) exit 1 ;;
esac
