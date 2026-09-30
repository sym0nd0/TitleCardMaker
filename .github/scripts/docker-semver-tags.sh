#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

readonly EX_USAGE=64
readonly EX_DATAERR=65
readonly STABLE_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

usage() {
  printf 'Usage: %s derive TAG | promotions CURRENT VERIFIED_TAG... | compare LEFT RIGHT\n' "${0##*/}" >&2
  exit "$EX_USAGE"
}

parse_stable() {
  local tag=$1
  if [[ ! $tag =~ $STABLE_RE ]]; then
    printf "Invalid stable release tag: '%s'\n" "$tag" >&2
    return "$EX_DATAERR"
  fi
  SEMVER_MAJOR=${BASH_REMATCH[1]}
  SEMVER_MINOR=${BASH_REMATCH[2]}
  SEMVER_PATCH=${BASH_REMATCH[3]}
}

numeric_gt() {
  local left=$1 right=$2
  if ((${#left} != ${#right})); then
    ((${#left} > ${#right}))
  else
    [[ $left > $right ]]
  fi
}

semver_gt() {
  local left=$1 right=$2
  local left_major left_minor left_patch right_major right_minor right_patch
  parse_stable "$left" >/dev/null
  left_major=$SEMVER_MAJOR left_minor=$SEMVER_MINOR left_patch=$SEMVER_PATCH
  parse_stable "$right" >/dev/null
  right_major=$SEMVER_MAJOR right_minor=$SEMVER_MINOR right_patch=$SEMVER_PATCH

  if [[ $left_major != "$right_major" ]]; then
    numeric_gt "$left_major" "$right_major"
  elif [[ $left_minor != "$right_minor" ]]; then
    numeric_gt "$left_minor" "$right_minor"
  elif [[ $left_patch != "$right_patch" ]]; then
    numeric_gt "$left_patch" "$right_patch"
  else
    return 1
  fi
}

derive() {
  (($# == 1)) || usage
  local tag=$1 major minor
  parse_stable "$tag" || return "$EX_DATAERR"
  major="v${SEMVER_MAJOR}"
  minor="${major}.${SEMVER_MINOR}"
  printf 'exact\t%s\nminor\t%s\nmajor\t%s\nlatest\tlatest\n' \
    "$tag" "$minor" "$major"
}

promotions() {
  (($# >= 2)) || {
    printf 'promotions requires CURRENT and at least one verified exact tag\n' >&2
    return "$EX_DATAERR"
  }

  local current=$1 candidate
  shift
  parse_stable "$current" || return "$EX_DATAERR"
  local current_major=$SEMVER_MAJOR current_minor=$SEMVER_MINOR
  local overall_max='' major_max='' minor_max='' current_found=false
  declare -A seen=()

  for candidate in "$@"; do
    if ! parse_stable "$candidate"; then
      printf "Ignoring non-stable candidate: '%s'\n" "$candidate" >&2
      continue
    fi
    [[ -z ${seen[$candidate]+x} ]] || continue
    seen[$candidate]=1
    [[ $candidate == "$current" ]] && current_found=true

    if [[ -z $overall_max ]] || semver_gt "$candidate" "$overall_max"; then
      overall_max=$candidate
    fi
    parse_stable "$candidate" >/dev/null
    if [[ $SEMVER_MAJOR == "$current_major" ]]; then
      if [[ -z $major_max ]] || semver_gt "$candidate" "$major_max"; then
        major_max=$candidate
      fi
      parse_stable "$candidate" >/dev/null
      if [[ $SEMVER_MINOR == "$current_minor" ]]; then
        if [[ -z $minor_max ]] || semver_gt "$candidate" "$minor_max"; then
          minor_max=$candidate
        fi
      fi
    fi
  done

  if [[ $current_found != true ]]; then
    printf "Current tag '%s' is not in the verified exact-tag set\n" "$current" >&2
    return "$EX_DATAERR"
  fi

  printf 'expected_latest\t%s\n' "$overall_max"
  [[ $current == "$minor_max" ]] && printf 'promote\tv%s.%s\n' "$current_major" "$current_minor"
  [[ $current == "$major_max" ]] && printf 'promote\tv%s\n' "$current_major"
  [[ $current == "$overall_max" ]] && printf 'promote\tlatest\n'
  return 0
}

compare() {
  (($# == 2)) || usage
  parse_stable "$1" || return "$EX_DATAERR"
  parse_stable "$2" || return "$EX_DATAERR"
  if semver_gt "$1" "$2"; then
    printf '1\n'
  elif semver_gt "$2" "$1"; then
    printf '%s\n' '-1'
  else
    printf '0\n'
  fi
}

main() {
  (($# >= 1)) || usage
  local command=$1
  shift
  case "$command" in
    derive) derive "$@" ;;
    promotions) promotions "$@" ;;
    compare) compare "$@" ;;
    *) usage ;;
  esac
}

main "$@"
