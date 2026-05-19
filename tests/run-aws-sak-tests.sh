#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FIXTURE="$REPO_ROOT/tests/fixtures/aws-sak-cases.jsonl"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$TMPROOT/projects/aws-sak-test"
cp "$FIXTURE" "$TMPROOT/projects/aws-sak-test/cases.jsonl"

bash "$REPO_ROOT/scripts/redact-claude-history-secrets.sh" \
  --config-dir "$TMPROOT" --all --apply --quiet >/dev/null

OUT="$TMPROOT/projects/aws-sak-test/cases.jsonl"

fail=0
check() {
  local case_name="$1"
  local pattern="$2"
  local mode="$3"
  local actual_line
  actual_line="$(grep -F "\"case\":\"$case_name\"" "$OUT" || true)"
  if [[ -z "$actual_line" ]]; then
    printf 'FAIL [%s]: case line missing from output\n' "$case_name"
    fail=1
    return
  fi
  if [[ "$mode" == "match" ]]; then
    if grep -qF -- "$pattern" <<< "$actual_line"; then
      printf 'PASS [%s] contains %q\n' "$case_name" "$pattern"
    else
      printf 'FAIL [%s] expected to contain %q\n' "$case_name" "$pattern"
      printf '  got: %s\n' "$actual_line"
      fail=1
    fi
  else
    if grep -qF -- "$pattern" <<< "$actual_line"; then
      printf 'FAIL [%s] expected NOT to contain %q\n' "$case_name" "$pattern"
      printf '  got: %s\n' "$actual_line"
      fail=1
    else
      printf 'PASS [%s] does not contain %q\n' "$case_name" "$pattern"
    fi
  fi
}

# Level A: labeled aws_secret_access_key value is replaced regardless of surrounding chars
check "level-a-equals" "<AWS_SECRET_ACCESS_KEY>" "match"
check "level-a-equals" "wJalrXUtnFEMI" "no-match"
check "level-a-json" "<AWS_SECRET_ACCESS_KEY>" "match"
check "level-a-json" "wJalrXUtnFEMI" "no-match"
check "level-a-yaml" "<AWS_SECRET_ACCESS_KEY>" "match"
check "level-a-yaml" "wJalrXUtnFEMI" "no-match"

# Level B: bare 40-char base64-ish is replaced when AKIA/ASIA appears on the same line
check "level-b-pair" "<AWS_ACCESS_KEY_ID>" "match"
check "level-b-pair" "<AWS_SECRET_ACCESS_KEY>" "match"
check "level-b-pair" "AKIAIOSFODNN7EXAMPLE" "no-match"
check "level-b-pair" "wJalrXUtnFEMI" "no-match"

# Level B SHA1 hex exclusion: even with AKIA on the line, git hashes stay intact
check "level-b-sha1-excluded" "<AWS_ACCESS_KEY_ID>" "match"
check "level-b-sha1-excluded" "da39a3ee5e6b4b0d3255bfef95601890afd80709" "match"
check "level-b-sha1-excluded" "adc83b19e793491b1c6ea0fd8b46cd9f32e592fc" "match"
check "level-b-sha1-excluded" "<AWS_SECRET_ACCESS_KEY>" "no-match"

# JWT-only line still redacts as JWT and does not trigger SAK rules
check "negative-jwt-only" "<JWT>" "match"
check "negative-jwt-only" "<AWS_SECRET_ACCESS_KEY>" "no-match"

# Level A non-trigger: bare 40-char base64 without label or AKIA is left alone
check "negative-bare-40-no-akia" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "match"
check "negative-bare-40-no-akia" "<AWS_SECRET_ACCESS_KEY>" "no-match"

# Bare SHA1 without AKIA is left alone
check "negative-sha1-no-akia" "abc1234567890abcdef1234567890abcdef12345" "match"
check "negative-sha1-no-akia" "<AWS_SECRET_ACCESS_KEY>" "no-match"

if [[ "$fail" -eq 0 ]]; then
  echo "all checks passed"
  exit 0
fi

echo "some checks failed"
exit 1
