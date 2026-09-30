#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

GH_BIN=${GH_BIN:-gh}
GIT_BIN=${GIT_BIN:-git}
readonly RELEASE_STABLE_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

release_error() {
  printf 'GitHub Release error: %s\n' "$*" >&2
  return 1
}

verify_remote_tag() {
  local repository=$1 tag=$2 expected_sha=$3 output direct peeled resolved
  local tag_ref="refs/tags/${tag}" peeled_ref="refs/tags/${tag}^{}"
  if ! output=$($GIT_BIN ls-remote --exit-code \
      "https://github.com/${repository}.git" "$tag_ref" "$peeled_ref" 2>&1); then
    release_error "remote Git tag ${tag} does not exist"
    return 1
  fi
  direct=$(awk -v ref="$tag_ref" '$2 == ref {print $1}' <<<"$output")
  peeled=$(awk -v ref="$peeled_ref" '$2 == ref {print $1}' <<<"$output")
  resolved=${peeled:-$direct}
  [[ $resolved =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] || {
    release_error "could not peel remote Git tag ${tag} to a commit"
    return 1
  }
  [[ ${resolved,,} == "${expected_sha,,}" ]] || {
    release_error "remote Git tag ${tag} resolves to ${resolved}, expected ${expected_sha}"
    return 1
  }
}

api_get() {
  local endpoint=$1 error_file output status
  error_file=$(mktemp)
  if output=$($GH_BIN api "$endpoint" 2>"$error_file"); then
    rm -f "$error_file"
    printf '%s\n' "$output"
    return 0
  else
    status=$?
  fi
  if grep -Eq 'HTTP 404|Not Found' "$error_file"; then
    rm -f "$error_file"
    return 44
  fi
  printf 'GitHub API request failed for %s: ' "$endpoint" >&2
  cat "$error_file" >&2
  rm -f "$error_file"
  return "$status"
}

get_release_by_tag() {
  api_get "repos/$1/releases/tags/$2"
}

get_latest_release() {
  api_get "repos/$1/releases/latest"
}

verify_release_association() {
  local repository=$1 tag=$2 release_json actual_tag
  release_json=$(get_release_by_tag "$repository" "$tag") || return 1
  actual_tag=$(jq -er '.tag_name' <<<"$release_json") || return 1
  [[ $actual_tag == "$tag" ]] || {
    release_error "Release lookup for ${tag} returned tag ${actual_tag}"
    return 1
  }
}

patch_latest_only() {
  local repository=$1 release_id=$2 make_latest=$3
  [[ $make_latest == true || $make_latest == false ]] || return 64
  printf '{"make_latest":"%s"}\n' "$make_latest" |
    $GH_BIN api --method PATCH \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      --input - "repos/${repository}/releases/${release_id}" >/dev/null
}

reconcile() {
  (($# == 5)) || {
    printf 'Usage: %s reconcile OWNER/REPO TAG SOURCE_SHA true|false EXPECTED_LATEST_TAG\n' "${0##*/}" >&2
    return 64
  }
  local repository=$1 tag=$2 source_sha=$3 latest_eligible=$4 expected_latest_tag=$5
  local release_json release_id actual_tag expected_json expected_id latest_json current_latest
  local release_exists=false expected_release_verified=false

  [[ -n ${GH_TOKEN:-} ]] || {
    release_error 'GH_TOKEN is required; the built-in Actions token is not a fallback'
    return 1
  }
  [[ $tag =~ $RELEASE_STABLE_RE ]] || release_error "invalid stable tag ${tag}" || return 1
  [[ $expected_latest_tag =~ $RELEASE_STABLE_RE ]] || release_error "invalid expected Latest tag ${expected_latest_tag}" || return 1
  [[ $source_sha =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] || release_error 'invalid source SHA' || return 1
  [[ $latest_eligible == true || $latest_eligible == false ]] || release_error 'latest_eligible must be true or false' || return 1
  if [[ $latest_eligible == true && $tag != "$expected_latest_tag" ]]; then
    release_error 'a Latest-eligible release must equal expected_latest_tag'
    return 1
  fi
  if [[ $latest_eligible == false && $tag == "$expected_latest_tag" ]]; then
    release_error 'a non-Latest release cannot equal expected_latest_tag'
    return 1
  fi

  verify_remote_tag "$repository" "$tag" "$source_sha"

  if [[ $latest_eligible == false ]]; then
    if expected_json=$(get_release_by_tag "$repository" "$expected_latest_tag"); then
      actual_tag=$(jq -er '.tag_name' <<<"$expected_json") || return 1
      expected_id=$(jq -er '.id' <<<"$expected_json") || return 1
      [[ $actual_tag == "$expected_latest_tag" ]] || release_error 'expected higher Release has the wrong tag association' || return 1
      expected_release_verified=true
    else
      release_error "expected higher Release ${expected_latest_tag} is missing; repair it before ${tag}"
      return 1
    fi
  fi

  if release_json=$(get_release_by_tag "$repository" "$tag"); then
    release_exists=true
    release_id=$(jq -er '.id' <<<"$release_json") || return 1
    actual_tag=$(jq -er '.tag_name' <<<"$release_json") || return 1
    [[ $actual_tag == "$tag" ]] || release_error "existing Release is associated with ${actual_tag}, not ${tag}" || return 1
  else
    status=$?
    [[ $status == 44 ]] || return "$status"
  fi

  if [[ $release_exists == false ]]; then
    # Close the window between the first tag check and Release creation. The
    # post-mutation check below detects deletion during the API operation.
    verify_remote_tag "$repository" "$tag" "$source_sha"
    if [[ $latest_eligible == true ]]; then
      $GH_BIN release create "$tag" --repo "$repository" --verify-tag \
        --title "$tag" --generate-notes --latest
    else
      [[ $expected_release_verified == true ]] || return 1
      $GH_BIN release create "$tag" --repo "$repository" --verify-tag \
        --title "$tag" --generate-notes --latest=false
    fi
  fi

  verify_remote_tag "$repository" "$tag" "$source_sha"
  release_json=$(get_release_by_tag "$repository" "$tag") || return 1
  release_id=$(jq -er '.id' <<<"$release_json") || return 1
  actual_tag=$(jq -er '.tag_name' <<<"$release_json") || return 1
  [[ $actual_tag == "$tag" ]] || release_error "final Release association is ${actual_tag}, expected ${tag}" || return 1

  if latest_json=$(get_latest_release "$repository"); then
    current_latest=$(jq -er '.tag_name' <<<"$latest_json") || return 1
  else
    status=$?
    [[ $status == 44 ]] || return "$status"
    current_latest=''
  fi

  if [[ $current_latest != "$expected_latest_tag" ]]; then
    if [[ $latest_eligible == true ]]; then
      patch_latest_only "$repository" "$release_id" true
    else
      [[ $expected_release_verified == true ]] || return 1
      patch_latest_only "$repository" "$expected_id" true
      patch_latest_only "$repository" "$release_id" false
    fi
  fi

  verify_remote_tag "$repository" "$tag" "$source_sha"
  verify_release_association "$repository" "$tag"
  latest_json=$(get_latest_release "$repository") || {
    release_error 'GitHub has no Latest Release after reconciliation'
    return 1
  }
  current_latest=$(jq -er '.tag_name' <<<"$latest_json") || return 1
  [[ $current_latest == "$expected_latest_tag" ]] || {
    release_error "GitHub Latest is ${current_latest}, expected ${expected_latest_tag}"
    return 1
  }
}

main() {
  (($# >= 1)) || {
    printf 'Usage: %s reconcile ...\n' "${0##*/}" >&2
    exit 64
  }
  local command=$1
  shift
  case $command in
    reconcile) reconcile "$@" ;;
    *) printf 'Unknown command: %s\n' "$command" >&2; exit 64 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
