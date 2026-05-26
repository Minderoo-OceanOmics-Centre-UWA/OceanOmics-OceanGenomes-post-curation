#!/usr/bin/env bash
#SBATCH --job-name=stage_post_curation
#SBATCH --array=0-6
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=8:00:00
#SBATCH --account=pawsey0964
#SBATCH --partition=work
#SBATCH --output=/scratch/pawsey0964/lhuet/post_curation/logs/stage_%A_%a.log
#SBATCH --error=/scratch/pawsey0964/lhuet/post_curation/logs/stage_%A_%a.log

# One SLURM task per OG — all 7 OGs download in parallel.
# Within each task, per-file copies run in parallel via xargs -P.
#
# Submit: sbatch stage_data.slurm
# Monitor: squeue -u $USER
#          tail -f /scratch/pawsey0964/lhuet/post_curation/logs/stage_<jobid>_<taskid>.log

set -euo pipefail

module load rclone/1.68.1

SAMPLESHEET=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/assets/samplesheet.csv
HIC_BUCKET=s3:oceanomics/OceanGenomes/illumina-hic
ASSEMBLY_BUCKET=pawsey0964:oceanomics-refassemblies
NCPUS="${SLURM_CPUS_PER_TASK:-4}"

# Resolve this task's OG and paths from the samplesheet
mapfile -t SAMPLES < <(tail -n +2 "$SAMPLESHEET" | cut -d, -f1)
OG="${SAMPLES[$SLURM_ARRAY_TASK_ID]}"
ROW=$(grep "^${OG}," "$SAMPLESHEET")
HIC_DIR=$(echo "$ROW"  | cut -d, -f2)
ASSEMBLY_DIR=$(echo "$ROW" | cut -d, -f3)
MERYL_DIR=$(echo "$ROW"    | cut -d, -f4)

mkdir -p "$HIC_DIR" "$ASSEMBLY_DIR" "$MERYL_DIR"
echo "=== Staging $OG (task ${SLURM_ARRAY_TASK_ID}) ==="
date

# ── 1. HiC ───────────────────────────────────────────────────────────────────
# List all files for this OG in the HiC bucket, then copy each in parallel.
# rclone copy <remote_full_path> <local_dir/> writes the file flat (no subdirs).
echo ""
echo "[1/3] HiC → $HIC_DIR"
rclone ls "$HIC_BUCKET" --include "${OG}*" 2>/dev/null \
  | awk '{print $2}' \
  | xargs -r -P "$NCPUS" -I{} \
      rclone copy "${HIC_BUCKET}/{}" "${HIC_DIR}/"
echo "HiC done."

# ── 2. Assembly ──────────────────────────────────────────────────────────────
# Find the combined-scaffolds FASTA under the OG's bucket prefix.
echo ""
echo "[2/3] Assembly → $ASSEMBLY_DIR"
rclone lsf --recursive "${ASSEMBLY_BUCKET}/${OG}" \
    --include "*hap1.hap2_combined_scaffolds.fa" 2>/dev/null \
  | xargs -r -P "$NCPUS" -I{} \
      rclone copy "${ASSEMBLY_BUCKET}/${OG}/{}" "${ASSEMBLY_DIR}/"
echo "Assembly done."

# ── 3. Meryl ─────────────────────────────────────────────────────────────────
# Download tarball(s), extract, remove archive.
echo ""
echo "[3/3] Meryl → $MERYL_DIR"
rclone lsf --recursive "${ASSEMBLY_BUCKET}/${OG}" \
    --include "*meryl*.tar.gz" 2>/dev/null \
  | xargs -r -P "$NCPUS" -I{} \
      rclone copy "${ASSEMBLY_BUCKET}/${OG}/{}" "${MERYL_DIR}/"

for f in "${MERYL_DIR}"/*.tar.gz; do
  [[ -f "$f" ]] || continue
  echo "Extracting $(basename "$f")..."
  tar -xzf "$f" -C "${MERYL_DIR}"
  rm -f "$f"
done
echo "Meryl done."

echo ""
echo "=== Complete: $OG ===" && date
