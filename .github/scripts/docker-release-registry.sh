#!/usr/bin/env bash
# Shared fail-closed registry inspection and copy functions. Authentication is
# intentionally performed by the calling workflow, never by this library.
set -uo pipefail
export LC_ALL=C

REGCTL_BIN=${REGCTL_BIN:-regctl}
TAG_SHA_RESOLVER=${TAG_SHA_RESOLVER:-}
TAG_SOURCE_VERSION_RESOLVER=${TAG_SOURCE_VERSION_RESOLVER:-}
readonly REGISTRY_STABLE_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

quarantined_release() {
  # This Git tag points to source with backend/.version=v2.16.5. Never use it
  # for publication, repair, or promotion, even if a registry lists it.
  case $1 in
    v2.16.1) return 0 ;;
    *) return 1 ;;
  esac
}

reject_quarantined_release() {
  (($# == 1)) || return 64
  if quarantined_release "$1"; then
    registry_error "${1} is quarantined: its tagged source reports v2.16.5"
    return 1
  fi
}

registry_error() {
  printf 'Registry error: %s\n' "$*" >&2
  return 1
}

registry_tag_state() {
  (($# == 1)) || return 64
  local ref=$1 output
  if output=$($REGCTL_BIN manifest head "$ref" 2>&1); then
    if [[ ! $output =~ ^sha256:[0-9a-f]{64}$ ]]; then
      registry_error "malformed manifest-head response for ${ref}"
      return 1
    fi
    printf 'present\n'
    return 0
  fi

  if [[ $output == *'manifest unknown'* ||
        $output == *'MANIFEST_UNKNOWN'* ||
        $output == *'request failed: not found [http 404]'* ]]; then
    printf 'absent\n'
    return 0
  fi
  registry_error "unable to determine whether ${ref} exists: ${output}"
}

stable_exact_preflight() {
  (($# == 2)) || return 64
  local gh_ref=$1 docker_ref=$2 gh_state docker_state
  gh_state=$(registry_tag_state "$gh_ref") || return 1
  docker_state=$(registry_tag_state "$docker_ref") || return 1

  if [[ $gh_state == absent && $docker_state == absent ]]; then
    return 0
  fi

  printf 'Exact-tag preflight stopped publication: GHCR=%s DockerHub=%s. Use the repair workflow for a partial release; inspect an existing release before any further action.\n' \
    "$gh_state" "$docker_state" >&2
  return 1
}

# Repair may mirror the canonical GHCR release to Docker Hub, but registry
# labels and matching layer fingerprints do not prove that a Docker Hub-only
# image came from the tagged Git source. Refuse that direction unless a future
# repair path can verify independent provenance.
repair_exact_source_preflight() {
  (($# == 2)) || return 64
  local gh_state=$1 docker_state=$2
  case "${gh_state}/${docker_state}" in
    present/absent|present/present)
      return 0
      ;;
    absent/present)
      registry_error 'refusing to promote a DockerHub-only exact release into GHCR without trusted provenance'
      return 1
      ;;
    absent/absent)
      registry_error 'neither registry contains an exact release to repair; repair never builds'
      return 1
      ;;
    *)
      registry_error "unsafe exact-release repair state: GHCR=${gh_state} DockerHub=${docker_state}"
      return 1
      ;;
  esac
}

repository_from_ref() {
  local ref=${1%@*}
  local last=${ref##*/}
  if [[ $last != *:* ]]; then
    registry_error "reference must contain a tag or digest: ${1}"
    return 1
  fi
  printf '%s\n' "${ref%:*}"
}

release_fingerprint() {
  (($# == 4)) || return 64
  local ref=$1 expected_version=$2 expected_revision=$3 expected_source=$4
  local repository index_json platform manifest_json config_digest layers config_json
  local version revision source digest
  local -a descriptors
  declare -A platform_digest=()

  repository=$(repository_from_ref "$ref") || return 1
  if ! index_json=$($REGCTL_BIN manifest get "$ref" --format raw-body 2>&1); then
    registry_error "could not read release index ${ref}: ${index_json}"
    return 1
  fi
  if ! jq -e '
      (.schemaVersion == 2) and
      (.manifests | type == "array") and
      ([.manifests[] |
        if (.platform.os == "linux" and
            (.platform.architecture == "amd64" or .platform.architecture == "arm64") and
            ((.platform.variant // "") == "")) then
          "runnable"
        elif (.platform.os == "unknown" and
              .platform.architecture == "unknown" and
              .annotations["vnd.docker.reference.type"] == "attestation-manifest") then
          "attestation"
        else
          "unexpected"
        end] | all(. != "unexpected"))
    ' >/dev/null 2>&1 <<<"$index_json"; then
    registry_error "${ref} is not an acceptable two-platform image index"
    return 1
  fi

  mapfile -t descriptors < <(jq -r '
    .manifests[] |
    select(.platform.os == "linux" and
           (.platform.architecture == "amd64" or .platform.architecture == "arm64") and
           ((.platform.variant // "") == "")) |
    [.platform.architecture, .digest] | @tsv
  ' <<<"$index_json")
  ((${#descriptors[@]} == 2)) || {
    registry_error "${ref} must contain exactly linux/amd64 and linux/arm64"
    return 1
  }
  for descriptor in "${descriptors[@]}"; do
    IFS=$'\t' read -r platform digest <<<"$descriptor"
    [[ -z ${platform_digest[$platform]+x} ]] || {
      registry_error "${ref} contains duplicate linux/${platform} entries"
      return 1
    }
    platform_digest[$platform]=$digest
  done
  [[ -n ${platform_digest[amd64]:-} && -n ${platform_digest[arm64]:-} ]] || {
    registry_error "${ref} is missing a required runnable platform"
    return 1
  }

  for platform in amd64 arm64; do
    digest=${platform_digest[$platform]}
    if ! manifest_json=$($REGCTL_BIN manifest get "${repository}@${digest}" --format raw-body 2>&1); then
      registry_error "could not read linux/${platform} manifest for ${ref}: ${manifest_json}"
      return 1
    fi
    if ! config_digest=$(jq -er '.config.digest | select(type == "string" and startswith("sha256:"))' <<<"$manifest_json") ||
       ! layers=$(jq -er '[.layers[].digest | select(type == "string" and startswith("sha256:"))] | select(length > 0) | join(",")' <<<"$manifest_json"); then
      registry_error "malformed linux/${platform} manifest for ${ref}"
      return 1
    fi
    if ! config_json=$($REGCTL_BIN image config "${repository}@${digest}" --format raw-body 2>&1); then
      registry_error "could not read linux/${platform} config for ${ref}: ${config_json}"
      return 1
    fi
    version=$(jq -er '.config.Labels["org.opencontainers.image.version"] // empty' <<<"$config_json") || {
      registry_error "linux/${platform} is missing the OCI version label"
      return 1
    }
    revision=$(jq -er '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"$config_json") || {
      registry_error "linux/${platform} is missing the OCI revision label"
      return 1
    }
    source=$(jq -er '.config.Labels["org.opencontainers.image.source"] // empty' <<<"$config_json") || {
      registry_error "linux/${platform} is missing the OCI source label"
      return 1
    }
    [[ $version == "$expected_version" ]] || registry_error "linux/${platform} version label is ${version}, expected ${expected_version}" || return 1
    [[ $revision == "$expected_revision" ]] || registry_error "linux/${platform} revision label is ${revision}, expected ${expected_revision}" || return 1
    [[ $source == "$expected_source" ]] || registry_error "linux/${platform} source label is ${source}, expected ${expected_source}" || return 1
    [[ $version != *$'\t'* && $revision != *$'\t'* && $source != *$'\t'* ]] || {
      registry_error "OCI labels must not contain tab characters"
      return 1
    }
    printf 'linux/%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$platform" "$config_digest" "$layers" "$version" "$revision" "$source"
  done
}

verify_release() {
  release_fingerprint "$@"
}

compare_releases() {
  (($# == 5)) || return 64
  local left=$1 right=$2 version=$3 revision=$4 source=$5
  local left_fingerprint right_fingerprint
  left_fingerprint=$(release_fingerprint "$left" "$version" "$revision" "$source") || return 1
  right_fingerprint=$(release_fingerprint "$right" "$version" "$revision" "$source") || return 1
  [[ $left_fingerprint == "$right_fingerprint" ]] || {
    registry_error "${left} and ${right} have divergent platform content"
    return 1
  }
}

resolve_tag_sha() {
  local tag=$1
  if [[ -n $TAG_SHA_RESOLVER ]]; then
    "$TAG_SHA_RESOLVER" "$tag"
  else
    git rev-parse --verify "refs/tags/${tag}^{commit}"
  fi
}

resolve_source_version() {
  (($# == 1)) || return 64
  local revision=$1
  if [[ -n $TAG_SOURCE_VERSION_RESOLVER ]]; then
    "$TAG_SOURCE_VERSION_RESOLVER" "$revision"
  else
    git show "${revision}:backend/.version"
  fi
}

registry_tags_json() {
  local repository=$1 output
  if ! output=$($REGCTL_BIN tag ls "$repository" --format '{{json .}}' 2>&1); then
    registry_error "could not list tags for ${repository}: ${output}"
    return 1
  fi
  jq -ce '
    (if type == "array" then . elif (.tags | type) == "array" then .tags else error("missing tags array") end)
    | if all(.[]; type == "string") then . else error("non-string registry tag") end
  ' <<<"$output" || {
    registry_error "malformed tag listing for ${repository}"
    return 1
  }
}

validated_tag_source_sha() {
  (($# == 1)) || return 64
  local tag=$1 revision source_version
  [[ $tag =~ $REGISTRY_STABLE_RE ]] || registry_error "invalid stable exact tag ${tag}" || return 1
  reject_quarantined_release "$tag" || return 1
  revision=$(resolve_tag_sha "$tag") || {
    registry_error "could not resolve Git tag ${tag}"
    return 1
  }
  source_version=$(resolve_source_version "$revision") || {
    registry_error "could not read backend/.version from Git commit ${revision} for tag ${tag}"
    return 1
  }
  if ! source_version=$(printf '%s' "$source_version" | tr -d '[:space:]'); then
    registry_error "could not normalize backend/.version at Git commit ${revision} for tag ${tag}"
    return 1
  fi
  [[ -n $source_version ]] || {
    registry_error "backend/.version is empty at Git commit ${revision} for tag ${tag}"
    return 1
  }
  [[ $source_version == "$tag" ]] || {
    registry_error "backend/.version at Git commit ${revision} is ${source_version}, expected ${tag}"
    return 1
  }
  printf '%s\n' "$revision"
}

# Validate every strict exact tag visible in either registry. Only the named
# historical quarantine is skipped; every other provenance failure is fatal.
validated_release_inventory() {
  (($# == 3)) || return 64
  local gh_repository=$1 docker_repository=$2 expected_source=$3
  local gh_json docker_json candidates tag revision gh_ref docker_ref location
  local gh_present docker_present
  local -a records=()
  gh_json=$(registry_tags_json "$gh_repository") || return 1
  docker_json=$(registry_tags_json "$docker_repository") || return 1
  candidates=$(jq -nr --argjson gh "$gh_json" --argjson docker "$docker_json" \
    '[$gh[], $docker[]] | unique[]') || {
    registry_error 'could not calculate the registry exact-tag inventory'
    return 1
  }
  while IFS= read -r tag; do
    [[ $tag =~ $REGISTRY_STABLE_RE ]] || continue
    if quarantined_release "$tag"; then
      printf 'Warning: excluding quarantined historical stable release %s from validated inventory and promotion decisions; tagged source reports backend/.version=v2.16.5\n' \
        "$tag" >&2
      continue
    fi
    revision=$(validated_tag_source_sha "$tag") || return 1
    gh_ref="${gh_repository}:${tag}"
    docker_ref="${docker_repository}:${tag}"
    gh_present=false docker_present=false
    if jq -e --arg tag "$tag" 'index($tag) != null' >/dev/null <<<"$gh_json"; then
      gh_present=true
      verify_release "$gh_ref" "$tag" "$revision" "$expected_source" >/dev/null || return 1
    fi
    if jq -e --arg tag "$tag" 'index($tag) != null' >/dev/null <<<"$docker_json"; then
      docker_present=true
      verify_release "$docker_ref" "$tag" "$revision" "$expected_source" >/dev/null || return 1
    fi
    if [[ $gh_present == true && $docker_present == true ]]; then
      compare_releases "$gh_ref" "$docker_ref" "$tag" "$revision" "$expected_source" || return 1
      location=common
    elif [[ $gh_present == true ]]; then
      location=ghcr
    else
      location=docker
    fi
    records+=("${location}"$'\t'"${tag}")
  done <<<"$candidates"
  ((${#records[@]} == 0)) || printf '%s\n' "${records[@]}"
}

common_valid_exact_tags() {
  (($# == 3)) || return 64
  local inventory location tag
  inventory=$(validated_release_inventory "$@") || return 1
  while IFS=$'\t' read -r location tag; do
    [[ $location == common ]] && printf '%s\n' "$tag"
  done <<<"$inventory"
  return 0
}

promotion_candidates() {
  (($# == 4)) || return 64
  local current=$4 inventory location tag current_common=false
  local -a candidates=()
  [[ $current =~ $REGISTRY_STABLE_RE ]] || registry_error "invalid stable exact tag ${current}" || return 1
  reject_quarantined_release "$current" || return 1
  inventory=$(validated_release_inventory "$1" "$2" "$3") || return 1
  while IFS=$'\t' read -r location tag; do
    [[ -n $tag ]] || continue
    candidates+=("$tag")
    [[ $location == common && $tag == "$current" ]] && current_common=true
  done <<<"$inventory"
  [[ $current_common == true ]] || {
    registry_error "${current} is not a validated exact release in both registries"
    return 1
  }
  printf '%s\n' "${candidates[@]}"
}

registry_digest() {
  (($# == 1)) || return 64
  local digest
  digest=$("$REGCTL_BIN" image digest "$1") || {
    registry_error "could not resolve digest for ${1}"
    return 1
  }
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
    registry_error "invalid digest for ${1}"
    return 1
  }
  printf '%s\n' "$digest"
}

resolved_alias_target() {
  (($# >= 3)) || return 64
  local alias_ref=$1 expected_source=$2
  shift 2
  local repository candidate candidate_ref alias_state alias_digest candidate_state
  local candidate_digest matched='' revision
  repository=$(repository_from_ref "$alias_ref") || return 1
  for candidate in "$@"; do
    [[ $candidate =~ $REGISTRY_STABLE_RE ]] || registry_error "invalid promotion candidate ${candidate}" || return 1
    reject_quarantined_release "$candidate" || return 1
  done
  alias_state=$(registry_tag_state "$alias_ref") || return 1
  [[ $alias_state != absent ]] || return 0
  alias_digest=$(registry_digest "$alias_ref") || return 1
  for candidate in "$@"; do
    candidate_ref="${repository}:${candidate}"
    candidate_state=$(registry_tag_state "$candidate_ref") || return 1
    [[ $candidate_state != absent ]] || continue
    candidate_digest=$(registry_digest "$candidate_ref") || return 1
    [[ $alias_digest == "$candidate_digest" ]] || continue
    [[ -z $matched ]] || {
      registry_error "${alias_ref} matches multiple exact releases"
      return 1
    }
    matched=$candidate
  done
  [[ -n $matched ]] || {
    registry_error "${alias_ref} does not match a validated stable exact release"
    return 2
  }
  revision=$(validated_tag_source_sha "$matched") || return 1
  verify_release "${repository}:${matched}" "$matched" "$revision" "$expected_source" >/dev/null || return 1
  verify_alias "$alias_ref" "${repository}:${matched}" "$matched" "$revision" "$expected_source" || return 1
  printf '%s\n' "$matched"
}

guard_alias_promotion() {
  (($# >= 4)) || return 64
  local alias_ref=$1 proposed=$2 expected_source=$3
  shift 3
  local alias proposed_major proposed_minor candidate matched comparison
  local proposed_in_candidates=false
  [[ $proposed =~ $REGISTRY_STABLE_RE ]] || registry_error "invalid proposed release ${proposed}" || return 1
  proposed_major=${BASH_REMATCH[1]} proposed_minor=${BASH_REMATCH[2]}
  reject_quarantined_release "$proposed" || return 1
  alias=${alias_ref##*:}
  case $alias in
    "v${proposed_major}.${proposed_minor}"|"v${proposed_major}"|latest) ;;
    *) registry_error "${alias_ref} is not an alias of ${proposed}"; return 1 ;;
  esac
  for candidate in "$@"; do
    [[ $candidate != "$proposed" ]] || proposed_in_candidates=true
  done
  [[ $proposed_in_candidates == true ]] || registry_error "${proposed} is missing from promotion candidates" || return 1
  matched=$(resolved_alias_target "$alias_ref" "$expected_source" "$@") || return 1
  [[ -n $matched ]] || return 0
  case $alias in
    "v${proposed_major}.${proposed_minor}")
      [[ $matched =~ ^v${proposed_major}\.${proposed_minor}\.[0-9]+$ ]] || {
        registry_error "${alias_ref} points outside its minor series"
        return 1
      }
      ;;
    "v${proposed_major}")
      [[ $matched =~ ^v${proposed_major}\.[0-9]+\.[0-9]+$ ]] || {
        registry_error "${alias_ref} points outside its major series"
        return 1
      }
      ;;
  esac
  comparison=$("${BASH_SOURCE[0]%/*}/docker-semver-tags.sh" compare "$proposed" "$matched") || return 1
  [[ $comparison != -1 ]] || {
    registry_error "${alias_ref} already points to newer validated release ${matched}"
    return 1
  }
}

# Repair only: an unmatched alias is an ordering floor, never release evidence.
# The requested target must be an independently validated exact tag in both registries.
repair_alias_bootstrap_target() {
  (($# >= 6)) || return 64
  local alias_ref=$1 target=$2 gh_repository=$3 docker_repository=$4 expected_source=$5
  shift 5
  local alias=${alias_ref##*:} major minor candidate found=false status
  local repository index_json platform_digest config_json old_version old_revision target_revision comparison
  [[ $target =~ $REGISTRY_STABLE_RE ]] || registry_error "invalid bootstrap target ${target}" || return 1
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
  reject_quarantined_release "$target" || return 1
  case $alias in
    "v${major}.${minor}"|"v${major}"|latest) ;;
    *) registry_error "${alias_ref} is not an alias of ${target}"; return 1 ;;
  esac
  for candidate in "$@"; do
    [[ $candidate != "$target" ]] || found=true
  done
  [[ $found == true ]] || registry_error "${target} is missing from promotion candidates" || return 1

  local gh_state docker_state
  gh_state=$(registry_tag_state "${gh_repository}:${target}") || return 1
  docker_state=$(registry_tag_state "${docker_repository}:${target}") || return 1
  [[ $gh_state == present && $docker_state == present ]] || \
    registry_error "${target} must be present in both registries before bootstrap" || return 1
  target_revision=$(validated_tag_source_sha "$target") || return 1
  verify_release "${gh_repository}:${target}" "$target" "$target_revision" "$expected_source" >/dev/null || return 1
  verify_release "${docker_repository}:${target}" "$target" "$target_revision" "$expected_source" >/dev/null || return 1
  compare_releases "${gh_repository}:${target}" "${docker_repository}:${target}" \
    "$target" "$target_revision" "$expected_source" || return 1

  if resolved_alias_target "$alias_ref" "$expected_source" "$@" >/dev/null; then
    return 0 # Existing validated aliases still use guard_alias_promotion.
  else
    status=$?
    [[ $status == 2 ]] || return "$status"
  fi

  # Read the current alias's claimed version only to forbid a backwards move.
  # A missing Git tag, bad label, platform, or provenance stops migration.
  repository=$(repository_from_ref "$alias_ref") || return 1
  if ! index_json=$($REGCTL_BIN manifest get "$alias_ref" --format raw-body 2>&1); then
    registry_error "could not read existing alias ${alias_ref}: ${index_json}"
    return 1
  fi
  platform_digest=$(jq -er '
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64" and
      ((.platform.variant // "") == "")) | .digest] |
    if length == 1 then .[0] else error("ambiguous amd64 platform") end |
    select(type == "string" and startswith("sha256:"))
  ' <<<"$index_json") || registry_error "could not identify the version of ${alias_ref}" || return 1
  if ! config_json=$($REGCTL_BIN image config "${repository}@${platform_digest}" --format raw-body 2>&1); then
    registry_error "could not read existing alias config ${alias_ref}: ${config_json}"
    return 1
  fi
  old_version=$(jq -er '.config.Labels["org.opencontainers.image.version"] | select(type == "string")' \
    <<<"$config_json") || registry_error "${alias_ref} has no usable version label" || return 1
  [[ $old_version =~ $REGISTRY_STABLE_RE ]] || registry_error "${alias_ref} has invalid version ${old_version}" || return 1
  reject_quarantined_release "$old_version" || return 1
  case $alias in
    "v${major}.${minor}") [[ $old_version =~ ^v${major}\.${minor}\.[0-9]+$ ]] ;;
    "v${major}") [[ $old_version =~ ^v${major}\.[0-9]+\.[0-9]+$ ]] ;;
    latest) true ;;
  esac || registry_error "${alias_ref} points outside its release series" || return 1
  old_revision=$(validated_tag_source_sha "$old_version") || return 1
  verify_release "$alias_ref" "$old_version" "$old_revision" "$expected_source" >/dev/null || return 1
  comparison=$("${BASH_SOURCE[0]%/*}/docker-semver-tags.sh" compare "$target" "$old_version") || return 1
  [[ $comparison == 1 ]] || registry_error "${alias_ref} is not older than ${target}" || return 1
  printf '%s\n' "$target"
}

validated_common_latest_target() {
  (($# >= 4)) || return 64
  local gh_repository=$1 docker_repository=$2 expected_source=$3
  shift 3
  local gh_target docker_target revision
  gh_target=$(resolved_alias_target "${gh_repository}:latest" "$expected_source" "$@") || return 1
  docker_target=$(resolved_alias_target "${docker_repository}:latest" "$expected_source" "$@") || return 1
  [[ -n $gh_target && $gh_target == "$docker_target" ]] || {
    registry_error 'latest aliases are missing or do not resolve to the same validated exact release'
    return 1
  }
  revision=$(validated_tag_source_sha "$gh_target") || return 1
  compare_releases "${gh_repository}:${gh_target}" "${docker_repository}:${gh_target}" \
    "$gh_target" "$revision" "$expected_source" || return 1
  printf '%s\n' "$gh_target"
}

latest_decision() {
  (($# >= 6)) || return 64
  local gh_repository=$1 docker_repository=$2 expected_source=$3 current=$4 promotions_file=$5
  shift 5
  local highest_verified expected_latest_tag latest_eligible=false
  [[ -r $promotions_file ]] || registry_error "cannot read promotions file ${promotions_file}" || return 1
  highest_verified=$(awk -F '\t' '$1 == "expected_latest" {print $2}' "$promotions_file")
  [[ $highest_verified =~ $REGISTRY_STABLE_RE ]] || registry_error 'promotions omitted the highest verified tag' || return 1
  if grep -Fqx $'promote\tlatest' "$promotions_file"; then
    [[ $highest_verified == "$current" ]] || registry_error 'latest promotion disagrees with verified tag ordering' || return 1
    expected_latest_tag=$current
  else
    expected_latest_tag=$(validated_common_latest_target \
      "$gh_repository" "$docker_repository" "$expected_source" "$@") || return 1
  fi
  [[ $expected_latest_tag != "$current" ]] || latest_eligible=true
  printf 'latest_eligible\t%s\nexpected_latest_tag\t%s\n' "$latest_eligible" "$expected_latest_tag"
}

copy_exact_by_digest() {
  (($# == 2)) || return 64
  local source_ref=$1 destination_ref=$2 source_repository digest
  source_repository=$(repository_from_ref "$source_ref") || return 1
  digest=$($REGCTL_BIN image digest "$source_ref") || return 1
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || registry_error "invalid source digest for ${source_ref}" || return 1
  $REGCTL_BIN image copy "${source_repository}@${digest}" "$destination_ref"
}

copy_alias_by_digest() {
  copy_exact_by_digest "$@"
}

verify_alias() {
  (($# == 5)) || return 64
  local alias_ref=$1 exact_ref=$2 version=$3 revision=$4 source=$5
  local alias_digest exact_digest
  alias_digest=$(registry_digest "$alias_ref") || return 1
  exact_digest=$(registry_digest "$exact_ref") || return 1
  [[ $alias_digest == "$exact_digest" ]] || {
    registry_error "${alias_ref} does not resolve to ${exact_ref} within its registry"
    return 1
  }
  verify_release "$alias_ref" "$version" "$revision" "$source" >/dev/null
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  (($# >= 1)) || {
    printf 'Usage: %s FUNCTION [ARG...]\n' "${0##*/}" >&2
    exit 64
  }
  function_name=$1
  shift
  case "$function_name" in
    registry_tag_state|stable_exact_preflight|release_fingerprint|verify_release|compare_releases|common_valid_exact_tags|promotion_candidates|guard_alias_promotion|validated_common_latest_target|latest_decision|reject_quarantined_release|copy_exact_by_digest|copy_alias_by_digest|verify_alias)
      "$function_name" "$@"
      ;;
    *)
      printf 'Unknown registry helper function: %s\n' "$function_name" >&2
      exit 64
      ;;
  esac
fi
