# OceanGenomes Post-Curation Pipeline — Pawsey Automated Run Guide

This document covers the end-to-end workflow on Pawsey Setonix, from staging input data through running the Nextflow pipeline to compiling QC results, pushing to the database, and backing up outputs to Acacia.

---

## Quick start

```
1. Edit config      →  scripts/postcuration_pipeline.conf
2. Stage data       →  bash scripts/stage_all.sh
3. Add AGP files    →  scp from local machine into each OG's agp/ dir
4. Run pipeline     →  bash scripts/postcuration_run.sh
```

That's it. Details for each step below.

---

## Prerequisites

| Requirement | Location |
|---|---|
| Singularity containers | `/software/projects/pawsey0964/singularity/` |
| PostgreSQL credentials | `~/postgresql_details/oceanomics.cfg` |
| rclone configured | `~/.config/rclone/rclone.conf` (remotes: `pawsey0964`, `s3`) |
| Nextflow | loaded at login via `nextflow/24.10.0` module |
| BUSCO database | `/scratch/references/busco_db/actinopterygii_odb10` |
| Meryl databases | pre-built per OG on Acacia (staged automatically in Step 2) |
| Curated AGP files | exported from PretextView after manual curation (you provide these) |

---

## Step 1 — Edit the config

All OG IDs and paths are controlled by one file:

```
scripts/postcuration_pipeline.conf
```

The only thing you need to update each run is `OG_IDS`:

```bash
OG_IDS=OG696,OG775,OG778,OG824
```

Other settings you may occasionally need to change:

| Key | Description |
|---|---|
| `STAGING_BASE_DIR` | Root dir for staged inputs and pipeline outputs |
| `SAMPLESHEET` | Path where the generated samplesheet is written |
| `HIC_BUCKET` | rclone remote for Hi-C reads |
| `ASSEMBLY_BUCKET` | rclone remote for assemblies + meryl |

The `{user}` placeholder in paths is automatically replaced with `$USER` at runtime.

---

## Step 2 — Stage input data

```bash
cd /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation
bash scripts/stage_all.sh
```

This does three things in one command:

1. **Generates the samplesheet** — queries the OceanOmics PostgreSQL DB to build `assets/samplesheet.csv` with genome sizes, sequencing dates, and staged paths for each OG
2. **Creates per-OG directories** — `hic/`, `assembly/`, `meryl/`, `agp/` under `STAGING_BASE_DIR`
3. **Downloads data in parallel** — Hi-C reads, assembly FASTAs, and Meryl databases are downloaded simultaneously in background processes; the script waits for all three to finish before exiting

Logs are written to `logs/hic_<stamp>.log`, `logs/assembly_<stamp>.log`, `logs/meryl_<stamp>.log`.

