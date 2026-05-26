#!/usr/bin/env bash
# stage_all.sh — one-command post-curation data staging
#
# Usage: bash stage_all.sh [config.conf] [--no-samplesheet]
#
# Steps:
#   1. Generate samplesheet from DB (skip with --no-samplesheet)
#   2. Create per-OG directory structure
#   3. Download HiC, assembly, and meryl in parallel background jobs
#
# Logs written to $LOG_DIR (default: scripts/../logs/)
# Monitor with: tail -f <log>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/postcuration_pipeline.conf"
SKIP_SAMPLESHEET=false

for arg in "$@"; do
  case "$arg" in
    --no-samplesheet) SKIP_SAMPLESHEET=true ;;
    *.conf)           CONFIG="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

SING="${SING:-/software/projects/pawsey0964/singularity}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)

[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }

echo "=== Post-Curation Staging ==="
echo "Config : $CONFIG"
echo "Logs   : $LOG_DIR"
echo ""

# 1. Generate samplesheet
if [[ "$SKIP_SAMPLESHEET" == false ]]; then
  echo "[1/3] Generating samplesheet..."
  singularity run "$SING/psycopg2:0.1.sif" python \
    "$SCRIPT_DIR/0_create_samplesheet/create_samplesheet_from_config.py" "$CONFIG"
  echo ""
else
  echo "[1/3] Skipping samplesheet generation (--no-samplesheet)"
fi

# Resolve samplesheet path with {user} expansion
USER_REAL="${USER:-$(whoami)}"
SAMPLESHEET="$(grep -E '^SAMPLESHEET=' "$CONFIG" | head -1 | cut -d= -f2- \
  | sed "s/{user}/$USER_REAL/g" | tr -d "'\"")"
[[ -f "$SAMPLESHEET" ]] || { echo "Samplesheet not found: $SAMPLESHEET" >&2; exit 1; }

# 2. Create per-OG directory structure
echo "[2/3] Creating per-OG directories..."
tail -n +2 "$SAMPLESHEET" | while IFS=, read -r sample hic_dir assembly meryldb agp _rest; do
  for d in "$hic_dir" "$assembly" "$meryldb" "$agp"; do
    d="${d//[$'\t\r\n ']}"
    [[ -n "$d" ]] && mkdir -p "$d"
  done
  echo "  $sample: dirs created"
done
echo ""

# 3. Stage data in parallel
echo "[3/3] Starting parallel downloads..."

bash "$SCRIPT_DIR/02_stage_data/01_get_hic_from_config.sh"      "$CONFIG" \
  2>&1 | tee "$LOG_DIR/hic_$STAMP.log" &
PID_HIC=$!

bash "$SCRIPT_DIR/02_stage_data/03_get_assembly_from_config.sh" "$CONFIG" \
  2>&1 | tee "$LOG_DIR/assembly_$STAMP.log" &
PID_ASSEMBLY=$!

bash "$SCRIPT_DIR/02_stage_data/04_get_meryl_from_config.sh"    "$CONFIG" \
  2>&1 | tee "$LOG_DIR/meryl_$STAMP.log" &
PID_MERYL=$!

echo "  Staging running in background:"
echo "    HiC      PID $PID_HIC      → $LOG_DIR/hic_$STAMP.log"
echo "    Assembly PID $PID_ASSEMBLY → $LOG_DIR/assembly_$STAMP.log"
echo "    Meryl    PID $PID_MERYL    → $LOG_DIR/meryl_$STAMP.log"
echo ""
echo "  Monitor all: tail -f $LOG_DIR/hic_$STAMP.log $LOG_DIR/assembly_$STAMP.log $LOG_DIR/meryl_$STAMP.log"
echo ""

EXIT=0
wait $PID_HIC      && echo "[OK] HiC"      || { echo "[FAIL] HiC — see $LOG_DIR/hic_$STAMP.log";           EXIT=1; }
wait $PID_ASSEMBLY && echo "[OK] Assembly" || { echo "[FAIL] Assembly — see $LOG_DIR/assembly_$STAMP.log";  EXIT=1; }
wait $PID_MERYL    && echo "[OK] Meryl"    || { echo "[FAIL] Meryl — see $LOG_DIR/meryl_$STAMP.log";        EXIT=1; }

echo ""
if [[ $EXIT -eq 0 ]]; then
  echo "All staging complete."
  echo "Next: drop AGP files into each OG's agp/ directory, then run the Nextflow pipeline."
else
  echo "Some steps failed — check logs in $LOG_DIR"
  exit 1
fi
