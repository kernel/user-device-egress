#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: relay.sh validate' \
    '       relay.sh deploy STACK [Parameter=value ...]' \
    '       relay.sh outputs STACK' \
    '       relay.sh destroy STACK' \
    '' \
    'Uses AWS credentials and region from the environment/configuration. Requires Bash and AWS CLI v2.' \
    'deploy creates or updates a stack; SshCidr is required on first creation.' \
    'deploy/outputs print shell exports on stdout; progress goes to stderr.' \
    'destroy deletes the VM, its disk, and static IP; it waits for completion.'
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

action=${1:-help}
case "$action" in
  help|-h|--help) usage; exit 0 ;;
  validate|deploy|outputs|destroy) ;;
  *) usage >&2; exit 1 ;;
esac
shift

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template="$script_dir/../infra/relay.yaml"
command -v aws >/dev/null || fail 'Install AWS CLI v2 first.'
export AWS_PAGER=''
export AWS_CLI_AUTO_PROMPT=off

region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
if [[ -z "$region" ]]; then
  region=$(aws configure get region) || fail 'Set AWS_REGION or configure an AWS region.'
fi
[[ -n "$region" ]] || fail 'Set AWS_REGION or configure an AWS region.'
aws_cli() { aws --region "$region" "$@"; }

if [[ "$action" == validate ]]; then
  [[ $# -eq 0 ]] || fail 'validate takes no arguments.'
  aws_cli cloudformation validate-template --template-body "file://$template" >/dev/null
  printf 'CloudFormation template validation passed.\n' >&2
  exit 0
fi

[[ $# -ge 1 ]] || fail 'Supply an explicit stack name.'
stack=$1
shift
[[ "$stack" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ && ${#stack} -le 128 ]] || fail 'Invalid CloudFormation stack name.'
if [[ "$action" != deploy && $# -ne 0 ]]; then
  fail "$action takes only a stack name."
fi

print_exports() {
  local outputs key value variable
  outputs=$(aws_cli cloudformation describe-stacks --stack-name "$stack" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text)
  [[ -n "$outputs" && "$outputs" != None ]] || fail 'Stack has no outputs yet.'
  while IFS=$'\t' read -r key value; do
    case "$key" in
      StackId) variable=RELAY_STACK_ID ;;
      Region) variable=RELAY_REGION ;;
      InstanceName) variable=RELAY_INSTANCE ;;
      StaticIp) variable=RELAY_IP ;;
      SshUser) variable=RELAY_SSH_USER ;;
      SshKeyPair) variable=RELAY_SSH_KEY_PAIR ;;
      TenantPortStart) variable=RELAY_TENANT_PORT_START ;;
      TenantPortEnd) variable=RELAY_TENANT_PORT_END ;;
      TunnelPortStart) variable=RELAY_TUNNEL_PORT_START ;;
      TunnelPortEnd) variable=RELAY_TUNNEL_PORT_END ;;
      *) continue ;;
    esac
    printf 'export %s=%q\n' "$variable" "$value"
  done <<< "$outputs"
}

case "$action" in
  deploy)
    for parameter in "$@"; do
      [[ "$parameter" =~ ^[a-zA-Z][a-zA-Z0-9]*= ]] || fail 'Use CloudFormation parameters in Parameter=value form.'
    done
    account=$(aws_cli sts get-caller-identity --query Account --output text)
    printf 'Deploying %s in account %s, region %s.\n' "$stack" "$account" "$region" >&2
    args=(cloudformation deploy --template-file "$template" --stack-name "$stack" --no-fail-on-empty-changeset)
    if [[ $# -gt 0 ]]; then
      args+=(--parameter-overrides "$@")
    fi
    aws_cli "${args[@]}" >&2
    print_exports
    ;;
  outputs)
    print_exports
    ;;
  destroy)
    # Resolve the exact stack before deleting; do not re-resolve its name during the wait.
    stack_id=$(aws_cli cloudformation describe-stacks --stack-name "$stack" \
      --query 'Stacks[0].StackId' --output text)
    [[ "$stack_id" == arn:*:cloudformation:* ]] || fail 'Could not resolve the stack ARN.'
    printf 'Deleting %s (including the VM disk and static IP).\n' "$stack_id" >&2
    aws_cli cloudformation delete-stack --stack-name "$stack_id"
    aws_cli cloudformation wait stack-delete-complete --stack-name "$stack_id"
    printf 'Deleted %s.\n' "$stack_id" >&2
    ;;
esac
