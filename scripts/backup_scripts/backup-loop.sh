#!/usr/bin/env bash
# backup-loop.sh — submit one backup SLURM job per OG from the samplesheet
# Usage: bash backup-loop.sh [samplesheet] [base_dir]
# Prints all submitted job IDs to stdout (one per line) — capture with $() or mapfile.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLESHEET="${1:-/scratch/pawsey0964/$USER/post_curation/OceanOmics-OceanGenomes-post-curation/assets/samplesheet.csv}"
BASE_DIR="${2:-/scratch/pawsey0964/$USER/post_curation/post-curation}"

[[ -f "$SAMPLESHEET" ]] || { echo "Samplesheet not found: $SAMPLESHEET" >&2; exit 1; }

while IFS=',' read -r sample hic_dir assembly meryldb agp version date genomesize; do
    job_id=$(sbatch --parsable "$SCRIPTS_DIR/backup.sh" "$sample" "$date" "$version" "$BASE_DIR")
    echo "$job_id"
    echo "  Submitted backup: $sample $date $version → job $job_id" >&2
done < <(tail -n +2 "$SAMPLESHEET")
