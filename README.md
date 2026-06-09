# OceanOmics OceanGenomes Post-Curation Pipeline

A Nextflow DSL2 pipeline for QC and validation of manually curated diploid genome assemblies, developed for the [Minderoo OceanOmics Ocean Genomes Project](https://www.minderoo.org/oceanomics/).

<p align="center">
    <img src="docs/images/post-curation--pipeline-overview.PNG" alt="OceanOmics Post Curation Pipeline Overview" width="100%">
</p>

## Pipeline position

```
PacBio HiFi + Hi-C reads
  └─> Assembly pipeline (hifi_hic mode)
        └─> PretextMap contact map
              └─> Manual curation in PretextView (local)
                    └─> Export AGP file
                          └─> THIS PIPELINE
                                └─> Curated hap1/hap2 assemblies + QC metrics
```

## Pipeline steps

1. **Curation** (one of two paths, set via `--curation_tool`):
   - `rapid-curation` *(default)* — splits haplotypes from a combined-scaffolds FASTA using a PretextView AGP ([Nadolina Brajuka, VGL](https://github.com/sanger-tol/rapid-curation))
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

---

## Usage

### Requirements

- [Nextflow](https://www.nextflow.io/) ≥ 23.04
- [Singularity](https://sylabs.io/docs/) (recommended) or Docker
- A pre-built [Meryl](https://github.com/marbl/merqury) k-mer database for each sample
- An AGP file exported from [PretextView](https://github.com/sanger-tol/PretextView) after manual curation
- A [BUSCO](https://busco.ezlab.org/) lineage database appropriate for your taxon

### Samplesheet

Prepare a CSV samplesheet with one row per sample:

```csv
sample,hic_dir,assembly,meryldb,agp,version,date,genomesize
SAMPLE1,/path/to/hic,/path/to/assembly,/path/to/meryl,/path/to/agp,hic1,v240228,1375723817
```

| Column | Description |
|--------|-------------|
| `sample` | Sample identifier |
| `hic_dir` | Directory containing Hi-C FASTQ files (R1 + R2) |
| `assembly` | Directory containing the input assembly FASTA |
| `meryldb` | Directory containing the pre-built Meryl k-mer database |
| `agp` | Directory containing the AGP file from PretextView |
| `version` | Hi-C library version (e.g. `hic1`, `hic2`) |
| `date` | Sequencing date as `vYYMMDD` (e.g. `v240228`) |
| `genomesize` | Estimated genome size in bp (from GenomeScope) |

All `hic_dir`, `assembly`, `meryldb`, and `agp` columns must point to **directories** containing the relevant files.

### Run

```bash
nextflow run main.nf \
  -profile singularity \
  --input assets/samplesheet.csv \
  --buscodb /path/to/busco_db/actinopterygii_odb10 \
  --binddir /scratch \
  --outdir /path/to/outdir \
  -resume \
  --tempdir /path/to/tmp \
  --curation_tool rapid-curation
```

Key parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--input` | Samplesheet CSV path | required |
| `--buscodb` | BUSCO lineage database directory | required |
| `--curation_tool` | `rapid-curation` or `pretext-to-asm` | `rapid-curation` |
| `--outdir` | Results output directory | required |
| `--binddir` | Singularity bind path (must cover all input paths) | `/scratch` |
| `--tempdir` | Temp directory for pairtools sort (needs ~100 GB free) | required |

### Outputs

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

---

## OceanOmics internal usage

If you are running this pipeline as part of the OceanOmics Ocean Genomes project, see the internal documentation for Pawsey Setonix-specific instructions including automated staging, database integration, and Acacia backup:

- **[docs/oceanomics_pawsey_usage.md](docs/oceanomics_pawsey_usage.md)** — step-by-step guide
- **[docs/pawsey_automated_run.md](docs/pawsey_automated_run.md)** — end-to-end automated run (recommended)

---

## Credits

Developed by Lauren Huet, Minderoo OceanOmics.

This pipeline incorporates:
- [Rapid Curation](https://github.com/sanger-tol/rapid-curation) by Nadolina Brajuka (Vertebrate Genome Laboratory)
- Update Mapping scripts by Tom Mathers (Darwin Tree of Life)
- Calculate Statistics by Emma de Jong (Minderoo OceanOmics)

Built on the [nf-core](https://nf-co.re/) framework.
