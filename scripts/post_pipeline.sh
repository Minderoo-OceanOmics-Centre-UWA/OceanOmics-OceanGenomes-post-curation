#!/usr/bin/env bash
# post_pipeline.sh — compile results, push to DB, backup to Acacia, audit
#
# Usage: bash post_pipeline.sh [config.conf]
# Can be run standalone after a successful pipeline, or called by postcuration_run.sh.
#
# Steps:
#   1. Compile all QC outputs into TSV files
#   2. Push compiled results to PostgreSQL via singularity
#   3. Submit per-OG backup SLURM jobs to Acacia
#   4. Back up MultiQC report
#   5. Submit audit SLURM job (runs after all backups complete)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/postcuration_pipeline.conf}"
SING="${SING:-/software/projects/pawsey0964/singularity}"
LOG_DIR="${LOG_DIR:-$(dirname "$SCRIPT_DIR")/logs}"
STAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$LOG_DIR"

[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 1; }

# Source config (only KEY=VALUE lines)
source <(grep -E '^[A-Z_][A-Z0-9_]*=' "$CONFIG")

STAGING_BASE_DIR_REAL="${STAGING_BASE_DIR//\{user\}/$USER}"
OUTDIR="${STAGING_BASE_DIR_REAL}/post-curation"
MULTIQC_DIR="${STAGING_BASE_DIR_REAL}/multiqc"
SAMPLESHEET_REAL="${SAMPLESHEET//\{user\}/$USER}"

[[ -f "$SAMPLESHEET_REAL" ]] || { echo "Samplesheet not found: $SAMPLESHEET_REAL" >&2; exit 1; }

echo "=== Post-Pipeline Processing ==="
echo "Config     : $CONFIG"
echo "Outdir     : $OUTDIR"
echo "Samplesheet: $SAMPLESHEET_REAL"
echo "Logs       : $LOG_DIR"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 1. Compile results
# ────────────────────────────────────────────────────────────────────────────
COMPILE_DIR="$LOG_DIR/compile_$STAMP"
mkdir -p "$COMPILE_DIR"
echo "[1/5] Compiling QC results → $COMPILE_DIR"

(
  cd "$COMPILE_DIR"
  bash "$SCRIPT_DIR/compile_results/02a_merqury_qv_compile.sh" "$OUTDIR"
  bash "$SCRIPT_DIR/compile_results/02c_merqury_completeness_compile.sh" "$OUTDIR"
  bash "$SCRIPT_DIR/compile_results/03_busco_compile.sh" "$OUTDIR"
  bash "$SCRIPT_DIR/compile_results/04_final_gfastats_compile.sh" "$OUTDIR"
  bash "$SCRIPT_DIR/compile_results/05_stats_compile.sh" "$OUTDIR"
  bash "$SCRIPT_DIR/compile_results/06_compile_percent_stats.sh" "$OUTDIR"
) 2>&1 | tee "$LOG_DIR/compile_$STAMP.log"
echo "[OK] Compile done"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 2. Push to database
# ────────────────────────────────────────────────────────────────────────────
echo "[2/5] Pushing results to PostgreSQL..."
DB_PUSH_FAILED=0

DB_CONFIG="${DB_CONFIG:-$HOME/postgresql_details/oceanomics.cfg}"

push_py() {
  local script="$1"
  echo "  → $(basename "$script")"
  singularity run "$SING/psycopg2:0.1.sif" python "$SCRIPT_DIR/compile_results/$script" "$DB_CONFIG" \
    || { echo "  [WARN] $script failed — continuing"; DB_PUSH_FAILED=1; }
}

(
  cd "$COMPILE_DIR"
  push_py 02b_push_merqury_qv_results_to_sqldb.py
  push_py 02d_push_merqury_completeness_results_to_sqldb.py
  push_py 03a_push_busco_results_to_sqldb.py
  push_py 04a_push_gfa_results_to_sqldb.py
  push_py 05a_push_stats_compiled_results_to_sql.py
  push_py 06a_transform_percent_stats.py
  push_py 06b_push_percentage_stats_to_sqldb.py
) 2>&1 | tee "$LOG_DIR/db_push_$STAMP.log"

[[ $DB_PUSH_FAILED -eq 0 ]] && echo "[OK] Database push done" || echo "[WARN] Some DB pushes failed — check $LOG_DIR/db_push_$STAMP.log"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 3. Submit per-OG backup jobs
# ────────────────────────────────────────────────────────────────────────────
echo "[3/5] Submitting per-OG backup jobs..."
mapfile -t BACKUP_JOB_IDS < <(
  bash "$SCRIPT_DIR/backup_scripts/backup-loop.sh" "$SAMPLESHEET_REAL" "$OUTDIR"
)
echo "[OK] ${#BACKUP_JOB_IDS[@]} backup jobs submitted: ${BACKUP_JOB_IDS[*]}"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 4. Backup MultiQC report (once, not per-OG)
# ────────────────────────────────────────────────────────────────────────────
echo "[4/5] Backing up MultiQC report..."
MULTIQC_SRC="$MULTIQC_DIR/multiqc_report.html"
if [[ -f "$MULTIQC_SRC" ]]; then
  MULTIQC_DEST="$MULTIQC_DIR/$(date +"%Y_%m_%d")_post_curation_multiqc_report.html"
  MULTIQC_REMOTE="pawsey0964:oceanomics-refassemblies/postcuration_multiqc"
  cp "$MULTIQC_SRC" "$MULTIQC_DEST"
  rclone copy "$MULTIQC_DEST" "$MULTIQC_REMOTE" --checksum --progress
  if rclone check "$MULTIQC_DEST" "$MULTIQC_REMOTE" --checksum --one-way; then
    echo "[OK] MultiQC backed up and verified"
  else
    echo "[WARN] MultiQC rclone check failed — report may not be backed up correctly"
  fi
else
  echo "[WARN] MultiQC report not found at $MULTIQC_SRC — skipping"
fi
echo ""

# ────────────────────────────────────────────────────────────────────────────
# 5. Submit audit job (runs after all backups complete)
# ────────────────────────────────────────────────────────────────────────────
echo "[5/5] Submitting audit job..."
AUDIT_LOG_DIR="$LOG_DIR/audit_$STAMP"
mkdir -p "$AUDIT_LOG_DIR"

if [[ ${#BACKUP_JOB_IDS[@]} -gt 0 ]]; then
  # afterany, not afterok: backup.sh exits non-zero if any rclone check fails, and
  # a failed backup is precisely when the audit report is most useful.
  DEPENDENCY="afterany:$(IFS=':'; echo "${BACKUP_JOB_IDS[*]}")"
  AUDIT_JOB=$(sbatch --parsable \
    --dependency="$DEPENDENCY" \
    --account=pawsey1348 \
    --partition=work \
    --ntasks=1 \
    --cpus-per-task=1 \
    --time=2:00:00 \
    --job-name=postcuration-audit \
    --output="$AUDIT_LOG_DIR/audit_%j.log" \
    --wrap="bash $SCRIPT_DIR/backup_scripts/backup_audit.sh \
              --samplesheet $SAMPLESHEET_REAL \
              --outdir $AUDIT_LOG_DIR \
              --datadir $OUTDIR")
  echo "[OK] Audit job $AUDIT_JOB submitted (depends on: ${BACKUP_JOB_IDS[*]})"
else
  echo "[WARN] No backup jobs were submitted — skipping audit"
fi

echo ""
echo "=== Post-pipeline complete ==="
echo "Compiled TSVs : $COMPILE_DIR"
echo "Logs          : $LOG_DIR"
