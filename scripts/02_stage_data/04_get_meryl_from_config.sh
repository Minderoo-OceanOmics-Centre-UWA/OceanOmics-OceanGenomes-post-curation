#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Usage:
#   bash 04_get_meryl_from_config.sh ../postcuration_pipeline.conf

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

MERYL_BUCKET="${MERYL_BUCKET:?Missing MERYL_BUCKET in config}"
MERYL_REQUIRED_SUBSTR_1="${MERYL_REQUIRED_SUBSTR_1:-meryl}"
MERYL_REQUIRED_SUBSTR_2="${MERYL_REQUIRED_SUBSTR_2:-tar.gz}"
NPROC="${NPROC:-4}"

tmp="$(mktemp)"
tmp_pairs="$(mktemp)"
trap 'rm -f "$tmp" "${tmp}.matched" "$tmp_pairs" 2>/dev/null || true' EXIT

declare -A MERYL_DIR
samples=()

# map sample -> meryldb dir (col1 -> col4)
while IFS=$'\t' read -r s dir; do
  s="$(clean "$s")"
  dir="$(clean "$dir")"
  [[ -z "$s" ]] && continue
  MERYL_DIR["$s"]="$(expand_user "$dir")"
  samples+=("$s")
done < <(awk -F, 'NR>1{ gsub(/\r/,"",$1); gsub(/\r/,"",$4); print $1 "\t" $4 }' "$SAMPLESHEET")

[[ ${#samples[@]} -gt 0 ]] || { echo "No samples found in $SAMPLESHEET" >&2; exit 1; }

# Build remote_path <TAB> local_dir pairs for all samples
for s in "${samples[@]}"; do
  outdir="${MERYL_DIR[$s]:-}"
  [[ -n "$outdir" ]] || { echo "Error: no meryldb entry for ${s}" >&2; exit 1; }
  mkdir -p "$outdir"

  rclone lsf --recursive ${RCLONE_FLAGS:+$RCLONE_FLAGS} "${MERYL_BUCKET}/${s}" > "$tmp" 2>/dev/null || true
  grep -i "$MERYL_REQUIRED_SUBSTR_1" "$tmp" | grep -i "$MERYL_REQUIRED_SUBSTR_2" > "${tmp}.matched" || true

  if [[ ! -s "${tmp}.matched" ]]; then
    echo "Error: no meryl tarball found for ${s} on ${MERYL_BUCKET}/${s}" >&2; exit 1
  fi

  while IFS= read -r relpath; do
    relpath="$(clean "$relpath")"
    [[ -z "$relpath" ]] && continue
    printf '%s\t%s\n' "${MERYL_BUCKET}/${s}/${relpath}" "$outdir"
  done < "${tmp}.matched"
done > "$tmp_pairs"

# Download all tarballs in parallel
total=$(wc -l < "$tmp_pairs")
echo "Downloading ${total} meryl tarballs (NPROC=${NPROC})..."
running=0
while IFS=$'\t' read -r src dst; do
  echo "  Downloading $(basename "$src") -> $dst/"
  rclone copy ${RCLONE_FLAGS:+$RCLONE_FLAGS} "$src" "$dst/" &
  running=$((running + 1))
  if (( running >= NPROC )); then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done < "$tmp_pairs"
wait

# Extract all tarballs (sequential — avoids competing I/O during decompression)
while IFS=$'\t' read -r src dst; do
  arc="${dst}/$(basename "$src")"
  [[ -f "$arc" ]] || continue
  echo "Extracting $(basename "$arc") -> $dst/"
  tar -xzf "$arc" -C "$dst"
  rm -f "$arc"
done < "$tmp_pairs"

echo "Done."
