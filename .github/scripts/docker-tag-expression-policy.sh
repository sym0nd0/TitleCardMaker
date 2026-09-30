#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  printf 'Usage: %s <repair-workflow.yml>\n' "${0##*/}" >&2
  exit 64
fi

workflow=$1
[[ -r $workflow ]] || {
  printf 'Cannot read repair workflow: %s\n' "$workflow" >&2
  exit 1
}

input_reference_re='\$\{\{[^}]*inputs[^}]*\}\}'
safe_assignment_re='^ {10}RELEASE_TAG:[[:space:]]+\$\{\{[[:space:]]*inputs[[:space:]]*\.[[:space:]]*tag[[:space:]]*\}\}[[:space:]]*$'
env_line_re='^ {8}env:[[:space:]]*$'
mapfile -t tag_reference_lines < <(grep -nE "$input_reference_re" "$workflow" || true)

if ((${#tag_reference_lines[@]} != 4)); then
  printf 'Expected four workflow input references, found %s in %s\n' \
    "${#tag_reference_lines[@]}" "$workflow" >&2
  exit 1
fi

for match in "${tag_reference_lines[@]}"; do
  line_number=${match%%:*}
  line=${match#*:}
  if [[ ! $line =~ $safe_assignment_re ]]; then
    printf 'Workflow input references are only allowed as an unquoted RELEASE_TAG environment assignment (%s:%s)\n' \
      "$workflow" "$line_number" >&2
      exit 1
  fi

  env_block_found=false
  for ((previous_number = line_number - 1; previous_number > 0; previous_number--)); do
    previous_line=$(sed -n "${previous_number}p" "$workflow")
    [[ $previous_line =~ ^[[:space:]]*$ ]] && continue
    if [[ $previous_line =~ $env_line_re ]]; then
      env_block_found=true
      break
    fi
    previous_prefix=${previous_line%%[![:space:]]*}
    previous_indent=${#previous_prefix}
    ((previous_indent > 8)) || break
  done
  if [[ $env_block_found != true ]]; then
    printf 'RELEASE_TAG must be inside a step env block (%s:%s)\n' \
      "$workflow" "$line_number" >&2
    exit 1
  fi
done
