# OceanOmics Post-Curation Pipeline — Pawsey Usage Guide

This guide covers running the post-curation pipeline on Setonix (Pawsey Supercomputing Centre) for the OceanOmics Ocean Genomes project.

---

## Pipeline position in the genome assembly workflow

```
PacBio HiFi + Hi-C reads
  └─> OceanOmics-OceanGenomes-ref-genomes (hifi_hic mode)
        └─> PretextMap contact map
              └─> Manual curation in PretextView (local)
                    └─> Export AGP file
                          └─> THIS PIPELINE (post-curation)
                                └─> Curated hap1/hap2 + QC metrics + DB push
```

**Inputs required:**
- Original combined-scaffolds FASTA from the assembly pipeline
- Hi-C FASTQ reads (R1 + R2)
- Meryl k-mer database (built during assembly)
- AGP file exported from PretextView after manual curation

---

## Prerequisites

- Pawsey account with access to the `pawsey0964` project
- `rclone` configured with `pawsey0964` (Acacia) and `s3` remotes
- PostgreSQL credentials at `~/postgresql_details/oceanomics.cfg`
- Singularity image: `$SING/psycopg2:0.1.sif` (`$SING=/software/projects/pawsey0964/singularity`)
- AGP files exported from PretextView on your local machine (one per OG)
- Pipeline cloned to: `/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/`

---

## Step 1 — Configure your OG samples

Edit the pipeline config file to set the OG IDs you want to process:

```bash
nano /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/scripts/postcuration_pipeline.conf
```

Update `OG_IDS` to a comma-separated list:

```
OG_IDS=OG696,OG676,OG775,OG55,OG659,OG778,OG824
```

Other key settings in this file:

| Key | Description |
|-----|-------------|
| `STAGING_BASE_DIR` | Root dir where per-OG data is staged (e.g. `/scratch/pawsey0964/lhuet/post_curation`) |
| `HIC_BUCKET` | rclone remote for Hi-C reads |
| `ASSEMBLY_BUCKET` | rclone remote for assemblies + meryl |
| `ASSEMBLY_GLOB_SUFFIX` | Filename suffix used to find the correct assembly FASTA |
| `NPROC` | Parallel file downloads within each staging script (default: 4) |

---

## Step 2 — Generate the samplesheet

The samplesheet is generated automatically from the OceanOmics PostgreSQL database. It pulls genome size and PacBio sequencing date for each OG.

```bash
SING=/software/projects/pawsey0964/singularity
SCRIPTS=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/scripts

singularity run $SING/psycopg2:0.1.sif python \
  $SCRIPTS/0_create_samplesheet/create_samplesheet_from_config.py \
  $SCRIPTS/postcuration_pipeline.conf
```

This writes two files:
- `assets/samplesheet_YYYYMMDD.csv` — dated copy
- `assets/samplesheet.csv` — latest (used by all downstream scripts)

The samplesheet has one row per OG with these columns:

| Column | Example | Description |
|--------|---------|-------------|
| `sample` | `OG696` | OG identifier |
| `hic_dir` | `.../OG696/hic` | Directory where Hi-C FASTQs will be staged |
| `assembly` | `.../OG696/assembly` | Directory where assembly FASTA will be staged |
| `meryldb` | `.../OG696/meryl` | Directory where meryl DB will be staged |
| `agp` | `.../OG696/agp` | Directory where you place the AGP file |
| `version` | `hic1` | Hi-C library version |
| `date` | `v240228` | PacBio sequencing date (v + YYMMDD) |
| `genomesize` | `1375723817` | Estimated genome size in bp (from GenomeScope) |

> **Note:** The `date` field (`vYYMMDD`) comes from the PacBio sequencing date in the DB and must match the prefix of the AGP filename exported from PretextView.

---

## Step 3 — Stage the data

All assembly data lives on Acacia (`pawsey0964:` remote) and Hi-C reads on S3 (`s3:` remote). You need to download them to scratch before running the pipeline.

### Recommended: SLURM array job

Submits one job per OG — all OGs download in parallel, with parallel per-file copies within each job. Much faster than running scripts manually on the login node.