To skip samplesheet regeneration (e.g. if you're re-staging after a partial failure):

```bash
bash scripts/stage_all.sh --no-samplesheet
```

**Expected directory structure after staging:**

```
post_curation/
└── OG696/
    ├── hic/        ← Hi-C FASTQs (R1 + R2)
    ├── assembly/   ← combined-scaffolds FASTA
    ├── meryl/      ← Meryl k-mer database
    └── agp/        ← AGP file (you add this in Step 3)
```

---

## Step 3 — Add AGP files

AGP files are exported from PretextView on your local machine after manual curation. Transfer them to Setonix and place them in each OG's `agp/` directory.

**Naming convention:** `{OG}_{date}.{version}.*.agp*`
Example: `OG696_v240228.hic1.scaffolds.dual.map.pretext.agp_2`

The `{date}` and `{version}` parts must match the values in `assets/samplesheet.csv`.

```bash
# From your local machine — transfer directly into the agp/ dirs
scp OG696_v240228.hic1.*.agp* lhuet@setonix.pawsey.org.au:/scratch/pawsey0964/lhuet/post_curation/OG696/agp/

# Or drop into the staging root and auto-sort:
for f in /scratch/pawsey0964/lhuet/post_curation/OG*_v*.agp*; do
  og=$(basename "$f" | grep -o 'OG[0-9]*')
  [[ -n "$og" ]] && mv "$f" "/scratch/pawsey0964/lhuet/post_curation/${og}/agp/"
done
```

**Verify everything is in place before running the pipeline:**

```bash
STAGING=/scratch/pawsey0964/lhuet/post_curation
tail -n +2 assets/samplesheet.csv | cut -d, -f1 | while read og; do
  echo "$og | HiC: $(ls $STAGING/$og/hic/*.fastq.gz 2>/dev/null | wc -l) \
  | Asm: $(ls $STAGING/$og/assembly/*.fa 2>/dev/null | wc -l) \
  | Meryl: $(ls -d $STAGING/$og/meryl/*.meryl 2>/dev/null | wc -l) \
  | AGP: $(ls $STAGING/$og/agp/*.agp* 2>/dev/null | wc -l)"
done
```

All counts should be ≥ 1 before proceeding.

---

## Step 4 — Run the pipeline

Launch from inside a **tmux session** so it keeps running after you disconnect:

```bash
tmux new-session -s post_curation   # or: tmux attach -t post_curation

cd /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation
bash scripts/postcuration_run.sh
```

`postcuration_run.sh` runs the full automated pipeline:

1. **Nextflow pipeline** — RAPID_CURATION (or PRETEXT_TO_ASM) → BUSCO → Merqury → gfastats → CALCULATE_STATS → Hi-C mapping → PretextMap → MultiQC
2. **Compile QC results** — produces TSV files from all QC outputs
3. **Push to PostgreSQL** — upserts all metrics into the `ref_genomes` table
4. **Backup to Acacia** — submits one SLURM job per OG to rclone outputs
5. **Audit** — submits a SLURM job (runs after all backups) to verify remote copies

### Curation tool

The default curation tool is `rapid-curation`. To use `pretext-to-asm` instead:

```bash
bash scripts/postcuration_run.sh --curation-tool=pretext-to-asm
```

### Monitoring

```bash
# SLURM jobs submitted by Nextflow
squeue -u $USER

# Nextflow progress is printed to the tmux terminal
# Detailed process log:
tail -f logs/nextflow_<timestamp>.log

# Check which processes failed:
nextflow log <run-name> -f name,status,exit,work_dir | grep -v -E "COMPLETED|CACHED"
```

---

## Step 4b — Re-run post-pipeline steps only

If Nextflow completed successfully but compile/push/backup failed:

```bash
bash scripts/post_pipeline.sh scripts/postcuration_pipeline.conf
```

All DB inserts use `ON CONFLICT ... DO UPDATE`, so re-running is safe.

---

## Outputs

### On scratch

All pipeline outputs are written to `$STAGING_BASE_DIR/post-curation/<OG_ID>/`:

```
<OG_ID>/
├── rapid-curation/          # or pretext-to-asm/ — split haplotype FASTAs + AGPs
├── update_mapping/          # hap2 with sequence IDs updated to match hap1
├── busco/                   # BUSCO completeness
├── merqury/                 # QV scores and completeness
├── gfastats/                # N50, L50, contig counts
├── calculate_stats/         # % sequences assigned to chromosomes
├── omnic_hap1/              # Hi-C BAMs (hap1)
├── omnic_hap2/              # Hi-C BAMs (hap2)
├── pretextmap_hap_1/        # PretextMap contact map (hap1)
├── pretextmap_hap_2/        # PretextMap contact map (hap2)
├── pretextsnapshot_hap1/    # PNG snapshot (hap1)
├── pretextsnapshot_hap2/    # PNG snapshot (hap2)
└── multiqc/                 # Per-run MultiQC HTML report
```

### On Acacia

Each OG is backed up to `pawsey0964:oceanomics-refassemblies/<OG>/<OG>_<date>.<version>/`:

```
assembly/        curated hap1 and hap2 FASTAs
agp/             curated AGP files
busco/
merqury/
gfastats/
bam/omnic_hap1/
bam/omnic_hap2/
pretext/hap1/
pretext/hap2/
pretext_snapshots/hap1/
pretext_snapshots/hap2/
stats/           stats_output.txt + percentage_stats_output.txt
```

MultiQC report: `pawsey0964:oceanomics-refassemblies/postcuration_multiqc/<date>_post_curation_multiqc_report.html`

### In the database

Results are upserted into `ref_genomes` keyed on `(og_id, seq_date, stage, haplotype, version)`:

| Script | Columns populated |
|---|---|
| `02b_push_merqury_qv_results_to_sqldb.py` | `qv`, `error`, `unique_k_mers_assembly`, `k_mers_total` |
| `02d_push_merqury_completeness_results_to_sqldb.py` | `solid_k_mers`, `total_k_mers`, `completeness` |
| `03a_push_busco_results_to_sqldb.py` | `complete`, `single_copy`, `multi_copy`, `fragmented`, `missing`, `n_markers`, `scaffold_n50_bus`, etc. |
| `04a_push_gfa_results_to_sqldb.py` | `num_contigs`, `contig_n50`, `num_scaffolds`, `scaffold_n50`, `total_scaffold_length`, `gc_content_percent`, etc. |
| `05a_push_stats_compiled_results_to_sql.py` | `num_seqs`, `sum_len`, `min_len`, `avg_len`, `max_len` |
| `06b_push_percentage_stats_to_sqldb.py` | `num_chromosomes`, `pct_assigned`, `pct_no_super`, `num_seq_no_super`, `max_len_no_super` |

---

## Troubleshooting

### Nextflow pipeline failed

```bash
# Find failed processes
nextflow log <run-name> -f name,status,exit,work_dir | grep -v -E "COMPLETED|CACHED"

# Fix the issue, then resume from cache
bash scripts/postcuration_run.sh
```

### DB push failed

Re-run just the post-pipeline steps from existing pipeline outputs:

```bash
bash scripts/post_pipeline.sh scripts/postcuration_pipeline.conf
```

### Backup job failed

Re-run backup for a single OG:

```bash
sbatch scripts/backup_scripts/backup.sh <OG> <date> <version> /scratch/pawsey0964/lhuet/post_curation/post-curation
# e.g.:
sbatch scripts/backup_scripts/backup.sh OG55 v231115 hic1 /scratch/pawsey0964/lhuet/post_curation/post-curation
```

### OMNIC fails (pairtools sort out of space)

Ensure `--tempdir` points to a location with ≥100 GB free:

```bash
df -h /scratch/pawsey0964/lhuet/tmp
```

If low on space, set a different temp dir:

```bash
bash scripts/postcuration_run.sh --tempdir /scratch/pawsey0964/lhuet/tmp2
```

### Samplesheet has NULL values

The DB is missing a PacBio sequencing record or GenomeScope result for that OG. Check:

```bash
singularity run $SING/psycopg2:0.1.sif python - ~/postgresql_details/oceanomics.cfg << 'EOF'
import sys, configparser, psycopg2
pg = configparser.ConfigParser(); pg.read(sys.argv[1])
s = pg['postgres']
conn = psycopg2.connect(dbname=s['dbname'], user=s['user'], password=s['password'], host=s['host'], port=s['port'])
cur = conn.cursor()
cur.execute("SELECT og_id, seq_date FROM sequencing WHERE og_id = 'OG696' AND seq_type = 'PacBio'")
print(cur.fetchall())
EOF
```

---

## Script reference

| Script | Purpose |
|---|---|
| `scripts/postcuration_pipeline.conf` | Central config — edit OG IDs and paths here |
| `scripts/stage_all.sh` | Generate samplesheet + stage all input data from Acacia |
| `scripts/postcuration_run.sh` | Full run: Nextflow pipeline + compile + DB push + backup |
| `scripts/post_pipeline.sh` | Post-pipeline steps only (compile, push, backup, audit) |
| `scripts/0_create_samplesheet/create_samplesheet_from_config.py` | Generate samplesheet from DB + config |
| `scripts/backup_scripts/backup.sh` | SLURM job: rclone one OG's outputs to Acacia |
| `scripts/backup_scripts/backup-loop.sh` | Submit one backup job per OG from samplesheet |
| `scripts/backup_scripts/backup_audit.sh` | Verify remote copies match local outputs |
