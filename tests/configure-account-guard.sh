#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/repo"
MOCK_BIN="$TMP/bin"
CALL_LOG="$TMP/aws-calls"
MUTATION_LOG="$TMP/aws-mutations"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/terraform/live/eks" \
  "$FIXTURE/k8s" "$FIXTURE/docker" "$MOCK_BIN"
cp "$ROOT/scripts/configure.sh" "$FIXTURE/scripts/configure.sh"

cat >"$FIXTURE/terraform/live/eks/variables.tf" <<'EOF'
variable "gpu_count" {
  default = 8
}
EOF
cat >"$FIXTURE/k8s/workflow-base-train.yaml" <<'EOF'
resources:
  limits:
    nvidia.com/gpu: 8
EOF
cat >"$FIXTURE/docker/entrypoint.sh" <<'EOF'
NPROC="${NPROC:=8}"
EOF

cat >"$MOCK_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$AWS_CALL_LOG"
case "$1 $2" in
  "sts get-caller-identity")
    case " $* " in
      *" --query Account "*) printf '%s\n' "$MOCK_ACCOUNT" ;;
      *" --query Arn "*) printf 'arn:aws:iam::%s:user/test\n' "$MOCK_ACCOUNT" ;;
      *) exit 2 ;;
    esac
    ;;
  "s3api head-bucket")
    exit 0
    ;;
  "s3api get-bucket-location")
    printf 'None\n'
    ;;
  "s3api create-bucket"|"s3api put-bucket-versioning"|"s3api put-public-access-block"|"s3api put-bucket-policy")
    printf '%s\n' "$*" >>"$AWS_MUTATION_LOG"
    ;;
  *)
    printf 'unexpected mock aws call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$MOCK_BIN/aws"

export PATH="$MOCK_BIN:$PATH"
export AWS_CALL_LOG="$CALL_LOG"
export AWS_MUTATION_LOG="$MUTATION_LOG"
export MOCK_ACCOUNT=111122223333
unset EXPECTED_ACCOUNT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_configure() {
  (
    cd "$FIXTURE"
    bash scripts/configure.sh "$@"
  )
}

: >"$CALL_LOG"
: >"$MUTATION_LOG"
if run_configure --region test-region-1 >/dev/null 2>"$TMP/missing.err"; then
  fail "missing expected account was accepted"
fi
grep -q 'intended 12-digit AWS account ID' "$TMP/missing.err" \
  || fail "missing-account error was not actionable"
[ ! -s "$CALL_LOG" ] || fail "missing expected account reached AWS"

: >"$CALL_LOG"
: >"$MUTATION_LOG"
if run_configure --region test-region-1 --expected-account 1234 >/dev/null 2>"$TMP/invalid.err"; then
  fail "invalid expected account was accepted"
fi
[ ! -s "$CALL_LOG" ] || fail "invalid expected account reached AWS"

: >"$CALL_LOG"
: >"$MUTATION_LOG"
if EXPECTED_ACCOUNT=111122223333 run_configure --region test-region-1 \
  --expected-account 999900001111 >/dev/null 2>"$TMP/ambiguous.err"; then
  fail "conflicting account declarations were accepted"
fi
grep -q 'name different accounts' "$TMP/ambiguous.err" \
  || fail "conflicting-account error was not actionable"
[ ! -s "$CALL_LOG" ] || fail "conflicting account declarations reached AWS"

: >"$CALL_LOG"
: >"$MUTATION_LOG"
if run_configure --region test-region-1 --expected-account 999900001111 \
  >/dev/null 2>"$TMP/mismatch.err"; then
  fail "account mismatch was accepted"
fi
grep -q 'credentials resolve to account 111122223333, expected 999900001111' \
  "$TMP/mismatch.err" || fail "account-mismatch error omitted both identities"
[ ! -s "$MUTATION_LOG" ] || fail "account mismatch issued a mutating AWS call"
[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" = 1 ] \
  || fail "account mismatch did not stop immediately after STS"

: >"$CALL_LOG"
: >"$MUTATION_LOG"
run_configure --region test-region-1 --expected-account "$MOCK_ACCOUNT" \
  >/dev/null 2>"$TMP/match.err"
grep -q '^EXPECTED_ACCOUNT=111122223333$' "$FIXTURE/config.env" \
  || fail "matching account was not persisted"
grep -q '^s3api put-bucket-versioning ' "$MUTATION_LOG" \
  || fail "matching account did not proceed to bucket hardening"
grep -q '^s3api put-public-access-block ' "$MUTATION_LOG" \
  || fail "matching account did not enable public access blocking"
grep -q '^s3api put-bucket-policy ' "$MUTATION_LOG" \
  || fail "matching account did not enforce the TLS-only policy"

rm -f "$FIXTURE/config.env"
rm -rf "$FIXTURE/terraform/live/foundation"
: >"$CALL_LOG"
: >"$MUTATION_LOG"
EXPECTED_ACCOUNT="$MOCK_ACCOUNT" run_configure --region test-region-1 --dry-run \
  >"$TMP/dry-run.out" 2>"$TMP/dry-run.err"
[ ! -s "$MUTATION_LOG" ] || fail "dry-run issued a mutating AWS call"
[ ! -e "$FIXTURE/config.env" ] || fail "dry-run wrote config.env"
grep -q '^EXPECTED_ACCOUNT=111122223333$' "$TMP/dry-run.out" \
  || fail "dry-run output omitted the asserted account"

printf 'configure account guard tests: OK\n'
