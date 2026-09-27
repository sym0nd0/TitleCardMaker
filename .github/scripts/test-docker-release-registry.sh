#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HELPER=${HELPER:-"${SCRIPT_DIR}/docker-release-registry.sh"}
[[ -r $HELPER ]] || {
  printf 'Registry helper is missing: %s\n' "$HELPER" >&2
  exit 1
}
# shellcheck source-path=SCRIPTDIR
# shellcheck source=docker-release-registry.sh
source "$HELPER"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"
}

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
FAKE_REGCTL="$TEST_DIR/regctl"
WRITE_LOG="$TEST_DIR/writes"
: >"$WRITE_LOG"

cat >"$FAKE_REGCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

repo_kind() {
  [[ $1 == ghcr.io/* ]] && printf gh || printf dh
}

index_digest() {
  if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
    printf 'sha256:%s' "$(printf '%s:%s' "$(repo_kind "$1")" "$(tag_from_ref "$1")" | sha256sum | cut -d' ' -f1)"
    return
  fi
  if [[ $(repo_kind "$1") == gh ]]; then
    printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  else
    printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  fi
}

state_for() {
  if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
    local tag=${1##*:} tags aliases target
    if [[ $(repo_kind "$1") == gh ]]; then
      tags=${GH_TAGS:-'{"tags":[]}'} aliases=${GH_ALIASES:-'{}'}
    else
      tags=${DH_TAGS:-'{"tags":[]}'} aliases=${DH_ALIASES:-'{}'}
    fi
    if [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      if jq -e --arg tag "$tag" '.tags | index($tag) != null' >/dev/null <<<"$tags"; then
        printf present
      else
        printf absent
      fi
      return
    fi
    target=$(jq -r --arg tag "$tag" '.[$tag] // empty' <<<"$aliases")
    case $target in
      '') printf absent ;;
      __auth__) printf auth ;;
      __timeout__) printf timeout ;;
      __malformed__) printf malformed ;;
      *) printf present ;;
    esac
    return
  fi
  if [[ $(repo_kind "$1") == gh ]]; then
    printf '%s' "${GH_STATE:-present}"
  else
    printf '%s' "${DH_STATE:-present}"
  fi
}

tag_from_ref() {
  local ref=${1%%@*}
  local tag=${ref##*:} aliases target
  if [[ ${FAKE_MULTI_RELEASE:-0} == 1 && ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if [[ $(repo_kind "$1") == gh ]]; then
      aliases=${GH_ALIASES:-'{}'}
    else
      aliases=${DH_ALIASES:-'{}'}
    fi
    target=$(jq -r --arg tag "$tag" '.[$tag] // empty' <<<"$aliases")
    [[ -z $target ]] || tag=$target
  fi
  printf '%s' "$tag"
}

command=$1
subcommand=$2
shift 2
case "${command} ${subcommand}" in
  'manifest head')
    ref=$1
    case $(state_for "$ref") in
      present) printf '%s\n' "$(index_digest "$ref")" ;;
      present_malformed) printf 'unexpected successful response\n' ;;
      absent) printf 'manifest unknown\n' >&2; exit 1 ;;
      absent404) printf 'request failed: not found [http 404]\n' >&2; exit 1 ;;
      auth) printf 'unauthorized: authentication required\n' >&2; exit 1 ;;
      timeout) printf 'context deadline exceeded\n' >&2; exit 1 ;;
      malformed) printf 'unexpected registry response\n' >&2; exit 1 ;;
    esac
    ;;
  'image digest')
    index_digest "$1"
    printf '\n'
    ;;
  'manifest get')
    ref=$1
    if [[ ${FAKE_MULTI_RELEASE:-0} == 1 && $ref == *@sha256:amd-* ]]; then
      tag=${ref##*amd-}
      printf '{"schemaVersion":2,"config":{"digest":"sha256:config-amd-%s"},"layers":[{"digest":"sha256:layer-amd-%s"}]}\n' "$tag" "$tag"
    elif [[ ${FAKE_MULTI_RELEASE:-0} == 1 && $ref == *@sha256:arm-* ]]; then
      tag=${ref##*arm-}
      printf '{"schemaVersion":2,"config":{"digest":"sha256:config-arm-%s"},"layers":[{"digest":"sha256:layer-arm-%s"}]}\n' "$tag" "$tag"
    elif [[ $ref == *@sha256:amd ]]; then
      layer=layer-amd
      [[ ${FAKE_MODE:-valid} == divergent && $(repo_kind "$ref") == dh ]] && layer=other-amd
      printf '{"schemaVersion":2,"config":{"digest":"sha256:config-amd"},"layers":[{"digest":"sha256:%s"}]}\n' "$layer"
    elif [[ $ref == *@sha256:arm ]]; then
      printf '{"schemaVersion":2,"config":{"digest":"sha256:config-arm"},"layers":[{"digest":"sha256:layer-arm"}]}\n'
    elif [[ $ref == *@sha256:extra ]]; then
      printf '{"schemaVersion":2,"config":{"digest":"sha256:config-extra"},"layers":[{"digest":"sha256:layer-extra"}]}\n'
    else
      tag=$(tag_from_ref "$ref")
      printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":['
      if [[ ${FAKE_MODE:-valid} != missing_platform ]]; then
        if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
          printf '{"digest":"sha256:amd-%s","platform":{"os":"linux","architecture":"amd64"}},' "$tag"
        else
          printf '{"digest":"sha256:amd","platform":{"os":"linux","architecture":"amd64"}},'
        fi
      fi
      if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
        printf '{"digest":"sha256:arm-%s","platform":{"os":"linux","architecture":"arm64"}}' "$tag"
      else
        printf '{"digest":"sha256:arm","platform":{"os":"linux","architecture":"arm64"}}'
      fi
      if [[ ${FAKE_MODE:-valid} == extra_platform ]]; then
        printf ',{"digest":"sha256:extra","platform":{"os":"linux","architecture":"s390x"}}'
      fi
      if [[ ${FAKE_MODE:-valid} == attestation ]]; then
        printf ',{"digest":"sha256:att","platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest"}}'
      fi
      printf ']}\n'
    fi
    ;;
  'image config')
    ref=$1
    if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
      tag=${ref##*-}
      version=$tag revision=$(printf '%s' "$tag" | sha1sum | cut -d' ' -f1)
    else
      tag=${RELEASE_TAG:-$(tag_from_ref "$ref")}
      version=$tag revision=${SOURCE_SHA:-1111111111111111111111111111111111111111}
    fi
    source=${SOURCE_URL:-https://github.com/TitleCardMaker/TitleCardMaker}
    case ${FAKE_MODE:-valid} in
      wrong_version) version=v9.9.9 ;;
      wrong_revision) revision=2222222222222222222222222222222222222222 ;;
      wrong_source) source=https://github.com/example/other ;;
      missing_labels) printf '{"config":{"Labels":{}}}\n'; exit 0 ;;
    esac
    printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s","org.opencontainers.image.revision":"%s","org.opencontainers.image.source":"%s"}}}\n' \
      "$version" "$revision" "$source"
    ;;
  'tag ls')
    if [[ $(repo_kind "$1") == gh ]]; then
      if [[ -n ${GH_TAGS:-} ]]; then printf '%s\n' "$GH_TAGS"; else printf '{"tags":[]}\n'; fi
    else
      if [[ -n ${DH_TAGS:-} ]]; then printf '%s\n' "$DH_TAGS"; else printf '{"tags":[]}\n'; fi
    fi
    ;;
  'image copy')
    printf '%s -> %s\n' "$1" "$2" >>"$WRITE_LOG"
    ;;
  *)
    printf 'unexpected fake regctl call: %s %s %s\n' "$command" "$subcommand" "$*" >&2
    exit 90
    ;;
esac
FAKE
chmod +x "$FAKE_REGCTL"

export REGCTL_BIN=$FAKE_REGCTL WRITE_LOG
export SOURCE_SHA=1111111111111111111111111111111111111111
export SOURCE_URL=https://github.com/TitleCardMaker/TitleCardMaker
export RELEASE_TAG=v2.16.10
GH_REF=ghcr.io/titlecardmaker/titlecardmaker:v2.16.10
DH_REF=example/titlecardmaker:v2.16.10

export GH_STATE=present DH_STATE=present FAKE_MODE=valid
assert_eq "$(registry_tag_state "$GH_REF")" present
GH_STATE=absent
assert_eq "$(registry_tag_state "$GH_REF")" absent
GH_STATE=absent404
assert_eq "$(registry_tag_state "$GH_REF")" absent

for bad_state in auth timeout malformed; do
  GH_STATE=$bad_state
  if registry_tag_state "$GH_REF" >/dev/null 2>&1; then
    fail "registry_tag_state accepted ${bad_state} as absence"
  fi
done
GH_STATE=present_malformed
if registry_tag_state "$GH_REF" >/dev/null 2>&1; then
  fail 'registry_tag_state accepted a malformed successful response'
fi

GH_STATE=absent DH_STATE=absent
stable_exact_preflight "$GH_REF" "$DH_REF"

for states in 'present absent' 'absent present' 'present present'; do
  read -r GH_STATE DH_STATE <<<"$states"
  export GH_STATE DH_STATE
  : >"$WRITE_LOG"
  if stable_exact_preflight "$GH_REF" "$DH_REF" >/dev/null 2>&1; then
    fail "preflight accepted ${states}"
  fi
  [[ ! -s $WRITE_LOG ]] || fail "failed preflight performed a write for ${states}"
done

GH_STATE=auth DH_STATE=absent
if stable_exact_preflight "$GH_REF" "$DH_REF" >/dev/null 2>&1; then
  fail 'preflight treated authentication failure as absence'
fi
[[ ! -s $WRITE_LOG ]] || fail 'authentication failure performed a write'

export GH_STATE=present DH_STATE=present FAKE_MODE=valid
verify_release "$GH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL" >/dev/null
FAKE_MODE=attestation verify_release "$GH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL" >/dev/null
compare_releases "$GH_REF" "$DH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL"

for mode in missing_labels wrong_revision wrong_version wrong_source missing_platform extra_platform; do
  export FAKE_MODE=$mode
  if verify_release "$GH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL" >/dev/null 2>&1; then
    fail "verify_release accepted ${mode}"
  fi
done

FAKE_MODE=divergent
if compare_releases "$GH_REF" "$DH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'compare_releases accepted divergent platform content'
fi

export FAKE_MODE=valid
: >"$WRITE_LOG"
copy_exact_by_digest "$GH_REF" "$DH_REF"
grep -Fx 'ghcr.io/titlecardmaker/titlecardmaker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> example/titlecardmaker:v2.16.10' "$WRITE_LOG" >/dev/null || \
  fail 'exact copy was not digest-qualified'

: >"$WRITE_LOG"
copy_alias_by_digest "$GH_REF" ghcr.io/titlecardmaker/titlecardmaker:v2.16
grep -Fx 'ghcr.io/titlecardmaker/titlecardmaker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> ghcr.io/titlecardmaker/titlecardmaker:v2.16' "$WRITE_LOG" >/dev/null || \
  fail 'alias copy was not digest-qualified'
verify_alias ghcr.io/titlecardmaker/titlecardmaker:v2.16 "$GH_REF" "$RELEASE_TAG" "$SOURCE_SHA" "$SOURCE_URL"

TAG_SHA_RESOLVER="$TEST_DIR/tag-sha"
cat >"$TAG_SHA_RESOLVER" <<'RESOLVER'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${TAG_SHA_STATE:-valid} == missing ]]; then
  printf 'tag resolution failed\n' >&2
  exit 1
fi
if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
  printf '%s' "$1" | sha1sum | cut -d' ' -f1
  exit 0
fi
printf '%s\n' "$SOURCE_SHA"
RESOLVER
chmod +x "$TAG_SHA_RESOLVER"
export TAG_SHA_RESOLVER
TAG_SOURCE_VERSION_RESOLVER="$TEST_DIR/source-version"
cat >"$TAG_SOURCE_VERSION_RESOLVER" <<'RESOLVER'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_MULTI_RELEASE:-0} == 1 ]]; then
  while IFS= read -r tag; do
    [[ $(printf '%s' "$tag" | sha1sum | cut -d' ' -f1) == "$1" ]] || continue
    if [[ $tag == "${BAD_SOURCE_TAG:-}" ]]; then
      printf '%s\n' "${BAD_SOURCE_VERSION:-v9.9.9}"
    else
      printf '%s\n' "$tag"
    fi
    exit 0
  done < <(jq -r '.tags[]' <<<"$GH_TAGS"; jq -r '.tags[]' <<<"$DH_TAGS"; jq -r '.[]' <<<"${ALIAS_SOURCE_TAGS:-[]}")
  exit 1
fi
[[ $1 == "$SOURCE_SHA" ]] || {
  printf 'unexpected source revision: %s\n' "$1" >&2
  exit 1
}
if [[ ${TAG_SOURCE_VERSION_STATE:-valid} == unreadable ]]; then
  printf 'source version could not be read\n' >&2
  exit 1
fi
printf '%s\n' "${SOURCE_VERSION-v2.16.10}"
RESOLVER
chmod +x "$TAG_SOURCE_VERSION_RESOLVER"
export TAG_SOURCE_VERSION_RESOLVER
export GH_TAGS='{"tags":["v2.16.10","invalid","v3.0.0-rc.1"]}'
export DH_TAGS='{"tags":["v2.16.10","invalid"]}'
assert_eq "$(common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL")" v2.16.10

export GH_TAGS='{"tags":["v2.16.10","v2.17.0"]}'
export DH_TAGS='{"tags":["v2.16.10","v2.17.0"]}'
if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'common tag discovery accepted a strict exact tag with invalid provenance'
fi

# A verified common release must also prove the version stored in the source
# commit resolved for that tag. Keep the registry labels/content valid here so
# these cases isolate the Git source-version check.
export GH_TAGS='{"tags":["v2.16.10"]}'
export DH_TAGS='{"tags":["v2.16.10"]}'
export RELEASE_TAG=v2.16.10
export SOURCE_VERSION=v2.16.10
export TAG_SOURCE_VERSION_STATE=valid
export TAG_SHA_STATE=valid
: >"$WRITE_LOG"
assert_eq "$(common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL")" v2.16.10

export SOURCE_VERSION=$' \tv2.16.10\r\n'
assert_eq "$(common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL")" v2.16.10

export SOURCE_VERSION=v2.16.9
: >"$WRITE_LOG"
if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'common tag discovery accepted a source version that differs from the stable tag'
fi
[[ ! -s $WRITE_LOG ]] || fail 'mismatched source version performed an alias/copy write'

export SOURCE_VERSION=v2.16.10
export TAG_SOURCE_VERSION_STATE=unreadable
: >"$WRITE_LOG"
if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'common tag discovery accepted an unreadable backend/.version blob'
fi
[[ ! -s $WRITE_LOG ]] || fail 'unreadable source version performed an alias/copy write'
export TAG_SOURCE_VERSION_STATE=valid

export SOURCE_VERSION=''
: >"$WRITE_LOG"
if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'common tag discovery accepted an empty backend/.version blob'
fi
[[ ! -s $WRITE_LOG ]] || fail 'empty source version performed an alias/copy write'

export SOURCE_VERSION=v2.16.10
export TAG_SHA_STATE=missing
: >"$WRITE_LOG"
if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
  fail 'common tag discovery accepted a stable tag whose Git commit could not be resolved'
fi
[[ ! -s $WRITE_LOG ]] || fail 'unresolved Git tag performed an alias/copy write'

# The known broken release must never enter the common set, even if registry
# content carries otherwise matching labels and platform fingerprints.
export GH_TAGS='{"tags":["v2.16.1"]}'
export DH_TAGS='{"tags":["v2.16.1"]}'
export RELEASE_TAG=v2.16.1
export SOURCE_VERSION=v2.16.5
export TAG_SHA_STATE=valid
: >"$WRITE_LOG"
quarantine_warning="$TEST_DIR/quarantine-warning"
assert_eq "$(common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" 2>"$quarantine_warning")" ''
grep -F 'Warning: excluding quarantined historical stable release v2.16.1' "$quarantine_warning" >/dev/null || \
  fail 'quarantined release was skipped without an explicit warning'
[[ ! -s $WRITE_LOG ]] || fail 'mis-versioned v2.16.1 performed an alias/copy write'

# Exercise the production Git lookup without a GitHub dependency. The tagged
# commit must win over the current working tree, and a same-named branch must
# not substitute for a missing Git tag.
SOURCE_REPO="$TEST_DIR/source-repo"
mkdir -p "$SOURCE_REPO/backend"
git -C "$SOURCE_REPO" init -q
git -C "$SOURCE_REPO" config user.name 'Registry helper test'
git -C "$SOURCE_REPO" config user.email 'registry-helper-test@example.invalid'
printf 'v2.16.10\n' >"$SOURCE_REPO/backend/.version"
git -C "$SOURCE_REPO" add backend/.version
git -C "$SOURCE_REPO" commit -qm 'source for v2.16.10'
SOURCE_V21610_SHA=$(git -C "$SOURCE_REPO" rev-parse HEAD)
git -C "$SOURCE_REPO" tag v2.16.10
printf 'v2.16.11\n' >"$SOURCE_REPO/backend/.version"
git -C "$SOURCE_REPO" add backend/.version
git -C "$SOURCE_REPO" commit -qm 'branch-only source for v2.16.11'
SOURCE_V21611_SHA=$(git -C "$SOURCE_REPO" rev-parse HEAD)
git -C "$SOURCE_REPO" branch v2.16.11

(
  cd "$SOURCE_REPO"
  TAG_SHA_RESOLVER=
  TAG_SOURCE_VERSION_RESOLVER=
  SOURCE_SHA=$SOURCE_V21610_SHA
  RELEASE_TAG=v2.16.10
  # shellcheck disable=SC2030 # The isolated Git fixture intentionally overrides these here.
  GH_TAGS=$(jq -nc --arg tag "$RELEASE_TAG" '{tags:[$tag]}')
  # shellcheck disable=SC2030
  DH_TAGS=$GH_TAGS
  export TAG_SHA_RESOLVER TAG_SOURCE_VERSION_RESOLVER SOURCE_SHA RELEASE_TAG GH_TAGS DH_TAGS
  assert_eq "$(common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL")" v2.16.10

  SOURCE_SHA=$SOURCE_V21611_SHA
  RELEASE_TAG=v2.16.11
  GH_TAGS=$(jq -nc --arg tag "$RELEASE_TAG" '{tags:[$tag]}')
  DH_TAGS=$GH_TAGS
  export SOURCE_SHA RELEASE_TAG GH_TAGS DH_TAGS
  if common_valid_exact_tags ghcr.io/titlecardmaker/titlecardmaker example/titlecardmaker "$SOURCE_URL" >/dev/null 2>&1; then
    fail 'common tag discovery accepted a branch in place of the strict stable Git tag'
  fi
)

# Model several independently tagged releases so the scan must consider both
# registries, while alias digests still identify their actual release content.
export FAKE_MULTI_RELEASE=1 FAKE_MODE=valid
export GH_ALIASES='{}' DH_ALIASES='{}'
GH_REPO=ghcr.io/titlecardmaker/titlecardmaker
DH_REPO=example/titlecardmaker

# shellcheck disable=SC2031 # These are fresh parent-shell fixtures after the isolated Git test.
export GH_TAGS='{"tags":["v2.16.1","v2.16.10"]}'
# shellcheck disable=SC2031
export DH_TAGS=$GH_TAGS
assert_eq "$(common_valid_exact_tags "$GH_REPO" "$DH_REPO" "$SOURCE_URL")" v2.16.10
assert_eq "$(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10)" v2.16.10
if reject_quarantined_release v2.16.1 >/dev/null 2>&1; then
  fail 'v2.16.1 was accepted as a repair/publication source'
fi
reject_quarantined_release v2.16.10

# The pending exact release is validated on its source commit separately, then
# must be present and valid in both registries before it can enter promotion.
export GH_TAGS='{"tags":["v2.16.10"]}'
export DH_TAGS='{"tags":[]}'
if promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'promotion accepted a pending exact release present in only one registry'
fi

# A failed historical inventory must stop the pre-write sequence before its
# simulated first stable registry mutation.
run_prewrite_inventory_gate() {
  stable_exact_preflight "$GH_REPO:v2.17.0" "$DH_REPO:v2.17.0" || return 1
  validated_release_inventory "$GH_REPO" "$DH_REPO" "$SOURCE_URL" >/dev/null || return 1
  printf 'stable registry write\n' >>"$WRITE_LOG"
}
export GH_STATE=absent DH_STATE=absent
export GH_TAGS='{"tags":["v2.16.2"]}'
export DH_TAGS='{"tags":["v2.16.2"]}'
export BAD_SOURCE_TAG=v2.16.2 BAD_SOURCE_VERSION=v2.16.5
: >"$WRITE_LOG"
if run_prewrite_inventory_gate >/dev/null 2>&1; then
  fail 'pre-write historical inventory accepted unexpected broken provenance'
fi
[[ ! -s $WRITE_LOG ]] || fail 'failed historical inventory reached a stable registry write'
unset BAD_SOURCE_TAG BAD_SOURCE_VERSION

# A healthy historical inventory allows the pre-write gate to complete.
export GH_TAGS='{"tags":["v2.16.10"]}'
export DH_TAGS='{"tags":["v2.16.10"]}'
: >"$WRITE_LOG"
run_prewrite_inventory_gate >/dev/null
grep -Fx 'stable registry write' "$WRITE_LOG" >/dev/null || fail 'valid pre-write inventory blocked publication'

export GH_TAGS='{"tags":["v2.16.10","v2.16.2"]}'
export DH_TAGS='{"tags":["v2.16.10"]}' BAD_SOURCE_TAG=v2.16.2 BAD_SOURCE_VERSION=v2.16.5
if promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'an unexpected mis-versioned strict stable tag did not fail closed'
fi
unset BAD_SOURCE_TAG BAD_SOURCE_VERSION

export GH_TAGS='{"tags":["v2.18.0","v3.0.0"]}'
export DH_TAGS='{"tags":["v2.18.0"]}'
assert_eq "$(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0)" $'v2.18.0\nv3.0.0'
assert_eq "$("$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.18.0 v2.18.0 v3.0.0)" \
  $'expected_latest\tv3.0.0\npromote\tv2.18\npromote\tv2'

export GH_TAGS='{"tags":["v2.18.0"]}'
export DH_TAGS='{"tags":["v2.18.0","v3.0.0"]}'
assert_eq "$(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0)" $'v2.18.0\nv3.0.0'
assert_eq "$("$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.18.0 v2.18.0 v3.0.0)" \
  $'expected_latest\tv3.0.0\npromote\tv2.18\npromote\tv2'

export GH_TAGS='{"tags":["v2.16.10","v2.16.11","v2.17.0"]}'
export DH_TAGS='{"tags":["v2.16.10"]}'
assert_eq "$(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10)" \
  $'v2.16.10\nv2.16.11\nv2.17.0'
assert_eq "$("$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.16.10 v2.16.10 v2.16.11 v2.17.0)" \
  $'expected_latest\tv2.17.0'

# Even if a caller incorrectly proposes an older version, a verified alias
# already pointing to a newer release must stop the write in either registry.
export GH_TAGS='{"tags":["v2.18.0","v3.0.0"]}'
export DH_TAGS=$GH_TAGS
export GH_ALIASES='{"latest":"v3.0.0"}'
export DH_ALIASES='{"latest":"v3.0.0"}'
: >"$WRITE_LOG"
for alias_ref in "$GH_REPO:latest" "$DH_REPO:latest"; do
  if guard_alias_promotion "$alias_ref" v2.18.0 "$SOURCE_URL" v2.18.0 v3.0.0 >/dev/null 2>&1; then
    copy_alias_by_digest "$GH_REPO:v2.18.0" "$alias_ref"
    fail "newer ${alias_ref} was overwritten"
  fi
done
[[ ! -s $WRITE_LOG ]] || fail 'newer latest alias caused a registry write'

export GH_TAGS='{"tags":["v2.16.10","v2.16.11","v2.17.0"]}'
export DH_TAGS=$GH_TAGS
export GH_ALIASES='{"v2.16":"v2.16.11","v2":"v2.17.0"}'
export DH_ALIASES=$GH_ALIASES
for alias_ref in "$GH_REPO:v2.16" "$DH_REPO:v2.16" "$GH_REPO:v2" "$DH_REPO:v2"; do
  if guard_alias_promotion "$alias_ref" v2.16.10 "$SOURCE_URL" v2.16.10 v2.16.11 v2.17.0 >/dev/null 2>&1; then
    fail "newer ${alias_ref} was allowed to regress"
  fi
done
[[ ! -s $WRITE_LOG ]] || fail 'newer major/minor alias caused a registry write'

export GH_TAGS='{"tags":["v2.16.10","v2.16.11"]}'
export DH_TAGS=$GH_TAGS
export GH_ALIASES='{"v2.16":"v2.16.10","v2":"v2.16.10","latest":"v2.16.10"}'
export DH_ALIASES=$GH_ALIASES
for alias in v2.16 v2 latest; do
  guard_alias_promotion "$GH_REPO:$alias" v2.16.11 "$SOURCE_URL" v2.16.10 v2.16.11
  guard_alias_promotion "$DH_REPO:$alias" v2.16.11 "$SOURCE_URL" v2.16.10 v2.16.11
done

export GH_ALIASES='{"latest":"v9.9.9"}'
if guard_alias_promotion "$GH_REPO:latest" v2.16.11 "$SOURCE_URL" v2.16.10 v2.16.11 >/dev/null 2>&1; then
  fail 'an alias with unverifiable content was accepted'
fi
export GH_ALIASES='{"latest":"__timeout__"}'
if guard_alias_promotion "$GH_REPO:latest" v2.16.11 "$SOURCE_URL" v2.16.10 v2.16.11 >/dev/null 2>&1; then
  fail 'an alias query timeout was accepted'
fi
export GH_ALIASES='{"latest":"v2.16.10"}' FAKE_MODE=wrong_revision
if guard_alias_promotion "$GH_REPO:latest" v2.16.11 "$SOURCE_URL" v2.16.10 v2.16.11 >/dev/null 2>&1; then
  fail 'an alias with invalid image provenance was accepted'
fi
export FAKE_MODE=valid

export GH_TAGS='{"tags":["v2.16.1","v2.16.10"]}'
export DH_TAGS=$GH_TAGS GH_ALIASES='{"latest":"v2.16.1"}'
if guard_alias_promotion "$GH_REPO:latest" v2.16.10 "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'a quarantined alias target was treated as a verified release'
fi

# A newer one-registry-only exact release is a ceiling for future promotion,
# but it must not become GitHub Latest. The latter follows the validated
# Docker latest aliases in both registries.
export GH_TAGS='{"tags":["v2.17.2","v2.18.0","v3.0.0"]}'
export DH_TAGS='{"tags":["v2.17.2","v2.18.0"]}'
export GH_ALIASES='{"latest":"v2.17.2"}' DH_ALIASES='{"latest":"v2.17.2"}'
mapfile -t promotion_tags < <(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0)
"$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.18.0 "${promotion_tags[@]}" >"$TEST_DIR/promotions"
assert_eq "$(latest_decision "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0 "$TEST_DIR/promotions" "${promotion_tags[@]}")" \
  $'latest_eligible\tfalse\nexpected_latest_tag\tv2.17.2'

export GH_ALIASES='{"latest":"v3.0.0"}'
if latest_decision "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0 "$TEST_DIR/promotions" "${promotion_tags[@]}" >/dev/null 2>&1; then
  fail 'one-registry-only content was selected as GitHub Latest'
fi

export GH_TAGS='{"tags":["v2.17.2","v2.18.0"]}'
export DH_TAGS='{"tags":["v2.17.2","v2.18.0","v3.0.0"]}'
export GH_ALIASES='{"latest":"v2.17.2"}' DH_ALIASES='{"latest":"v2.17.2"}'
mapfile -t promotion_tags < <(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0)
"$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.18.0 "${promotion_tags[@]}" >"$TEST_DIR/promotions"
assert_eq "$(latest_decision "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.18.0 "$TEST_DIR/promotions" "${promotion_tags[@]}")" \
  $'latest_eligible\tfalse\nexpected_latest_tag\tv2.17.2'

export GH_TAGS='{"tags":["v2.16.10","v2.16.11"]}'
export DH_TAGS=$GH_TAGS
export GH_ALIASES='{"latest":"v2.16.10"}' DH_ALIASES='{"latest":"v2.16.10"}'
mapfile -t promotion_tags < <(promotion_candidates "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.11)
"$SCRIPT_DIR/docker-semver-tags.sh" promotions v2.16.11 "${promotion_tags[@]}" >"$TEST_DIR/promotions"
assert_eq "$(latest_decision "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.11 "$TEST_DIR/promotions" "${promotion_tags[@]}")" \
  $'latest_eligible\ttrue\nexpected_latest_tag\tv2.16.11'

# Repair may replace a stale alias only after establishing its old version as
# an ordering floor and independently validating the new exact tag in both registries.
export GH_TAGS='{"tags":["v2.16.10"]}' DH_TAGS='{"tags":["v2.16.10"]}'
export GH_ALIASES='{"v2.16":"v2.16.9","latest":"v2.16.9"}'
export DH_ALIASES=$GH_ALIASES ALIAS_SOURCE_TAGS='["v2.16.9"]'
: >"$WRITE_LOG"
assert_eq "$(repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10)" v2.16.10
assert_eq "$(repair_alias_bootstrap_target "$DH_REPO:latest" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10)" v2.16.10
[[ ! -s $WRITE_LOG ]] || fail 'bootstrap preflight wrote an alias'
copy_alias_by_digest "$GH_REPO:v2.16.10" "$GH_REPO:v2.16"
grep -F " -> $GH_REPO:v2.16" "$WRITE_LOG" >/dev/null || fail 'repair bootstrap did not copy the validated exact digest'
: >"$WRITE_LOG"
if guard_alias_promotion "$GH_REPO:v2.16" v2.16.10 "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'normal publication accepted an unmatched stale alias'
fi

export DH_TAGS='{"tags":[]}'
if repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap accepted a target missing from Docker Hub'
fi
[[ ! -s $WRITE_LOG ]] || fail 'missing bootstrap target caused a write'
export DH_TAGS='{"tags":["v2.16.10"]}'
export GH_TAGS='{"tags":[]}'
if repair_alias_bootstrap_target "$DH_REPO:latest" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap accepted a target missing from GHCR'
fi
export GH_TAGS='{"tags":["v2.16.10"]}'
if FAKE_MODE=wrong_revision repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap accepted invalid target provenance'
fi

export GH_ALIASES='{"v2.16":"v2.16.11"}' ALIAS_SOURCE_TAGS='["v2.16.11"]'
if repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap moved an unmatched alias backwards'
fi
export GH_ALIASES='{"v2.16":"v9.9.9"}' ALIAS_SOURCE_TAGS='[]'
if repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap accepted an unverifiable alias version'
fi
export GH_ALIASES='{"v2.16":"v2.16.1"}' ALIAS_SOURCE_TAGS='["v2.16.1"]'
if repair_alias_bootstrap_target "$GH_REPO:v2.16" v2.16.10 "$GH_REPO" "$DH_REPO" "$SOURCE_URL" v2.16.10 >/dev/null 2>&1; then
  fail 'bootstrap accepted the quarantined v2.16.1 alias'
fi
[[ ! -s $WRITE_LOG ]] || fail 'failed bootstrap preflight caused a write'

printf 'All Docker release registry helper tests passed.\n'
