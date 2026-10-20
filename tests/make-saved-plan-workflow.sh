#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="123456789012"
region="test-region-1"
plan_dir="${root}/.terraform-plans"

common=(
  --no-print-directory
  -n
  -C "${root}"
  "EXPECTED_ACCOUNT=${account}"
  "REGION=${region}"
  "AWS_PROFILE=unused"
  "TF_VAR_cluster_name=nanochat-demo"
  "ECR=example.invalid/repository"
  "BUCKET=example-bucket"
)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

missing_account_log="$(mktemp)"
trap 'rm -f "${missing_account_log}"' EXIT
if make --no-print-directory -C "${root}" require-config \
  EXPECTED_ACCOUNT= REGION="${region}" TF_VAR_cluster_name=nanochat-demo \
  >"${missing_account_log}" 2>&1; then
  fail "require-config accepted an empty EXPECTED_ACCOUNT"
fi
grep -Fq 'EXPECTED_ACCOUNT must be the intended 12-digit AWS account ID.' \
  "${missing_account_log}" \
  || fail "require-config did not explain the missing account assertion"

assert_contains() {
  local output="$1"
  local expected="$2"
  local label="$3"

  grep -Fq -- "${expected}" <<<"${output}" \
    || fail "${label} did not contain: ${expected}"
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  local label="$3"

  if grep -Fq -- "${unexpected}" <<<"${output}"; then
    fail "${label} unexpectedly contained: ${unexpected}"
  fi
}

foundation_plan="$(make "${common[@]}" foundation-plan)"
foundation_apply="$(make "${common[@]}" foundation-apply)"
foundation_alias="$(make "${common[@]}" foundation)"

foundation_artifact="${plan_dir}/foundation-${account}-${region}.tfplan"
assert_contains "${foundation_plan}" \
  "terraform plan -input=false -lock-timeout=10m -out=\"${foundation_artifact}\"" \
  foundation-plan
assert_not_contains "${foundation_plan}" "terraform apply " foundation-plan
assert_contains "${foundation_apply}" \
  "terraform apply -input=false -lock-timeout=10m \"${foundation_artifact}\"" \
  foundation-apply
assert_not_contains "${foundation_apply}" "terraform plan " foundation-apply
assert_not_contains "${foundation_apply}" "-auto-approve" foundation-apply
assert_contains "${foundation_alias}" \
  "terraform plan -input=false -lock-timeout=10m -out=\"${foundation_artifact}\"" \
  foundation-alias

cluster_common=(
  "${common[@]}"
  'TF_VAR_cluster_endpoint_public_access_cidrs=["192.0.2.10/32"]'
)
cluster_plan="$(make "${cluster_common[@]}" cluster-plan)"
cluster_apply="$(make "${cluster_common[@]}" cluster-apply)"
cluster_alias="$(make "${cluster_common[@]}" cluster)"

cluster_artifact="${plan_dir}/cluster-${account}-${region}.tfplan"
assert_contains "${cluster_plan}" \
  "terraform plan -input=false -lock-timeout=10m -out=\"${cluster_artifact}\"" \
  cluster-plan
assert_not_contains "${cluster_plan}" "terraform apply " cluster-plan
assert_contains "${cluster_apply}" \
  "terraform apply -input=false -lock-timeout=10m \"${cluster_artifact}\"" \
  cluster-apply
assert_not_contains "${cluster_apply}" "terraform plan " cluster-apply
assert_not_contains "${cluster_apply}" "-auto-approve" cluster-apply
assert_contains "${cluster_alias}" \
  "terraform plan -input=false -lock-timeout=10m -out=\"${cluster_artifact}\"" \
  cluster-alias

printf 'Make saved-plan workflow tests: OK\n'
