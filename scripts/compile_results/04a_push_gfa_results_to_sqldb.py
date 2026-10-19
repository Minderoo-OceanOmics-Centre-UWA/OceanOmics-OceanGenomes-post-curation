import psycopg2
import pandas as pd
import numpy as np
import configparser
import sys
from pathlib import Path

# Phase RG: database writes go through the shared helper (one transaction, non-zero exit on error).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import refdb  # noqa: E402

#run with singularity run $SING/psycopg2:0.1.sif python 04a_push_gfa_results_to_sqldb.py ~/postgresql_details/oceanomics.cfg

def load_db_config(config_file):
    if not Path(config_file).exists():
        raise FileNotFoundError(f"Config file '{config_file}' does not exist.")
    config = configparser.ConfigParser()
    config.read(config_file)
    return {
        'dbname': config.get('postgres', 'dbname'),
        'user': config.get('postgres', 'user'),
        'password': config.get('postgres', 'password'),
        'host': config.get('postgres', 'host'),
        'port': config.getint('postgres', 'port')
    }

config_file = sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / "postgresql_details/oceanomics.cfg")
db_params = load_db_config(config_file)


# File containing gfa stats data

gfa_compiled_path = f"final_gfastats_report.txt"  # if your file structure is different this might not work.

# Import gfa data
print(f"Importing data from {gfa_compiled_path}")

# Load data
gfa = pd.read_csv(gfa_compiled_path, sep="\t")

# Split the 'filename' column up so we have og_id, seq_date, stage and haplotype
# Ensure 'filename' column exists
if 'filename' in gfa.columns:
    # Split 'filename' into 4 new columns
    gfa['og_id'] = gfa['filename'].str.split('.').str[0].str.split('_').str[0]
    gfa['seq_date'] = gfa['filename'].str.split('.').str[0].str.split('_').str[1].str.lstrip('v')
    gfa['version'] = gfa['filename'].str.split('.').str[1]
    gfa['stage'] = gfa['filename'].str.split('.').str[2].astype(int)
    gfa['haplotype'] =  gfa['filename'].str.split('.').str[4].str.split('_').str[0]


    # Save the updated DataFrame back to a tab-delimited file
    output_file = f"gfa_compiled_results_split.tsv"
    gfa.to_csv(output_file, sep="\t", index=False)
    
    print("File successfully processed! New columns added.")
else:
    print("Error: 'sample' column not found in the input file.")


# Print summary of changes
print("\n🔍 Final dataset summary:")
print(gfa.describe())

# -------------------------------
# DB write (Phase RG): one row per assembly, part and tool in ref_assembly, ref_assembly_part and
# ref_gfastats, through scripts/lib/refdb.py. One transaction for the whole file; any error exits 1.
# Table names are unqualified: search_path decides (v4 during the RG window, public after RG.6).
# -------------------------------
PART_KEY = ("og_id", "seq_date", "version", "stage", "haplotype")


def build_rows():
    rows = []
    for index, row in gfa.iterrows():
        row_dict = row.to_dict()
        params = {
            "og_id": row_dict["og_id"],
            "seq_date": row_dict["seq_date"],
            "version": row_dict["version"],
            "stage": row_dict["stage"],
            "haplotype": row_dict["haplotype"],
            "num_contigs": None if pd.isna(row_dict["num_contigs"]) else int(row_dict["num_contigs"]),
            "contig_n50": None if pd.isna(row_dict["contig_n50"]) else int(row_dict["contig_n50"]),
            "contig_n50_size_mb": float(row_dict["contig_n50_size_mb"]) if row_dict["contig_n50_size_mb"] not in [None, ""] else None,
            "num_scaffolds": None if pd.isna(row_dict["num_scaffolds"]) else int(row_dict["num_scaffolds"]),
            "scaffold_n50": None if pd.isna(row_dict["scaffold_n50"]) else int(row_dict["scaffold_n50"]),
            "scaffold_n50_size_mb": float(row_dict["scaffold_n50_size_mb"]) if row_dict["scaffold_n50_size_mb"] not in [None, ""] else None,
            "largest_scaffold": None if pd.isna(row_dict["largest_scaffold"]) else int(row_dict["largest_scaffold"]),
            "largest_scaffold_size_mb": float(row_dict["largest_scaffold_size_mb"]) if row_dict["largest_scaffold_size_mb"] not in [None, ""] else None,
            "total_scaffold_length": None if pd.isna(row_dict["total_scaffold_length"]) else int(row_dict["total_scaffold_length"]),
            "total_scaffold_length_size_mb": float(row_dict["total_scaffold_length_size_mb"]) if row_dict["total_scaffold_length_size_mb"] not in [None, ""] else None,
            "gc_content_percent": float(row_dict["gc_content_percent"]) if row_dict["gc_content_percent"] not in [None, ""] else None,
            "num_gaps": None if pd.isna(row_dict["num_gaps"]) else int(row_dict["num_gaps"]),
        }
        rows.append(({k: params[k] for k in PART_KEY},
                     {k: v for k, v in params.items() if k not in PART_KEY}))
    return rows


refdb.main_guard(lambda: refdb.write_tool_rows(db_params, "ref_gfastats", build_rows()))
