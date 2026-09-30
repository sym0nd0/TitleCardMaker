#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POLICY=${POLICY:-"${SCRIPT_DIR}/docker-tag-expression-policy.sh"}
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x $POLICY ]] || fail "tag expression policy checker is missing or not executable: ${POLICY}"

VALID="$TEST_DIR/valid.yml"
cat >"$VALID" <<'YAML'
steps:
      - name: Example
        env:
          RELEASE_TAG: ${{ inputs.tag }}
        shell: bash
        run: check "$RELEASE_TAG"
      - name: Example two
        env:
          RELEASE_TAG: ${{ inputs.tag }}
        run: check "$RELEASE_TAG"
      - name: Example three
        env:
          RELEASE_TAG: ${{ inputs.tag }}
        run: check "$RELEASE_TAG"
      - name: Example four
        env:
          OTHER_SETTING: test
          RELEASE_TAG: ${{ inputs.tag }}
        run: check "$RELEASE_TAG"
YAML

"$POLICY" "$VALID"

# Whitespace accepted by the GitHub expression grammar must still be found
# and allowed only in the intended unquoted RELEASE_TAG environment value.
WHITESPACE="$TEST_DIR/whitespace.yml"
awk -v replacement="          RELEASE_TAG: \${{  inputs . tag  }}" \
  'NR == 4 {$0 = replacement} {print}' "$VALID" >"$WHITESPACE"
"$POLICY" "$WHITESPACE"

# Quoting the expression is not an allowed bypass of the environment-only rule.
QUOTED="$TEST_DIR/quoted.yml"
awk -v replacement="          RELEASE_TAG: '\${{ inputs.tag }}'" \
  'NR == 4 {$0 = replacement} {print}' "$VALID" >"$QUOTED"
if "$POLICY" "$QUOTED" >"$TEST_DIR/quoted.out" 2>&1; then
  fail 'tag expression policy accepted a quoted RELEASE_TAG expression'
fi

# An assignment inside a run block must not inherit an env block from an
# earlier step.
OUTSIDE_ENV="$TEST_DIR/outside-env.yml"
awk 'NR == 16 {$0 = "        run: |"} {print}' "$VALID" >"$OUTSIDE_ENV"
if "$POLICY" "$OUTSIDE_ENV" >"$TEST_DIR/outside-env.out" 2>&1; then
  fail 'tag expression policy accepted RELEASE_TAG outside an env block'
fi

# A fifth occurrence in a run block must be rejected even with expression
# whitespace that differs from the permitted environment assignment.
RUN_BLOCK="$TEST_DIR/run-block.yml"
cp "$VALID" "$RUN_BLOCK"
printf '%s\n' "        run: echo '\${{  inputs . tag  }}'" >>"$RUN_BLOCK"
if "$POLICY" "$RUN_BLOCK" >"$TEST_DIR/run-block.out" 2>&1; then
  fail 'tag expression policy accepted inputs.tag in a run block'
fi

# GitHub expressions also allow index syntax and the dispatch event payload.
# These must be rejected outside the single environment assignment too.
alternate_references=(
  "inputs['tag']"
  'inputs["tag"]'
  'github.event.inputs.tag'
  'github.event.inputs["tag"]'
  "github['event']['inputs']['tag']"
)
for index in "${!alternate_references[@]}"; do
  ALTERNATE="$TEST_DIR/alternate-${index}.yml"
  cp "$VALID" "$ALTERNATE"
  printf '%s\n' \
    '      - name: Alternate tag reference' \
    '        run: |' \
    "          echo '\${{ ${alternate_references[$index]} }}'" >>"$ALTERNATE"
  if "$POLICY" "$ALTERNATE" >"$TEST_DIR/alternate-${index}.out" 2>&1; then
    fail "tag expression policy accepted alternate reference ${alternate_references[$index]}"
  fi
done

printf 'All Docker tag expression policy tests passed.\n'
