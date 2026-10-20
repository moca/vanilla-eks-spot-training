#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eks_dir="$(cd "${test_dir}/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT

# Exercise the production variable contract without loading providers, backend
# configuration, modules, or any resource that could contact AWS.
cp "${eks_dir}/variables.tf" "${fixture_dir}/variables.tf"
terraform -chdir="${fixture_dir}" init -backend=false -input=false -no-color >/dev/null

assert_valid() {
  local label="$1"
  local cidrs="$2"
  local log="${fixture_dir}/${label}.log"

  if ! terraform -chdir="${fixture_dir}" plan \
    -input=false \
    -lock=false \
    -refresh=false \
    -no-color \
    -var='aws_region=test-region-1' \
    -var="cluster_endpoint_public_access_cidrs=${cidrs}" >"${log}" 2>&1; then
    printf 'FAIL: expected %s to be accepted\n' "${label}" >&2
    cat "${log}" >&2
    return 1
  fi
}

assert_invalid() {
  local label="$1"
  local cidrs="$2"
  local log="${fixture_dir}/${label}.log"

  if terraform -chdir="${fixture_dir}" plan \
    -input=false \
    -lock=false \
    -refresh=false \
    -no-color \
    -var='aws_region=test-region-1' \
    -var="cluster_endpoint_public_access_cidrs=${cidrs}" >"${log}" 2>&1; then
    printf 'FAIL: expected %s to be rejected\n' "${label}" >&2
    cat "${log}" >&2
    return 1
  fi

  if ! grep -Fq 'prefix-length /0 CIDRs are' "${log}"; then
    printf 'FAIL: %s failed for an unexpected reason\n' "${label}" >&2
    cat "${log}" >&2
    return 1
  fi
}

assert_valid ipv4_host '["192.0.2.10/32"]'
assert_valid ipv4_network '["198.51.100.0/24"]'
assert_valid ipv6_host '["2001:db8::10/128"]'
assert_valid ipv6_network '["2001:db8:1::/64"]'
assert_valid mixed_narrow '["192.0.2.10/32","2001:db8::10/128"]'

assert_invalid empty '[]'
assert_invalid malformed '["not-a-cidr"]'
assert_invalid ipv4_canonical_zero '["0.0.0.0/0"]'
assert_invalid ipv4_noncanonical_zero '["1.2.3.4/0"]'
assert_invalid ipv6_canonical_zero '["::/0"]'
assert_invalid ipv6_noncanonical_zero '["2001:db8::1/0"]'

printf 'endpoint CIDR validation tests passed\n'
