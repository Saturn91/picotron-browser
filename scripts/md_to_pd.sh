#!/usr/bin/env bash
# md_to_pd.sh — convert a Markdown file to podweb format
# Usage: bash md_to_pd.sh myfile.md
# Output is written next to the source as myfile.podweb

set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: bash md_to_pd.sh <file.md>"; exit 1; }
[[ -f "$1"  ]] || { echo "error: file not found: $1"; exit 1; }

src="$1"
out="${src%.*}.podweb"
> "$out"

emit() { printf '%s\n' "$1" >> "$out"; }

inline() {
  printf '%s' "$1" \
    | sed -E 's/!\[([^]]+)\]\([^)]+\)/\1/g' \
    | sed -E 's/\[([^]]+)\]\(([^)]+)\)/[link- url="\2"]\1[-link]/g' \
    | sed -E 's/\*\*([^*]+)\*\*/\1/g' \
    | sed -E 's/__([^_]+)__/\1/g'     \
    | sed -E 's/\*([^*]+)\*/\1/g'     \
    | sed -E 's/_([^_]+)_/\1/g'       \
    | sed -E 's/`([^`]+)`/\1/g'
}

declare -a para=()
in_code=0

flush_para() {
  if   [[ ${#para[@]} -eq 1 ]]; then
    emit "[p] ${para[0]}"
    emit ""
  elif [[ ${#para[@]} -gt 1 ]]; then
    emit "[p-]"
    for line in "${para[@]}"; do emit "$line"; done
    emit "[-p]"
    emit ""
  fi
  para=()
}

# regex patterns stored in variables to avoid bash parser confusion with ()
re_h3='^###[[:space:]](.+)'
re_h2='^##[[:space:]](.+)'
re_h1='^#[[:space:]](.+)'
re_hr='^(---+|\*\*\*+|___+)[[:space:]]*$'
re_bq='^\>[[:space:]](.+)'
re_ul='^[-*+][[:space:]](.+)'
re_ol='^[0-9]+\.[[:space:]](.+)'
re_img='^!\[([^]]+)\]\(([^)]+)\)$'
re_lnk='^\[([^]]+)\]\(([^)]+)\)$'
re_code='^```'

process_line() {
  local raw="$1"
  local trimmed="${raw#"${raw%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  if [[ $in_code -eq 1 ]]; then
    if [[ "$trimmed" =~ $re_code ]]; then
      emit "[-code]"; emit ""; in_code=0
    else
      emit "$raw"
    fi
    return
  fi

  if   [[ "$trimmed" =~ $re_code ]]; then
    flush_para; emit "[code-]"; in_code=1

  elif [[ "$trimmed" =~ $re_h3 ]]; then
    flush_para; emit "[h3] $(inline "${BASH_REMATCH[1]}")"; emit ""

  elif [[ "$trimmed" =~ $re_h2 ]]; then
    flush_para; emit "[h2] $(inline "${BASH_REMATCH[1]}")"; emit ""

  elif [[ "$trimmed" =~ $re_h1 ]]; then
    flush_para; emit "[h1] $(inline "${BASH_REMATCH[1]}")"; emit ""

  elif [[ "$trimmed" =~ $re_hr ]]; then
    flush_para; emit "[p] ---"; emit ""

  elif [[ "$trimmed" =~ $re_bq ]]; then
    flush_para; emit "[p] $(inline "${BASH_REMATCH[1]}")"; emit ""

  elif [[ "$trimmed" =~ $re_ul ]] || [[ "$trimmed" =~ $re_ol ]]; then
    flush_para; emit "[p] - $(inline "${BASH_REMATCH[1]}")"

  elif [[ "$trimmed" =~ $re_img ]]; then
    flush_para; emit "[img url=${BASH_REMATCH[2]} alt=${BASH_REMATCH[1]}]"; emit ""

  elif [[ "$trimmed" =~ $re_lnk ]]; then
    flush_para; emit "[link url=\"${BASH_REMATCH[2]}\"] ${BASH_REMATCH[1]}"; emit ""

  elif [[ -z "$trimmed" ]]; then
    flush_para

  else
    para+=("$(inline "$trimmed")")
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  process_line "$line"
done < "$src"

flush_para

echo "written to: $out"
