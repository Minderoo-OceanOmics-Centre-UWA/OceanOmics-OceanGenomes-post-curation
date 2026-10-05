#!/usr/bin/env bash
#SBATCH --job-name=stage_post_curation
#SBATCH --array=0-6
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=8:00:00
#SBATCH --account=pawsey0964
#SBATCH --partition=work
#SBATCH --output=/scratch/pawsey0964/%u/post_curation/logs/stage_%A_%a.log
#SBATCH --error=/scratch/pawsey0964/%u/post_curation/logs/stage_%A_%a.log

# One SLURM task per OG — all 7 OGs download in parallel.
# Within each task, per-file copies run in parallel via xargs -P.
#
# Submit: sbatch stage_data.slurm
# Monitor: squeue -u $USER
#          tail -f /scratch/pawsey0964/$USER/post_curation/logs/stage_<jobid>_<taskid>.log

set -euo pipefail

module load rclone/1.68.1

SAMPLESHEET=/scratch/pawsey0964/${USER}/post_curation/OceanOmics-OceanGenomes-post-curation/assets/samplesheet.csv
HIC_BUCKET=s3:ocom-oceangenomes/illumina-hic
ASSEMBLY_BUCKET=pawsey0964:oceanomics-refassemblies
NCPUS="${SLURM_CPUS_PER_TASK:-4}"

# Resolve this task's OG and paths from the samplesheet
mapfile -t SAMPLES < <(tail -n +2 "$SAMPLESHEET" | cut -d, -f1)
OG="${SAMPLES[$SLURM_ARRAY_TASK_ID]}"
ROW=$(grep "^${OG}," "$SAMPLESHEET")
HIC_DIR=$(echo "$ROW"  | cut -d, -f2)
ASSEMBLY_DIR=$(echo "$ROW" | cut -d, -f3)
MERYL_DIR=$(echo "$ROW"    | cut -d, -f4)
AGP_DIR=$(echo "$ROW"      | cut -d, -f5)
VERSION=$(echo "$ROW"      | cut -d, -f6)
DATE=$(echo "$ROW"         | cut -d, -f7)
# Assembly being curated, as named in the bucket: <OG>_<date>.<version>/
ASM_FOLDER="${OG}_${DATE}.${VERSION}"

mkdir -p "$HIC_DIR" "$ASSEMBLY_DIR" "$MERYL_DIR" "$AGP_DIR"
echo "=== Staging $OG (task ${SLURM_ARRAY_TASK_ID}) ==="
date

# Check the samplesheet version/date match an assembly in the bucket before downloading anything
if ! rclone lsf --dirs-only "${ASSEMBLY_BUCKET}/${OG}" 2>/dev/null | grep -Fx "${ASM_FOLDER}/" >/dev/null; then
  echo "ERROR: ${ASSEMBLY_BUCKET}/${OG}/${ASM_FOLDER}/ not found — check version/date in $SAMPLESHEET" >&2
  echo "Available:" >&2
  rclone lsf --dirs-only "${ASSEMBLY_BUCKET}/${OG}" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
echo "Assembly: ${ASM_FOLDER}"

# ── 1. HiC ───────────────────────────────────────────────────────────────────
# List all files for this OG in the HiC bucket, then copy each in parallel.
# rclone copy <remote_full_path> <local_dir/> writes the file flat (no subdirs).
# The grep drops other OGs sharing the prefix (e.g. OG5 vs OG52).
echo ""
echo "[1/3] HiC → $HIC_DIR"
rclone lsf --recursive --files-only "$HIC_BUCKET" 2>/dev/null \
  | grep -E "(^|/)${OG}([^0-9]|$)" \
  | xargs -r -P "$NCPUS" -I{} \
      rclone copy "${HIC_BUCKET}/{}" "${HIC_DIR}/"
echo "HiC done."

# ── 2. Assembly ──────────────────────────────────────────────────────────────
# Find the combined-scaffolds FASTA under this version's folder only.
echo ""
echo "[2/3] Assembly → $ASSEMBLY_DIR"
rclone lsf --recursive --files-only "${ASSEMBLY_BUCKET}/${OG}/${ASM_FOLDER}" \
    --include "*hap1.hap2_combined_scaffolds.fa" 2>/dev/null \
  | xargs -r -P "$NCPUS" -I{} \
      rclone copy "${ASSEMBLY_BUCKET}/${OG}/${ASM_FOLDER}/{}" "${ASSEMBLY_DIR}/"
compgen -G "${ASSEMBLY_DIR}/*hap1.hap2_combined_scaffolds.fa" > /dev/null \
  || { echo "ERROR: no combined scaffolds FASTA found in ${ASM_FOLDER}" >&2; exit 1; }
echo "Assembly done."

# ── 3. Meryl ─────────────────────────────────────────────────────────────────
# Download tarball(s), extract, remove archive.
echo ""
echo "[3/3] Meryl → $MERYL_DIR"
rclone lsf --recursive --files-only "${ASSEMBLY_BUCKET}/${OG}" \
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