```bash
# First check the array size matches your OG count
# (0-6 = 7 tasks for 7 OGs — adjust if different)
sbatch /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/scripts/stage_data.slurm

# Monitor jobs
squeue -u $USER

# Check per-OG logs
tail -f /scratch/pawsey0964/lhuet/post_curation/logs/stage_<jobid>_<taskid>.log
```

If you have a different number of OGs, update the `--array` line in `stage_data.slurm` before submitting (e.g. `--array=0-4` for 5 OGs).

### Alternative: single-command staging script

Runs all 3 data types (Hi-C, assembly, meryl) in parallel background jobs on the login node. Suitable for small batches.

```bash
cd /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/scripts
bash stage_all.sh                        # generates samplesheet + stages everything
bash stage_all.sh --no-samplesheet       # skip samplesheet regeneration
```

Logs are written to `/scratch/pawsey0964/lhuet/post_curation/logs/`.

### What gets staged

Each OG gets a directory structure under `STAGING_BASE_DIR`:

```
post_curation/
└── OG696/
    ├── hic/          ← Hi-C FASTQs (R1 + R2, flat — no subdirectories)
    ├── assembly/     ← Combined-scaffolds FASTA
    ├── meryl/        ← Meryl DB (extracted from tarball)
    └── agp/          ← AGP file (you provide this — see Step 4)
```

---

## Step 4 — Transfer the AGP files

AGP files are exported from PretextView on your local machine after manual curation. Transfer them to Setonix and place them in the correct `agp/` directory for each OG.

**Naming convention:** `{OG}_{date}.{version}.*.agp*`
For example: `OG696_v240228.hic1.scaffolds.dual.map.pretext.agp_2`

The `{date}` and `{version}` parts must match the values in the samplesheet.

**Transfer from your local machine:**

```bash
# From your local computer
scp OG696_v240228.hic1.*.agp* lhuet@setonix.pawsey.org.au:/scratch/pawsey0964/lhuet/post_curation/OG696/agp/

# Or transfer multiple at once
scp OG*_v*.hic*.agp* lhuet@setonix.pawsey.org.au:/scratch/pawsey0964/lhuet/post_curation/
```

If you drop AGP files into the staging base directory rather than the `agp/` subdirectory, you can move them to the right place with:

```bash
for f in /scratch/pawsey0964/lhuet/post_curation/OG*_v*.agp*; do
  og=$(basename "$f" | grep -o 'OG[0-9]*')
  [[ -n "$og" ]] && mv "$f" "/scratch/pawsey0964/lhuet/post_curation/${og}/agp/"
done
```

---

## Step 5 — Verify staging is complete

Before launching the pipeline, confirm all required files are present for each OG:

```bash
STAGING=/scratch/pawsey0964/lhuet/post_curation
SAMPLESHEET=$STAGING/OceanOmics-OceanGenomes-post-curation/assets/samplesheet.csv

tail -n +2 "$SAMPLESHEET" | cut -d, -f1 | while read og; do
  hic_count=$(ls "$STAGING/$og/hic/"*.fastq.gz 2>/dev/null | wc -l)
  asm_count=$(ls "$STAGING/$og/assembly/"*.fa 2>/dev/null | wc -l)
  meryl_count=$(ls -d "$STAGING/$og/meryl/"*.meryl 2>/dev/null | wc -l)
  agp_count=$(ls "$STAGING/$og/agp/"*.agp* 2>/dev/null | wc -l)
  echo "$og | HiC: $hic_count | Assembly: $asm_count | Meryl: $meryl_count | AGP: $agp_count"
done
```

Expected output (all counts ≥ 1):
```
OG55   | HiC: 2 | Assembly: 1 | Meryl: 1 | AGP: 1
OG659  | HiC: 2 | Assembly: 1 | Meryl: 1 | AGP: 1
...
```

> **AGP count of 0** means the AGP file has not yet been transferred — wait until you have all AGP files before running the pipeline.

---

## Step 6 — Run the Nextflow pipeline

The pipeline must be launched from within a **tmux session** on Setonix so it keeps running after you disconnect.

