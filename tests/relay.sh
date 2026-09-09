#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
relay="$test_dir/../scripts/relay.sh"
test_tmp=$(mktemp -d)
# Only remove the exact temporary files created by this test.
trap 'rm -f "$test_tmp/calls" "$test_tmp/stdout" "$test_tmp/stderr"; rmdir "$test_tmp"' EXIT
export PATH="$test_dir/fixtures:$PATH"
export RELAY_TEST_LOG="$test_tmp/calls"
export AWS_REGION=us-west-2

assert_contains() { grep -Fq -- "$1" "$2" || { printf 'Missing: %s\n' "$1" >&2; exit 1; }; }
assert_absent() { if grep -Fq -- "$1" "$2"; then printf 'Unexpected: %s\n' "$1" >&2; exit 1; fi; }

# Deploy can forward a parameter containing spaces as one argument. Progress
# must not contaminate the shell exports, even when AWS writes it to stdout.
"$relay" deploy test-relay 'SshCidr=192.0.2.10/32' 'KeyPairName=a key' > "$test_tmp/stdout" 2> "$test_tmp/stderr"
assert_contains 'KeyPairName=a\ key' "$RELAY_TEST_LOG"
assert_contains --no-fail-on-empty-changeset "$RELAY_TEST_LOG"
assert_contains 'AWS deployment progress' "$test_tmp/stderr"
assert_absent 'AWS deployment progress' "$test_tmp/stdout"
# shellcheck disable=SC1091
source "$test_tmp/stdout"
[[ "$RELAY_IP" == 192.0.2.20 ]]
# Command substitution must remain literal after sourcing.
# shellcheck disable=SC2016
[[ "$RELAY_SSH_KEY_PAIR" == 'literal-$(echo injected); spaced key' ]]

# A failed deployment must return nonzero and must not print usable exports.
if RELAY_TEST_DEPLOY_EXIT=7 "$relay" deploy test-relay > "$test_tmp/stdout" 2> "$test_tmp/stderr"; then
  printf 'Failed deployment unexpectedly succeeded.\n' >&2; exit 1
fi
[[ ! -s "$test_tmp/stdout" ]]

# Do not delete anything when the target stack cannot be resolved.
: > "$RELAY_TEST_LOG"
if RELAY_TEST_DESCRIBE_EXIT=9 "$relay" destroy missing > "$test_tmp/stdout" 2> "$test_tmp/stderr"; then
  printf 'Missing stack unexpectedly succeeded.\n' >&2; exit 1
fi
assert_absent delete-stack "$RELAY_TEST_LOG"

# Both deletion and the waiter must target the resolved stack ARN, not its name.
: > "$RELAY_TEST_LOG"
"$relay" destroy test-relay > "$test_tmp/stdout" 2> "$test_tmp/stderr"
assert_contains 'delete-stack --stack-name arn:aws:cloudformation:us-west-2:000000000000:stack/test-relay/exact-id' "$RELAY_TEST_LOG"
assert_contains 'wait stack-delete-complete --stack-name arn:aws:cloudformation:us-west-2:000000000000:stack/test-relay/exact-id' "$RELAY_TEST_LOG"

# Invalid commands/arguments must not reach an AWS operation.
: > "$RELAY_TEST_LOG"
for action in outputs deploy destroy; do
  if "$relay" "$action" --bad-name > "$test_tmp/stdout" 2> "$test_tmp/stderr"; then
    printf 'Invalid stack name accepted.\n' >&2; exit 1
  fi
done
[[ ! -s "$RELAY_TEST_LOG" ]]

# Use configured region when neither standard region environment variable is set.
unset AWS_REGION AWS_DEFAULT_REGION
"$relay" outputs test-relay > "$test_tmp/stdout" 2> "$test_tmp/stderr"
assert_contains 'configure get region' "$RELAY_TEST_LOG"
assert_contains '--region us-west-2 cloudformation describe-stacks' "$RELAY_TEST_LOG"
printf 'Relay lifecycle checks passed (offline; no AWS resources touched).\n'
