#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_valid() {
  local label="$1"
  local cidrs="$2"
  local log="${tmp}/${label}.log"

  make --no-print-directory -C "${root}" require-cluster-access \
    "TF_VAR_cluster_endpoint_public_access_cidrs=${cidrs}" >"${log}" 2>&1 \
    || fail "expected ${label} to pass"
}

assert_invalid() {
  local label="$1"
  local cidrs="$2"
  local expected="$3"
  local log="${tmp}/${label}.log"

  if make --no-print-directory -C "${root}" require-cluster-access \
    "TF_VAR_cluster_endpoint_public_access_cidrs=${cidrs}" >"${log}" 2>&1; then
    fail "expected ${label} to fail"
  fi

  grep -Fq "${expected}" "${log}" \
    || fail "${label} did not report the expected validation error"
}

assert_valid ipv4_host '["192.0.2.10/32"]'
assert_valid ipv6_network '["2001:db8:1::/64"]'
assert_valid mixed_narrow '["198.51.100.0/24","2001:db8::10/128"]'

assert_invalid empty '' 'is required for EKS API access'
assert_invalid malformed_json '["192.0.2.10/32"' 'must be a nonempty JSON array'
assert_invalid non_array '"192.0.2.10/32"' 'must be a nonempty JSON array'
assert_invalid non_string '[24]' 'must be a nonempty JSON array'
assert_invalid missing_prefix '["192.0.2.10"]' 'Prefixes must be'
assert_invalid nonnumeric_prefix '["192.0.2.10/nope"]' 'Prefixes must be'
assert_invalid ipv4_prefix_too_large '["192.0.2.10/33"]' 'Prefixes must be'
assert_invalid ipv6_prefix_too_large '["2001:db8::10/129"]' 'Prefixes must be'
assert_invalid ipv4_noncanonical_zero '["1.2.3.4/0"]' '/0 is forbidden'
assert_invalid ipv6_noncanonical_zero '["2001:db8::1/0"]' '/0 is forbidden'

printf 'Make EKS CIDR guard tests: OK\n'