```bash
# Create or attach to a tmux session
tmux new-session -s post_curation_nf
# or: tmux attach -t post_curation_nf

cd /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation

bash nextflow_run.sh
```

The `nextflow_run.sh` script runs:

```bash
nextflow run main.nf \
  -profile singularity \
  --input assets/samplesheet.csv \
  --buscodb /scratch/references/busco_db/actinopterygii_odb10 \
  --binddir /scratch \
  --outdir /scratch/pawsey0964/$USER/post_curation \
  -c pawsey_profile.config \
  -resume \
  --tempdir $MYSCRATCH/tmp
```

**Key parameters:**

| Parameter | Description |
|-----------|-------------|
| `--input` | Path to the samplesheet CSV |
| `--buscodb` | BUSCO lineage database. Use `actinopterygii_odb10` for bony fish (default). Change for other taxa. |
| `--outdir` | Results output directory |
| `--binddir` | Directory to bind into Singularity containers (must cover all input paths) |
| `--tempdir` | Temp dir for pairtools sort (needs ~100 GB free space) |
| `-resume` | Restart from where a previous run left off (always include this) |

> **BUSCO database:** Available databases are at `/scratch/pawsey0964/lhuet/busco_db/`. Check this directory if your samples are not fish (e.g. sharks use a different lineage).

---

## Step 7 — Monitor the run

```bash
# Watch SLURM jobs submitted by Nextflow
squeue -u $USER

# Follow the Nextflow log in your tmux session
# (Nextflow prints progress directly to the terminal)

# Check the .nextflow.log for detailed process-level info
tail -f .nextflow.log

# List previous Nextflow runs and their status
nextflow log

# Check per-process work directories if something fails
nextflow log <run-name> -f name,status,exit,work_dir | grep -v OK
```

---

## Step 8 — Review outputs

Results are written to `--outdir` (default: `/scratch/pawsey0964/lhuet/post_curation/`), organised per sample under `post-curation/{sample}/`.

| Output directory | Contents |
|-----------------|----------|
| `rapid-curation/` | Curated hap1 and hap2 chromosome-level FASTAs |
| `update_mapping/` | hap2 with updated sequence IDs (use this for downstream work) |
| `busco/` | BUSCO completeness assessment (hap1 + hap2) |
| `merqury/` | QV scores and completeness (hap1 + hap2) |
| `gfastats/` | Assembly statistics: N50, L50, contig counts |
| `calculate_stats/` | % sequences assigned to chromosomes |
| `omnic_hap1/` `omnic_hap2/` | Hi-C BAM files (deduplicated) |
| `pretextmap_hap_1/` `pretextmap_hap_2/` | PretextMap `.pretext` contact maps |
| `pretextsnapshot_hap1/` `pretextsnapshot_hap2/` | PNG snapshots of contact maps |
| `multiqc/multiqc_report.html` | Aggregated QC report for all samples |

**Key files to check after a run:**
1. `multiqc/multiqc_report.html` — open in a browser to review all QC metrics
2. `rapid-curation/{sample}/Hap_1/{sample}*hap1.chr_level.fa` — final curated hap1
3. `rapid-curation/{sample}/Hap_2/{sample}*hap2.chr_level.fa` — final curated hap2

---

## Step 9 — Compile results, push to DB, and back up to Acacia

After the pipeline completes, run `post_pipeline.sh` which handles everything in one command:

```bash
cd /scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation
bash scripts/post_pipeline.sh scripts/postcuration_pipeline.conf
```

This script:
1. Compiles all QC outputs into TSV files
2. Pushes compiled results to PostgreSQL (Merqury QV, Merqury completeness, BUSCO, gfastats, seqkit stats, chromosome assignment %)
3. Submits per-OG SLURM backup jobs to Acacia
4. Backs up the MultiQC report to Acacia
5. Submits an audit SLURM job (runs after all backups complete) to verify remote copies

All DB inserts use `ON CONFLICT ... DO UPDATE`, so re-running is safe.

> **Note:** If you used `postcuration_run.sh` to run the pipeline, `post_pipeline.sh` is called automatically on success — you only need to run it manually if the pipeline succeeded but the post-pipeline steps failed.

---

## Troubleshooting

