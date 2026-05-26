#!/bin/bash --login
#SBATCH --account=pawsey1348
#SBATCH --job-name=rebuild-meryl
#SBATCH --partition=work
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=12:00:00
#SBATCH --export=NONE
#SBATCH --output=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/logs/rebuild_meryl_%j.log
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=lauren.huet@uwa.edu.au

set -euo pipefail

module load singularity/4.1.0-slurm rclone/1.68.1

MERQURY_IMG=/software/projects/pawsey0964/lhuet/.nextflow_singularity/depot.galaxyproject.org-singularity-merqury-1.3--hdfd78af_1.img
MERYL_OUTBASE=/scratch/pawsey0964/lhuet/post_curation
HIFI_BASE=/scratch/pawsey0964/lhuet/ref-gen1
ACACIA_BASE="pawsey0964:oceanomics-refassemblies"
THREADS=16

declare -A OG_VERSION
OG_VERSION[OG111]=v241018
OG_VERSION[OG648]=v250704
OG_VERSION[OG652]=v240327
OG_VERSION[OG658]=v240327
OG_VERSION[OG721]=v240501

declare -A OG_VER_SHORT
OG_VER_SHORT[OG111]=hic1
OG_VER_SHORT[OG648]=hic1
OG_VER_SHORT[OG652]=hic1
OG_VER_SHORT[OG658]=hic1
OG_VER_SHORT[OG721]=hic1

for OG in OG111 OG648 OG652 OG658 OG721; do
    DATE="${OG_VERSION[$OG]}"
    VER="${OG_VER_SHORT[$OG]}"
    MERYL_NAME="${OG}_${DATE}.${VER}.meryl"
    OUTDIR="${MERYL_OUTBASE}/${OG}/meryl/${MERYL_NAME}"
    FASTQ="${HIFI_BASE}/${OG}/01-data-processing/fastqs_cat_hifi/${OG}_${DATE}.${VER}.hifi.cat.fastq.gz"

    echo "=== Building meryl for $OG → $OUTDIR ==="
    mkdir -p "${MERYL_OUTBASE}/${OG}/meryl"

    if [[ ! -f "$FASTQ" ]]; then
        echo "ERROR: HiFi FASTQ not found for $OG: $FASTQ" >&2
        exit 1
    fi
    echo "  Input FASTQ: $FASTQ"

    # Remove old empty database if it exists
    rm -rf "${OUTDIR}"

    # Run meryl count from adapter-filtered HiFi FASTQ
    singularity exec \
        --bind /scratch,/software \
        "$MERQURY_IMG" \
        meryl count k=21 threads="${THREADS}" \
            output "${OUTDIR}" \
            "${FASTQ}"

    echo "  Built: $OUTDIR"
    ls "${OUTDIR}" | head -3

    # Back up to Acacia as a directory (same style as OG106 hifi1.meryldb)
    ACACIA_DEST="${ACACIA_BASE}/${OG}/meryl/${MERYL_NAME}/"
    echo "  Uploading to Acacia: $ACACIA_DEST"
    rclone copy "${OUTDIR}/" "${ACACIA_DEST}" --checksum --progress
    echo "  [OK] $OG done"
    echo ""
done

echo "=== All meryl databases rebuilt and backed up ==="
