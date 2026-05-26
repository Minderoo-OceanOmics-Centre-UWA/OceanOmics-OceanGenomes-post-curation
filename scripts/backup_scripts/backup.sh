#!/bin/bash --login
#SBATCH --account=pawsey1348
#SBATCH --job-name=ocean-genomes-backup
#SBATCH --partition=work
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=12:00:00
#SBATCH --export=NONE
#SBATCH --mail-type=BEGIN,END
#SBATCH --mail-user=lauren.huet@uwa.edu.au

OG=$1
date=$2
version=$3
BASE_DIR="${4:-/scratch/pawsey0964/lhuet/post_curation/post-curation}"
asm_ver="${OG}_${date}.${version}"

if [[ -z "$OG" || ! -d "$BASE_DIR/$OG" ]]; then
  echo "Error: Missing or invalid input directory: $BASE_DIR/$OG"
  exit 1
fi

REMOTE="pawsey0964:oceanomics-refassemblies/${OG}/${asm_ver}"
D="$BASE_DIR/$OG"

# Determine which curation tool was used
if [[ -d "${D}/pretext-to-asm" ]]; then
  CURATION_TOOL="pretext-to-asm"
elif [[ -d "${D}/rapid-curation" ]]; then
  CURATION_TOOL="rapid-curation"
else
  echo "Error: No curation output directory found in $D"
  exit 1
fi

echo "Curation tool: $CURATION_TOOL"

# BUSCO
rclone copy "${D}/busco/" "${REMOTE}/busco" --checksum --progress

# Gfastats
rclone copy "${D}/gfastats/${asm_ver}.3.curated.hap1.assembly_summary.txt" "${REMOTE}/gfastats" --checksum --progress
rclone copy "${D}/gfastats/${asm_ver}.3.curated.hap2.assembly_summary.txt" "${REMOTE}/gfastats" --checksum --progress

# Merqury
rclone copy "${D}/merqury/" "${REMOTE}/merqury" --checksum --progress

# Curated assemblies and AGP files — paths differ by curation tool
if [[ "$CURATION_TOOL" == "rapid-curation" ]]; then
  cp "${D}/rapid-curation/Hap_1/${asm_ver}_hap1.chr_level.fa" "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.chr_level.fa"
  cp "${D}/update_mapping/${asm_ver}.hap2.chr_level_new.fa"    "${D}/update_mapping/${asm_ver}.3.curated.hap2.chr_level.fa"

  rclone copy "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.chr_level.fa" "${REMOTE}/assembly" --checksum --progress
  rclone copy "${D}/update_mapping/${asm_ver}.3.curated.hap2.chr_level.fa"        "${REMOTE}/assembly" --checksum --progress

  cp "${D}/rapid-curation/Hap_1/hap.agp" "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.agp"
  cp "${D}/rapid-curation/Hap_2/hap.agp" "${D}/rapid-curation/Hap_2/${asm_ver}.3.curated.hap2.agp"

  rclone copy "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.agp" "${REMOTE}/agp" --checksum --progress
  rclone copy "${D}/rapid-curation/Hap_2/${asm_ver}.3.curated.hap2.agp" "${REMOTE}/agp" --checksum --progress

else
  # pretext-to-asm: outputs named ${asm_ver}_hap1.chr_level.fa / _hap2.chr_level.fa
  cp "${D}/pretext-to-asm/${asm_ver}_hap1.chr_level.fa" "${D}/pretext-to-asm/${asm_ver}.3.curated.hap1.chr_level.fa"
  cp "${D}/pretext-to-asm/${asm_ver}_hap2.chr_level.fa" "${D}/pretext-to-asm/${asm_ver}.3.curated.hap2.chr_level.fa"

  rclone copy "${D}/pretext-to-asm/${asm_ver}.3.curated.hap1.chr_level.fa" "${REMOTE}/assembly" --checksum --progress
  rclone copy "${D}/pretext-to-asm/${asm_ver}.3.curated.hap2.chr_level.fa" "${REMOTE}/assembly" --checksum --progress

  # AGP is the curated input file — backed up from the staged agp/ directory
  STAGED_AGP_DIR="${BASE_DIR}/../${OG}/agp"
  rclone copy "${STAGED_AGP_DIR}/" "${REMOTE}/agp" --checksum --progress
fi

# BAMs
rclone copy "${D}/omnic_hap1" "${REMOTE}/bam/omnic_hap1" --checksum --progress
rclone copy "${D}/omnic_hap2" "${REMOTE}/bam/omnic_hap2" --checksum --progress

# Pretext maps and snapshots
rclone copy "${D}/pretextmap_hap_1"     "${REMOTE}/pretext/hap1"           --checksum --progress
rclone copy "${D}/pretextmap_hap_2"     "${REMOTE}/pretext/hap2"           --checksum --progress
rclone copy "${D}/pretextsnapshot_hap1" "${REMOTE}/pretext_snapshots/hap1" --checksum --progress
rclone copy "${D}/pretextsnapshot_hap2" "${REMOTE}/pretext_snapshots/hap2" --checksum --progress

# Stats
rclone copy "${D}/calculate_stats/${asm_ver}.stats_output.txt"            "${REMOTE}/stats" --checksum --progress
rclone copy "${D}/calculate_stats/${asm_ver}.percentage_stats_output.txt" "${REMOTE}/stats" --checksum --progress
