#!/usr/bin/env bash
set -u

# backup_audit.sh
# Verify files copied to rclone remote `pawsey964:oceanomics-refassemblies/...`
# Usage:
#   backup_audit.sh OG DATE VER         # check single assembly
#   backup_audit.sh --samplesheet FILE  # iterate samplesheet like backup-loop.sh
#   backup_audit.sh --all               # iterate default samplesheet
#   backup_audit.sh -n ...              # dry-run (no rclone calls)

SCRIPTS_DIR=$(dirname "${BASH_SOURCE[0]}")
DEFAULT_SAMPLESHEET=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/assets/samplesheet_04_02_2025.csv

DRY_RUN=0
SAMPLESHEET=""
OUTDIR=""

print_usage(){
  cat <<EOF
Usage: $0 [options] OG DATE VER
  -n|--dry-run        show checks but don't run rclone
  --samplesheet FILE  iterate rows from FILE (skips header)
  --all               use default samplesheet
  OG DATE VER         check a single assembly
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -o|--outdir) OUTDIR="$2"; shift 2 ;;
    --samplesheet) SAMPLESHEET="$2"; shift 2 ;;
    --all) SAMPLESHEET="$DEFAULT_SAMPLESHEET"; shift ;;
    -h|--help) print_usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option $1"; print_usage; exit 1 ;;
    *) break ;;
  esac
done

# prepare output file: default to scripts/logs with timestamp
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$SCRIPTS_DIR/logs"
fi
mkdir -p "$OUTDIR"
TS=$(date '+%Y%m%d_%H%M%S')
OUTFILE="$OUTDIR/audit_${TS}.txt"
# tee all output to outfile
exec > >(tee -a "$OUTFILE") 2>&1
echo "Audit started: $(date --iso-8601=seconds)" | tee -a "$OUTFILE"
echo "Log file: $OUTFILE" | tee -a "$OUTFILE"

run_check(){
  local src="$1" dst="$2" label="$3"
  echo "Checking: $label"
  echo "  local: $src"
  echo "  remote: ${dst}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would run: rclone check \"$src\" \"$dst\" --checksum --one-way"
    return 0
  fi
  # run rclone check and capture status
  rclone check "$src" "$dst" --checksum --one-way
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  OK"
  else
    echo "  MISMATCH or ERROR (rclone exit code $rc)"
  fi
  return $rc
}

audit_one(){
  local OG="$1" date="$2" ver="$3"
  local asm_ver="${OG}_${date}.${ver}"
  local sample="$OG"
  echo "== Audit: ${sample} / ${asm_ver} =="

  # list of checks: each line is "src|remote_path_suffix|label"
  checks=(
    "${OG}/busco/|${sample}/${asm_ver}/busco|busco/"
    "${OG}/gfastats/${asm_ver}.3.curated.hap1.assembly_summary.txt|${sample}/${asm_ver}/gfastats|gfastats_hap1_summary"
    "${OG}/gfastats/${asm_ver}.3.curated.hap2.assembly_summary.txt|${sample}/${asm_ver}/gfastats|gfastats_hap2_summary"
    "${OG}/merqury/|${sample}/${asm_ver}/merqury|merqury/"
    "${OG}/update_mapping/${asm_ver}.3.curated.hap2.chr_level.fa|${sample}/${asm_ver}/assembly|assembly_hap2.fa"
    "${OG}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.chr_level.fa|${sample}/${asm_ver}/assembly|assembly_hap1.fa"
    "${OG}/rapid-curation/Hap_1/${asm_ver}.3.curated.hap1.agp|${sample}/${asm_ver}/agp|agp_hap1"
    "${OG}/rapid-curation/Hap_2/${asm_ver}.3.curated.hap2.agp|${sample}/${asm_ver}/agp|agp_hap2"
    "${OG}/omnic_hap1|${sample}/${asm_ver}/bam/omnic_hap1|bam_omnic_hap1"
    "${OG}/omnic_hap2|${sample}/${asm_ver}/bam/omnic_hap2|bam_omnic_hap2"
    "${OG}/pretextmap_hap_1|${sample}/${asm_ver}/pretext/hap1|pretext_hap1"
    "${OG}/pretextmap_hap_2|${sample}/${asm_ver}/pretext/hap2|pretext_hap2"
    "${OG}/pretextsnapshot_hap1|${sample}/${asm_ver}/pretext_snapshots/hap1|pretext_snapshot_hap1"
    "${OG}/pretextsnapshot_hap2|${sample}/${asm_ver}/pretext_snapshots/hap2|pretext_snapshot_hap2"
    "${OG}/calculate_stats/${asm_ver}.stats_output.txt|${sample}/${asm_ver}/stats|stats_output"
    "${OG}/calculate_stats/${asm_ver}.percentage_stats_output.txt|${sample}/${asm_ver}/stats|percentage_stats_output"
  )

  failures=0
  for entry in "${checks[@]}"; do
    IFS='|' read -r src remote_suffix label <<< "$entry"
    dst="pawsey0964:oceanomics-refassemblies/${remote_suffix}"
    run_check "$src" "$dst" "$label"
    rc=$?
    if [[ $rc -ne 0 ]]; then failures=$((failures+1)); fi
  done

  if [[ $failures -eq 0 ]]; then
    echo "== RESULT: All checks passed for ${asm_ver} =="
  else
    echo "== RESULT: ${failures} mismatches/errors for ${asm_ver} =="
  fi
  return $failures
}

if [[ -n "$SAMPLESHEET" ]]; then
  if [[ ! -f "$SAMPLESHEET" ]]; then
    echo "Samplesheet not found: $SAMPLESHEET"; exit 1
  fi
  tail -n +2 "$SAMPLESHEET" | while IFS=',' read -r sample hic_dir assembly meryldb agp version date genomesize; do
    audit_one "$sample" "$date" "$version"
  done
  exit 0
fi

if [[ $# -eq 3 ]]; then
  audit_one "$1" "$2" "$3"
  exit $?
fi

print_usage
exit 1
