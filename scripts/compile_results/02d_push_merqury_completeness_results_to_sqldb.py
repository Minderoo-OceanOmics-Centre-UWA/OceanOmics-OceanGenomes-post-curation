import psycopg2
import pandas as pd
import numpy as np
import configparser
import sys
from pathlib import Path

# Phase RG: database writes go through the shared helper (one transaction, non-zero exit on error).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import refdb  # noqa: E402

#run using singularity run $SING/psycopg2:0.1.sif python 02d_push_merqury_completeness_results_to_sqldb.py ~/postgresql_details/oceanomics.cfg

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

# File containing Merqury completeness data
merqury_compiled_path = f"merqury.completeness.stats.tsv"  # if your file structure is different this might not work.

# Import merqury data
print(f"Importing data from {merqury_compiled_path}")

# Load data
merqury = pd.read_csv(merqury_compiled_path, sep="\t")

# Split the 'sample' column up so we have og_id, seq_date, stage and haplotype
# Ensure 'sample' column exists
if 'sample' in merqury.columns:
    # Split 'sample' into 4 new columns
    merqury['og_id'] = merqury['sample'].str.split('.').str[0].str.split('_').str[0]
    merqury['seq_date'] = merqury['sample'].str.split('.').str[0].str.split('_').str[1].str.lstrip('v')
    merqury['version'] = merqury['sample'].str.split('.').str[1]
    merqury['stage'] = merqury['sample'].str.split('.').str[2].astype(int)
    merqury['haplotype'] = merqury['sample'].str.split('.').str[4].str.split('_').str[0]

    # Save the updated DataFrame back to a tab-delimited file
    output_file = f"merqury_completeness_compiled_results_split.tsv"
    merqury.to_csv(output_file, sep="\t", index=False)

    print("File successfully processed! New columns added.")
else:
    print("Error: 'sample' column not found in the input file.")

# Print summary of changes
print("\n🔍 Final dataset summary:")
print(merqury.describe())

# -------------------------------
# DB write (Phase RG): one row per assembly, part and tool in ref_assembly, ref_assembly_part and
# ref_merqury_completeness, through scripts/lib/refdb.py. One transaction for the whole file; any error exits 1.
# Table names are unqualified: search_path decides (v4 during the RG window, public after RG.6).
# -------------------------------
PART_KEY = ("og_id", "seq_date", "version", "stage", "haplotype")


def build_rows():
    rows = []
    for index, row in merqury.iterrows():
        row_dict = row.to_dict()
        params = {
            "og_id": row_dict["og_id"],
            "seq_date": row_dict["seq_date"],
            "version": row_dict["version"],
            "stage": row_dict["stage"],
            "haplotype": row_dict["haplotype"],
            "solid_k_mers": None if pd.isna(row_dict["solid_k_mers"]) else int(row_dict["solid_k_mers"]),
            "total_k_mers": None if pd.isna(row_dict["total_k_mers"]) else int(row_dict["total_k_mers"]),
            "completeness": float(row_dict["completeness"]) if row_dict["completeness"] not in [None, ""] else None
        }
        rows.append(({k: params[k] for k in PART_KEY},
                     {k: v for k, v in params.items() if k not in PART_KEY}))
    return rows


refdb.main_guard(lambda: refdb.write_tool_rows(db_params, "ref_merqury_completeness", build_rows()))