### Pipeline fails on OMNIC (pairtools sort runs out of space)
pairtools sort writes large temp files. Ensure `--tempdir` points to a location with ≥100 GB free:
```bash
df -h $MYSCRATCH
```
If low on space, use a different temp location:
```bash
nextflow run main.nf ... --tempdir /scratch/pawsey0964/lhuet/tmp
```

### RAPID_CURATION fails with missing sequences
The AGP file references sequence names that don't match the assembly FASTA. Check that the assembly file in `assembly/` is the correct pre-curation combined-scaffolds FASTA (not a post-curation file from a previous run).

### BUSCO is slow or fails
Check the `--buscodb` path exists and is the correct lineage for your taxa:
```bash
ls /scratch/pawsey0964/lhuet/busco_db/
ls /scratch/references/busco_db/
```

### Samplesheet has NULL values (missing date or genome size)
The DB doesn't have a PacBio sequencing record or GenomeScope result for that OG. Check the DB directly:
```bash
singularity run $SING/psycopg2:0.1.sif python - ~/postgresql_details/oceanomics.cfg << 'EOF'
import sys, configparser, psycopg2
pg = configparser.ConfigParser(); pg.read(sys.argv[1])
s = pg['postgres']
conn = psycopg2.connect(dbname=s['dbname'], user=s['user'], password=s['password'], host=s['host'])
cur = conn.cursor()
cur.execute("SELECT og_id, seq_date FROM sequencing WHERE og_id = 'OG696' AND seq_type = 'PacBio'")
print(cur.fetchall())
EOF
```

### Resume not working after a failed run
Delete the `.nextflow/cache` subdirectory for the failed run, then re-run with `-resume`:
```bash
nextflow log             # find the failed run name
nextflow clean -f <run-name>
bash nextflow_run.sh
```

### Checking which samples completed vs failed
```bash
nextflow log <run-name> -f name,status | grep -v COMPLETED | grep -v CACHED
```

---

## Quick reference

```bash
# ── Config ────────────────────────────────────────────────────────────────────
PIPELINE=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation
STAGING=/scratch/pawsey0964/lhuet/post_curation
SCRIPTS=$PIPELINE/scripts
SING=/software/projects/pawsey0964/singularity

# ── Samplesheet ───────────────────────────────────────────────────────────────
# 1. Set OG_IDS in $SCRIPTS/postcuration_pipeline.conf
# 2. Generate:
singularity run $SING/psycopg2:0.1.sif python \
  $SCRIPTS/0_create_samplesheet/create_samplesheet_from_config.py \
  $SCRIPTS/postcuration_pipeline.conf

# ── Stage data ────────────────────────────────────────────────────────────────
# Recommended (parallel, one job per OG):
sbatch $SCRIPTS/stage_data.slurm

# Alternative (parallel data types, sequential files):
bash $SCRIPTS/stage_all.sh

# ── AGP files ─────────────────────────────────────────────────────────────────
# Transfer from local, then move to correct subdir:
for f in $STAGING/OG*_v*.agp*; do
  og=$(basename "$f" | grep -o 'OG[0-9]*')
  [[ -n "$og" ]] && mv "$f" "$STAGING/${og}/agp/"
done

# ── Verify staging ────────────────────────────────────────────────────────────
tail -n +2 $PIPELINE/assets/samplesheet.csv | cut -d, -f1 | while read og; do
  echo "$og | HiC: $(ls $STAGING/$og/hic/*.fastq.gz 2>/dev/null | wc -l) \
  | Asm: $(ls $STAGING/$og/assembly/*.fa 2>/dev/null | wc -l) \
  | Meryl: $(ls -d $STAGING/$og/meryl/*.meryl 2>/dev/null | wc -l) \
  | AGP: $(ls $STAGING/$og/agp/*.agp* 2>/dev/null | wc -l)"
done

# ── Run pipeline ──────────────────────────────────────────────────────────────
tmux new-session -s post_curation_nf   # or attach to existing
cd $PIPELINE && bash nextflow_run.sh

# ── Monitor ───────────────────────────────────────────────────────────────────
squeue -u $USER
nextflow log
```
