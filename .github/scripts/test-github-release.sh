#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HELPER=${HELPER:-"${SCRIPT_DIR}/github-release.sh"}
[[ -x $HELPER ]] || {
  printf 'GitHub Release helper is missing: %s\n' "$HELPER" >&2
  exit 1
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
STATE_DIR=$TEST_DIR/state
mkdir -p "$STATE_DIR"
GH_LOG=$TEST_DIR/gh.log
GIT_LOG=$TEST_DIR/git.log
FAKE_GH=$TEST_DIR/gh
FAKE_GIT=$TEST_DIR/git

cat >"$FAKE_GIT" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GIT_LOG"
[[ $1 == ls-remote && $2 == --exit-code ]] || exit 90
count_file=$STATE_DIR/git-count
count=0
[[ ! -f $count_file ]] || read -r count <"$count_file"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [[ ${GIT_TAG_MODE:-valid} == missing ]]; then exit 2; fi
if [[ ${GIT_TAG_MODE:-valid} == delete_after_second && $count -gt 2 ]]; then exit 2; fi
sha=${REMOTE_SHA:-1111111111111111111111111111111111111111}
tag=${@: -2:1}
tag=${tag#refs/tags/}
if [[ ${GIT_TAG_MODE:-valid} == mismatch ]]; then
  sha=2222222222222222222222222222222222222222
fi
if [[ ${GIT_TAG_MODE:-valid} == annotated ]]; then
  printf '%s\trefs/tags/%s\n' 3333333333333333333333333333333333333333 "$tag"
  printf '%s\trefs/tags/%s^{}\n' "$sha" "$tag"
else
  printf '%s\trefs/tags/%s\n' "$sha" "$tag"
fi
FAKE_GIT

cat >"$FAKE_GH" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [[ ${GH_FAILURE:-} == 403 || ${GH_FAILURE:-} == 404 ]]; then
  printf 'HTTP %s: Resource not accessible by personal access token\n' "$GH_FAILURE" >&2
  exit 1
fi
if [[ ${1:-} == api && -n ${GH_API_EXIT_STATUS:-} ]]; then
  printf 'simulated gh api transport failure\n' >&2
  exit "$GH_API_EXIT_STATUS"
fi

release_file() {
  printf '%s/release-%s' "$STATE_DIR" "${1//[^A-Za-z0-9]/_}"
}

if [[ $1 == release && $2 == create ]]; then
  tag=$3
  printf '%s\n' "$*" >>"$STATE_DIR/create-args"
  file=$(release_file "$tag")
  printf '%s %s\n' "${NEXT_ID:-99}" "$tag" >"$file"
  for argument in "$@"; do
    [[ $argument != --latest ]] || printf '%s\n' "$tag" >"$STATE_DIR/latest"
  done
  exit 0
fi

[[ $1 == api ]] || exit 90
shift
method=GET
endpoint=''
while (($#)); do
  case $1 in
    --method) method=$2; shift 2 ;;
    -H) shift 2 ;;
    --input) shift 2 ;;
    repos/*) endpoint=$1; shift ;;
    *) shift ;;
  esac
done

if [[ $method == GET && $endpoint == */releases/tags/* ]]; then
  tag=${endpoint##*/}
  file=$(release_file "$tag")
  if [[ ! -f $file ]]; then
    printf 'HTTP 404: Not Found\n' >&2
    exit 1
  fi
  read -r id stored_tag <"$file"
  printf '{"id":%s,"tag_name":"%s"}\n' "$id" "$stored_tag"
elif [[ $method == GET && $endpoint == */releases/latest ]]; then
  [[ -s $STATE_DIR/latest ]] || { printf 'HTTP 404: Not Found\n' >&2; exit 1; }
  read -r tag <"$STATE_DIR/latest"
  printf '{"tag_name":"%s"}\n' "$tag"
