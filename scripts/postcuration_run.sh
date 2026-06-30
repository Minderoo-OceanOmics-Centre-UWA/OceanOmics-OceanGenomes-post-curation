#!/usr/bin/env bash
# postcuration_run.sh — run the post-curation Nextflow pipeline, then compile,
#                        push to DB, and back up to Acacia on success.
#
# Usage: bash postcuration_run.sh [config.conf] [--curation-tool rapid-curation|pretext-to-asm]
#                                  [extra nextflow args...]
#
# Reads SAMPLESHEET, STAGING_BASE_DIR from the config.
# Nextflow-specific knobs (buscodb, tempdir, curation tool) can be overridden
# via the extra args passthrough or by editing the defaults below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SCRIPT_DIR/postcuration_pipeline.conf"
LOG_DIR="${LOG_DIR:-$(dirname "$SCRIPT_DIR")/logs}"
STAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOG_DIR"

# ── Defaults (override via CLI passthrough to nextflow) ────────────────────
BUSCODB="${BUSCODB:-/scratch/references/busco_db/actinopterygii_odb10}"
BINDDIR="${BINDDIR:-/scratch}"
TEMPDIR="${TEMPDIR:-/scratch/pawsey0964/$USER/tmp}"
CURATION_TOOL="rapid-curation"   # change to rapid-curation if needed

# Parse our own args; anything unrecognised is passed straight to nextflow
NF_EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    *.conf)                  CONFIG="$arg" ;;
    --curation-tool=*)       CURATION_TOOL="${arg#--curation-tool=}" ;;
    --curation-tool)         shift; CURATION_TOOL="$1" ;;
    *)                       NF_EXTRA_ARGS+=("$arg") ;;
  esac
done

[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }
source <(grep -E '^[A-Z_][A-Z0-9_]*=' "$CONFIG")

SAMPLESHEET_REAL="${SAMPLESHEET//\{user\}/$USER}"
OUTDIR="${STAGING_BASE_DIR//\{user\}/$USER}"
NF_LOG="$LOG_DIR/nextflow_$STAMP.log"

mkdir -p "$TEMPDIR"

echo "=== Post-Curation Pipeline Run ==="
echo "Config        : $CONFIG"
echo "Samplesheet   : $SAMPLESHEET_REAL"
echo "Outdir        : $OUTDIR"
echo "Curation tool : $CURATION_TOOL"
echo "Log           : $NF_LOG"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 1. Run Nextflow
# ────────────────────────────────────────────────────────────────────────────
echo "[1/2] Running Nextflow pipeline..."
set +e
nextflow run "$REPO_DIR/main.nf" \
  -profile singularity \
  --input "$SAMPLESHEET_REAL" \
  --buscodb "$BUSCODB" \
  --binddir "$BINDDIR" \
  --outdir  "$OUTDIR" \
  --tempdir "$TEMPDIR" \
  --curation_tool "$CURATION_TOOL" \
  -c "$REPO_DIR/pawsey_profile.config" \
  "${NF_EXTRA_ARGS[@]}" \
  2>&1 | tee "$NF_LOG"
NF_EXIT=${PIPESTATUS[0]}
set -e

echo ""
if [[ $NF_EXIT -ne 0 ]]; then
  echo "[FAIL] Nextflow pipeline exited with code $NF_EXIT"
  echo "       Log: $NF_LOG"
  exit "$NF_EXIT"
fi

echo "[OK] Pipeline completed successfully."
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 2. Post-pipeline: compile, DB push, backup, audit
# ────────────────────────────────────────────────────────────────────────────
echo "[2/2] Running post-pipeline steps..."
LOG_DIR="$LOG_DIR" bash "$SCRIPT_DIR/post_pipeline.sh" "$CONFIG"
