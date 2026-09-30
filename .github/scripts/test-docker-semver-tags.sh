#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HELPER=${HELPER:-"${SCRIPT_DIR}/docker-semver-tags.sh"}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_derive() {
  local tag=$1 expected=$2 actual
  actual=$($HELPER derive "$tag") || fail "derive rejected valid tag ${tag}"
  [[ $actual == "$expected" ]] || fail "unexpected derive output for ${tag}: ${actual}"
}

assert_rejected() {
  local tag=$1 output_file error_file
  output_file=$(mktemp)
  error_file=$(mktemp)
  if "$HELPER" derive "$tag" >"$output_file" 2>"$error_file"; then
    rm -f "$output_file" "$error_file"
    fail "derive accepted invalid tag ${tag}"
  fi
  [[ ! -s $output_file ]] || fail "derive emitted stdout for invalid tag ${tag}"
  [[ -s $error_file ]] || fail "derive emitted no diagnostic for invalid tag ${tag}"
  rm -f "$output_file" "$error_file"
}

assert_promotions() {
  local current=$1 expected=$2
  shift 2
  local actual
  actual=$($HELPER promotions "$current" "$@") || fail "promotions failed for ${current}"
  [[ $actual == "$expected" ]] || {
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
    fail "unexpected promotions for ${current}"
  }
}

derive_expected=$'exact\tv2.16.10\nminor\tv2.16\nmajor\tv2\nlatest\tlatest'
assert_derive v2.16.10 "$derive_expected"

for tag in \
  v0.0.0 v0.1.0 v1.0.0 v2.16.1 v2.16.9 v2.16.10 v2.17.0 \
  v3.0.0 v10.20.30
do
  "$HELPER" derive "$tag" >/dev/null || fail "derive rejected ${tag}"
done

for tag in \
  v01.2.3 v1.02.3 v1.2.03 v00.0.0 v1.0.0-rc.1 \
  v1.0.0-beta.1 v1.0.0+build 1.2.3 v1 v1.2 latest main develop invalid
do
  assert_rejected "$tag"
done

assert_promotions v2.16.10 \
  $'expected_latest\tv2.16.10\npromote\tv2.16\npromote\tv2\npromote\tlatest' \
  v2.16.8 v2.16.9 v2.16.10

assert_promotions v2.17.0 \
  $'expected_latest\tv2.17.0\npromote\tv2.17\npromote\tv2\npromote\tlatest' \
  v2.16.10 v2.17.0

assert_promotions v2.16.11 \
  $'expected_latest\tv2.17.2\npromote\tv2.16' \
  v2.17.2 v2.16.10 v2.16.11

assert_promotions v3.0.0 \
  $'expected_latest\tv3.0.0\npromote\tv3.0\npromote\tv3\npromote\tlatest' \
  v2.17.2 v3.0.0

assert_promotions v2.18.0 \
  $'expected_latest\tv3.0.0\npromote\tv2.18\npromote\tv2' \
  v3.0.0 v2.17.2 v2.18.0

# Duplicates are removed; malformed and prerelease candidates cannot affect
# ordering. The registry helper validates exact tags before calling this.
assert_promotions v2.16.10 \
  $'expected_latest\tv2.16.10\npromote\tv2.16\npromote\tv2\npromote\tlatest' \
  v2.16.9 v2.16.10 v2.16.10 invalid v3.0.0-rc.1

if "$HELPER" promotions v2.16.10 >/dev/null 2>&1; then
  fail 'promotions accepted an empty candidate set'
fi

if "$HELPER" promotions v2.16.10 v2.16.9 v2.17.0 >/dev/null 2>&1; then
  fail 'promotions accepted a common set that omitted the current tag'
fi

[[ $("$HELPER" compare v2.16.10 v2.16.9) == 1 ]] || fail 'numeric compare regressed patch 10 below patch 9'
[[ $("$HELPER" compare v2.16.9 v2.16.10) == -1 ]] || fail 'numeric compare missed an older patch'
[[ $("$HELPER" compare v3.0.0 v3.0.0) == 0 ]] || fail 'numeric compare missed equality'
if "$HELPER" compare v03.0.0 v3.0.0 >/dev/null 2>&1; then
  fail 'numeric compare accepted a noncanonical stable tag'
fi

printf 'All Docker SemVer helper tests passed.\n'
