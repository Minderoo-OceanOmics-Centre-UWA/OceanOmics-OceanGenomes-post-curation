#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

## USEAGE bash 03_get_assembly_from_config.sh ../postcuration_pipeline.conf 

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <config.conf>" >&2
  exit 1
fi

CONFIG_FILE="$1"
[[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE" >&2; exit 1; }

# Load config (bash-compatible KEY=VALUE)
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

# expand {user} placeholders in paths
USER_REAL="${USER:-$(whoami)}"
expand_user() { printf '%s' "${1//\{user\}/$USER_REAL}"; }

SAMPLESHEET="$(expand_user "${SAMPLESHEET}")"
RCLONE_FLAGS="${RCLONE_FLAGS:-}"

[[ -f "$SAMPLESHEET" ]] || { echo "Samplesheet not found: $SAMPLESHEET" >&2; exit 1; }

# Helper: trim CR/LF and leading/trailing whitespace
clean() { printf '%s' "$1" | tr -d '\r' | xargs; }


ASSEMBLY_BUCKET="${ASSEMBLY_BUCKET:?Missing ASSEMBLY_BUCKET in config}"
ASSEMBLY_GLOB_SUFFIX="${ASSEMBLY_GLOB_SUFFIX:-curated.hap1.chr_level.fa}"
NPROC="${NPROC:-4}"

tmp_list="$(mktemp)"
tmp_pairs="$(mktemp)"
trap 'rm -f "$tmp_list" "$tmp_pairs"' EXIT

declare -A ASSEMBLY_DIR
declare -A ASM_FOLDER
samples=()

# map sample -> assembly dir (col1 -> col3) and assembly folder <OG>_<date>.<version> (cols 7, 6)
while IFS=$'\t' read -r sample assembly_dir version asm_date; do
  sample="$(clean "$sample")"
  assembly_dir="$(clean "$assembly_dir")"
  [[ -z "$sample" ]] && continue
  ASSEMBLY_DIR["$sample"]="$(expand_user "$assembly_dir")"
  ASM_FOLDER["$sample"]="${sample}_$(clean "$asm_date").$(clean "$version")"
  samples+=("$sample")
done < <(awk -F, 'NR>1 { gsub(/\r/,""); print $1 "\t" $3 "\t" $6 "\t" $7 }' "$SAMPLESHEET")

[[ ${#samples[@]} -gt 0 ]] || { echo "No samples found in $SAMPLESHEET" >&2; exit 1; }

for s in "${samples[@]}"; do mkdir -p "${ASSEMBLY_DIR[$s]}"; done

# Only the assembly version named in the samplesheet (also stops OG5 matching OG52 etc.)
include=()
for s in "${samples[@]}"; do include+=( --include "/${s}/${ASM_FOLDER[$s]}/**${ASSEMBLY_GLOB_SUFFIX}*" ); done
rclone ls "$ASSEMBLY_BUCKET" ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${include[@]}" > "$tmp_list"

# Build remote_path <TAB> local_dir pairs
while IFS= read -r line || [[ -n "$line" ]]; do
  path="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//; s/\r$//')"
  og="$(printf '%s' "$path" | grep -o -m1 -E 'OG[0-9]+' || true)"

  target=""
  if [[ -n "$og" && -n "${ASSEMBLY_DIR[$og]:-}" ]]; then
    target="${ASSEMBLY_DIR[$og]}"
  else
    for s in "${samples[@]}"; do
      if [[ "$path" == *"$s"* ]]; then
        target="${ASSEMBLY_DIR[$s]}"
        break
      fi
    done
  fi

  if [[ -z "$target" ]]; then
    target="/scratch/pawsey0964/${USER_REAL}/post_curation/${og:-unknown}"
    echo "Warning: no assembly dir for remote path; falling back to ${target}" >&2
  fi

  printf '%s\t%s\n' "${ASSEMBLY_BUCKET}/${path}" "$target"
done < "$tmp_list" > "$tmp_pairs"

total=$(wc -l < "$tmp_pairs")
echo "Copying ${total} assembly files (NPROC=${NPROC})..."
running=0
while IFS=$'\t' read -r src dst; do
  echo "  $(basename "$src") -> $dst/"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$src" "$dst/" &
  running=$((running + 1))
  if (( running >= NPROC )); then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done < "$tmp_pairs"
wait

missing=0
for s in "${samples[@]}"; do
  if ! grep -q "/${ASM_FOLDER[$s]}/" "$tmp_list"; then
    echo "ERROR: no assembly found for $s under ${ASSEMBLY_BUCKET}/${s}/${ASM_FOLDER[$s]}/ — check version/date in $SAMPLESHEET" >&2
    missing=1
  fi
done
[[ $missing -eq 0 ]] || exit 1

echo "Done."
