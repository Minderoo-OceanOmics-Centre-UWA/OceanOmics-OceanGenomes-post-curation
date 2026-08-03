#!/bin/bash --login
#SBATCH --account=pawsey1348
#SBATCH --job-name=ocean-genomes-backup
#SBATCH --partition=work
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=12:00:00
#SBATCH --export=NONE
# Add your own --mail-user / --mail-type directives if you want job notifications.

OG=$1
date=$2
version=$3
BASE_DIR="${4:-/scratch/pawsey0964/$USER/post_curation/post-curation}"
asm_ver="${OG}_${date}.${version}"

if [[ -z "$OG" || ! -d "$BASE_DIR/$OG" ]]; then
  echo "Error: Missing or invalid input directory: $BASE_DIR/$OG"
  exit 1
fi

REMOTE="pawsey0964:oceanomics-refassemblies/${OG}/${asm_ver}"
D="$BASE_DIR/$OG"

# Every transfer is copied then immediately verified with `rclone check --checksum
# --one-way`. Failures are counted and reported in a summary at the end; the script
# exits non-zero if anything failed to copy or failed verification.
FAILURES=0
FAILED_ITEMS=()

copy_and_check() {
  local src="$1" dst="$2"

  echo "--- Backing up: $src -> $dst"

  if [[ ! -e "$src" ]]; then
    echo "    [FAIL] source does not exist"
    FAILURES=$((FAILURES + 1))
    FAILED_ITEMS+=("missing source: $src")
    return 1
  fi

  if ! rclone copy "$src" "$dst" --checksum --progress; then
    echo "    [FAIL] rclone copy failed"
    FAILURES=$((FAILURES + 1))
    FAILED_ITEMS+=("copy failed: $src")
    return 1
  fi

  if ! rclone check "$src" "$dst" --checksum --one-way; then
    echo "    [FAIL] rclone check mismatch"
    FAILURES=$((FAILURES + 1))
    FAILED_ITEMS+=("check failed: $src")
    return 1
  fi

  echo "    [OK] verified"
  return 0
}

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
copy_and_check "${D}/busco/" "${REMOTE}/busco"

# Gfastats
copy_and_check "${D}/gfastats/${asm_ver}.3.curated.hap1.assembly_summary.txt" "${REMOTE}/gfastats"
copy_and_check "${D}/gfastats/${asm_ver}.3.curated.hap2.assembly_summary.txt" "${REMOTE}/gfastats"

# Merqury
copy_and_check "${D}/merqury/" "${REMOTE}/merqury"

# Curated assemblies and AGP files — paths differ by curation tool
if [[ "$CURATION_TOOL" == "rapid-curation" ]]; then
  cp "${D}/rapid-curation/Hap_1/${asm_ver}_hap1.chr_level.fa" "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.chr_level.fa"
  cp "${D}/update_mapping/${asm_ver}.hap2.chr_level_new.fa"    "${D}/update_mapping/${asm_ver}.3.curated.hap2.chr_level.fa"

  copy_and_check "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.chr_level.fa" "${REMOTE}/assembly"
  copy_and_check "${D}/update_mapping/${asm_ver}.3.curated.hap2.chr_level.fa"        "${REMOTE}/assembly"

  cp "${D}/rapid-curation/Hap_1/hap.agp" "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.agp"
  cp "${D}/rapid-curation/Hap_2/hap.agp" "${D}/rapid-curation/Hap_2/${asm_ver}.3.curated.hap2.agp"

  copy_and_check "${D}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.agp" "${REMOTE}/agp"
  copy_and_check "${D}/rapid-curation/Hap_2/${asm_ver}.3.curated.hap2.agp" "${REMOTE}/agp"

else
  # pretext-to-asm: outputs named ${asm_ver}_hap1.chr_level.fa / _hap2.chr_level.fa
  cp "${D}/pretext-to-asm/${asm_ver}_hap1.chr_level.fa" "${D}/pretext-to-asm/${asm_ver}.3.curated.hap1.chr_level.fa"
  cp "${D}/pretext-to-asm/${asm_ver}_hap2.chr_level.fa" "${D}/pretext-to-asm/${asm_ver}.3.curated.hap2.chr_level.fa"

  copy_and_check "${D}/pretext-to-asm/${asm_ver}.3.curated.hap1.chr_level.fa" "${REMOTE}/assembly"
  copy_and_check "${D}/pretext-to-asm/${asm_ver}.3.curated.hap2.chr_level.fa" "${REMOTE}/assembly"

  # AGP is the curated input file — backed up from the staged agp/ directory
  STAGED_AGP_DIR="${BASE_DIR}/../${OG}/agp"
  copy_and_check "${STAGED_AGP_DIR}/" "${REMOTE}/agp"
fi

# BAMs
copy_and_check "${D}/omnic_hap1" "${REMOTE}/bam/omnic_hap1"
copy_and_check "${D}/omnic_hap2" "${REMOTE}/bam/omnic_hap2"

# Pretext maps and snapshots
copy_and_check "${D}/pretextmap_hap_1"     "${REMOTE}/pretext/hap1"
copy_and_check "${D}/pretextmap_hap_2"     "${REMOTE}/pretext/hap2"
copy_and_check "${D}/pretextsnapshot_hap1" "${REMOTE}/pretext_snapshots/hap1"
copy_and_check "${D}/pretextsnapshot_hap2" "${REMOTE}/pretext_snapshots/hap2"

# Stats
copy_and_check "${D}/calculate_stats/${asm_ver}.stats_output.txt"            "${REMOTE}/stats"
copy_and_check "${D}/calculate_stats/${asm_ver}.percentage_stats_output.txt" "${REMOTE}/stats"

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Backup summary: ${asm_ver} ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All transfers copied and verified with rclone check."
  exit 0
else
  echo "${FAILURES} transfer(s) failed:"
  for item in "${FAILED_ITEMS[@]}"; do
    echo "  - $item"
  done
  exit 1
fi