elif [[ $method == PATCH && $endpoint == */releases/* ]]; then
  id=${endpoint##*/}
  body=$(cat)
  printf '%s\t%s\n' "$id" "$body" >>"$STATE_DIR/patches"
  tag=''
  for file in "$STATE_DIR"/release-*; do
    [[ -f $file ]] || continue
    read -r candidate_id candidate_tag <"$file"
    [[ $candidate_id == "$id" ]] && tag=$candidate_tag
  done
  [[ -n $tag ]] || { printf 'HTTP 404: Not Found\n' >&2; exit 1; }
  value=$(jq -er '.make_latest' <<<"$body")
  [[ $(jq -r 'keys | join(",")' <<<"$body") == make_latest ]] || exit 91
  if [[ $value == true ]]; then
    printf '%s\n' "$tag" >"$STATE_DIR/latest"
  elif [[ $value == false ]]; then
    if [[ -s $STATE_DIR/latest ]] && [[ $(<"$STATE_DIR/latest") == "$tag" ]]; then
      : >"$STATE_DIR/latest"
    fi
  else
    exit 92
  fi
  printf '{"id":%s,"tag_name":"%s"}\n' "$id" "$tag"
else
  printf 'unexpected endpoint: %s %s\n' "$method" "$endpoint" >&2
  exit 90
fi
FAKE_GH
chmod +x "$FAKE_GH" "$FAKE_GIT"

export GH_BIN=$FAKE_GH GIT_BIN=$FAKE_GIT STATE_DIR GH_LOG GIT_LOG
export GH_TOKEN=test-token
export REMOTE_SHA=1111111111111111111111111111111111111111
# shellcheck source-path=SCRIPTDIR
# shellcheck source=github-release.sh
source "$HELPER"
REPO=TitleCardMaker/TitleCardMaker

reset_state() {
  rm -f "$STATE_DIR"/* "$GH_LOG" "$GIT_LOG"
  : >"$GH_LOG"
  : >"$GIT_LOG"
  unset GH_FAILURE
  export GIT_TAG_MODE=valid
}

add_release() {
  local tag=$1 id=$2 latest=${3:-false}
  printf '%s %s\n' "$id" "$tag" >"$STATE_DIR/release-${tag//[^A-Za-z0-9]/_}"
  [[ $latest == true ]] && printf '%s\n' "$tag" >"$STATE_DIR/latest"
  return 0
}

run_reconcile() {
  "$HELPER" reconcile "$REPO" "$1" "$REMOTE_SHA" "$2" "$3"
}

# A: newest patch and B: new major are created explicitly as Latest.
for newest in v2.17.2 v3.0.0; do
  reset_state
  add_release v2.17.1 10 true
  run_reconcile "$newest" true "$newest"
  grep -F -- '--verify-tag' "$STATE_DIR/create-args" >/dev/null || fail 'create omitted --verify-tag'
  grep -F -- '--latest' "$STATE_DIR/create-args" >/dev/null || fail 'newest release was not explicitly Latest'
  ! grep -F -- '--target' "$STATE_DIR/create-args" >/dev/null || fail 'create used forbidden --target'
  [[ $(<"$STATE_DIR/latest") == "$newest" ]] || fail "${newest} did not become Latest"
done

# C/D/F: late backports are created explicitly non-Latest.
for case_data in 'v2.18.0 v3.0.0' 'v2.16.11 v2.17.2'; do
  read -r backport expected_latest <<<"$case_data"
  reset_state
  add_release "$expected_latest" 20 true
  run_reconcile "$backport" false "$expected_latest"
  grep -F -- '--latest=false' "$STATE_DIR/create-args" >/dev/null || fail 'backport was not explicitly non-Latest'
  [[ $(<"$STATE_DIR/latest") == "$expected_latest" ]] || fail 'backport displaced the higher Latest release'
done

# E: missing or mismatched tags stop before any Release mutation.
for tag_mode in missing mismatch; do
  reset_state
  export GIT_TAG_MODE=$tag_mode
  if run_reconcile v2.17.2 true v2.17.2 >/dev/null 2>&1; then
    fail "reconcile accepted ${tag_mode} remote tag"
  fi
  ! grep -F 'release create' "$GH_LOG" >/dev/null || fail "${tag_mode} tag caused Release creation"
done

# Annotated tags are peeled to their commit.
reset_state
export GIT_TAG_MODE=annotated
run_reconcile v2.17.2 true v2.17.2

# G: restore the higher release using PATCH bodies containing only make_latest.
reset_state
add_release v3.0.0 30 false
add_release v2.18.0 31 true
run_reconcile v2.18.0 false v3.0.0
[[ $(<"$STATE_DIR/latest") == v3.0.0 ]] || fail 'wrong Latest state was not repaired'
[[ $(wc -l <"$STATE_DIR/patches") -eq 2 ]] || fail 'Latest repair did not make two explicit PATCHes'
while IFS=$'\t' read -r _ body; do
  [[ $(jq -r 'keys | join(",")' <<<"$body") == make_latest ]] || fail 'PATCH altered unrelated metadata'
done <"$STATE_DIR/patches"

# Already-correct state is idempotent.
reset_state
add_release v3.0.0 40 true
run_reconcile v3.0.0 true v3.0.0
[[ ! -e $STATE_DIR/patches ]] || fail 'idempotent reconciliation issued a PATCH'
[[ ! -e $STATE_DIR/create-args ]] || fail 'idempotent reconciliation recreated a Release'

# A missing expected higher Release fails before creating a backport Release.
reset_state
if run_reconcile v2.18.0 false v3.0.0 >/dev/null 2>&1; then
  fail 'reconcile accepted a missing expected higher Release'
fi
[[ ! -e $STATE_DIR/create-args ]] || fail 'backport was created before expected Latest was verified'

# Tag deletion during the operation is detected after mutation.
reset_state
export GIT_TAG_MODE=delete_after_second
if run_reconcile v2.17.2 true v2.17.2 >/dev/null 2>&1; then
  fail 'reconcile missed tag deletion during operation'
fi

# Permission failures are fatal, including a deliberately ambiguous 404.
for failure_code in 403 404; do
  reset_state
  export GH_FAILURE=$failure_code
  if run_reconcile v2.17.2 true v2.17.2 >/dev/null 2>&1; then
    fail "reconcile ignored a ${failure_code} response"
  fi
done

# GH_TOKEN is mandatory; GITHUB_TOKEN is never a fallback.
reset_state
unset GH_TOKEN
export GITHUB_TOKEN=built-in-token
if run_reconcile v2.17.2 true v2.17.2 >/dev/null 2>&1; then
  fail 'reconcile fell back to GITHUB_TOKEN'
fi
[[ ! -s $GH_LOG ]] || fail 'gh was invoked without GH_TOKEN'
unset GITHUB_TOKEN

# Non-404 gh api errors preserve the original command status.
reset_state
export GH_API_EXIT_STATUS=37
api_error_output="$TEST_DIR/api-error"
if api_get "repos/$REPO/releases/latest" >/dev/null 2>"$api_error_output"; then
  fail 'api_get accepted a non-404 gh api failure'
else
  api_status=$?
fi
[[ $api_status -eq 37 ]] || fail "api_get returned ${api_status}, expected gh api status 37"
grep -F 'simulated gh api transport failure' "$api_error_output" >/dev/null || fail 'api_get omitted the gh api failure detail'
unset GH_API_EXIT_STATUS

printf 'All GitHub Release helper tests passed.\n'
