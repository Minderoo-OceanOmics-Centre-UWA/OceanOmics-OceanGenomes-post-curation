# OceanOmics OceanGenomes Post-Curation Pipeline

A Nextflow DSL2 pipeline for QC and validation of manually curated diploid genome assemblies, developed for the [Minderoo OceanOmics Ocean Genomes Project](https://www.minderoo.org/oceanomics/).

<p align="center">
    <img src="docs/images/post-curation--pipeline-overview.PNG" alt="OceanOmics Post Curation Pipeline Overview" width="100%">
</p>

## Pipeline position

```
PacBio HiFi + Hi-C reads
  └─> OceanOmics-OceanGenomes-ref-genomes (hifi_hic mode)
        └─> PretextMap contact map
              └─> Manual curation in PretextView (local)
                    └─> Export AGP file
                          └─> THIS PIPELINE
                                └─> Curated hap1/hap2 + QC metrics + DB push + Acacia backup
```

## Pipeline steps

1. **Curation** (one of two paths, set via `--curation_tool`):
   - `rapid-curation` *(default)* — splits haplotypes from a combined-scaffolds FASTA using PretextView AGP ([Nadolina Brajuka, VGL](https://github.com/sanger-tol/rapid-curation))
   - `pretext-to-asm` — applies AGP directly to pre-split hap1/hap2 assemblies
2. **MashMap** — maps hap2 back to hap1 to establish sequence identity
3. **Update Mapping** — updates hap2 sequence IDs to match hap1 nomenclature ([Tom Mathers, DToL](https://www.darwintreeoflife.org/))
4. **BUSCO** — genome completeness assessment (`--miniprot`)
5. **Merqury** — k-mer QV and completeness using a pre-built Meryl database
6. **gfastats** — assembly statistics (N50, L50, contig counts, GC%)
7. **Calculate Stats** — percentage of sequences assigned to chromosomes
8. **Cat HiC** — concatenates Hi-C FASTQ pairs if multiple libraries exist
9. **Omnic** (×2) — maps Hi-C reads to hap1 and hap2 (`bwa mem` + `pairtools` + `samtools`)
10. **PretextMap** (×2) — generates Hi-C contact maps from BAM
11. **PretextSnapshot** (×2) — PNG snapshots of contact maps
12. **MultiQC** — aggregates all QC into a single HTML report

## Running on Pawsey (Setonix)

For full instructions including data staging, samplesheet generation, post-pipeline DB push, and Acacia backup, see:

- **[docs/pawsey_automated_run.md](docs/pawsey_automated_run.md)** — recommended: end-to-end automated run guide
- **[docs/oceanomics_pawsey_usage.md](docs/oceanomics_pawsey_usage.md)** — detailed step-by-step reference

### Quick start

```bash
# 1. Set OG IDs in the config
nano scripts/postcuration_pipeline.conf   # update OG_IDS=OG696,OG775,...

# 2. Stage input data (generates samplesheet + downloads HiC, assembly, meryl from Acacia)
bash scripts/stage_all.sh

# 3. Transfer AGP files from your local machine into each OG's agp/ directory
scp OG*_v*.hic*.agp* lhuet@setonix.pawsey.org.au:/scratch/pawsey0964/lhuet/post_curation/

# 4. Run the pipeline (Nextflow + compile + DB push + Acacia backup)
tmux new-session -s post_curation
bash scripts/postcuration_run.sh
```

## Samplesheet

```csv
sample,hic_dir,assembly,meryldb,agp,version,date,genomesize
OG696,/path/to/OG696/hic,/path/to/OG696/assembly,/path/to/OG696/meryl,/path/to/OG696/agp,hic1,v240228,1375723817
```

| Column | Description |
|--------|-------------|
| `sample` | OG identifier (e.g. `OG696`) |
| `hic_dir` | Directory containing Hi-C FASTQ files |
| `assembly` | Directory containing the combined-scaffolds FASTA |
| `meryldb` | Directory containing the pre-built Meryl k-mer database |
| `agp` | Directory containing the AGP file exported from PretextView |
| `version` | Hi-C library version (e.g. `hic1`, `hic2`) |
| `date` | PacBio sequencing date as `vYYMMDD` (e.g. `v240228`) |
| `genomesize` | Estimated genome size in bp (from GenomeScope) |

The samplesheet is generated automatically by `scripts/stage_all.sh` from the OceanOmics PostgreSQL database.

## Running manually (generic)

```bash
nextflow run main.nf \
  -profile singularity \
  --input assets/samplesheet.csv \
  --buscodb /path/to/busco_db/actinopterygii_odb10 \
  --binddir /scratch \
  --outdir /path/to/outdir \
  -c pawsey_profile.config \
  -resume \
  --tempdir /path/to/tmp \
  --curation_tool rapid-curation
```

Key parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--input` | Samplesheet CSV path | required |
| `--buscodb` | BUSCO lineage database path | required |
| `--curation_tool` | `rapid-curation` or `pretext-to-asm` | `rapid-curation` |
| `--outdir` | Results output directory | required |
| `--binddir` | Singularity bind path (must cover all input paths) | `/scratch` |
| `--tempdir` | Temp dir for pairtools sort (needs ~100 GB free) | required |

## Outputs

Results are written to `--outdir/post-curation/<sample>/`:

| Directory | Contents |
|-----------|----------|
| `rapid-curation/` or `pretext-to-asm/` | Curated hap1 and hap2 chromosome-level FASTAs + AGPs |
| `update_mapping/` | hap2 with sequence IDs updated to match hap1 |
| `busco/` | BUSCO completeness results |
| `merqury/` | QV scores and k-mer completeness |
| `gfastats/` | Assembly statistics (N50, L50, GC%) |
| `calculate_stats/` | % sequences assigned to chromosomes |
| `omnic_hap1/` `omnic_hap2/` | Hi-C BAM files |
| `pretextmap_hap_1/` `pretextmap_hap_2/` | PretextMap contact maps |
| `pretextsnapshot_hap1/` `pretextsnapshot_hap2/` | PNG contact map snapshots |
| `multiqc/` | Aggregated MultiQC HTML report |

## Credits

Developed by Lauren Huet, Minderoo OceanOmics.

This pipeline incorporates:
- [Rapid Curation](https://github.com/sanger-tol/rapid-curation) by Nadolina Brajuka (Vertebrate Genome Laboratory)
- Update Mapping scripts by Tom Mathers (Darwin Tree of Life)
- Calculate Statistics by Emma de Jong (Minderoo OceanOmics)

Built on the [nf-core](https://nf-co.re/) framework.
