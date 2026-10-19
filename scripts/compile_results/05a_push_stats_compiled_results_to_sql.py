import psycopg2
import pandas as pd
import numpy as np
import configparser
import sys
from pathlib import Path

# Phase RG: database writes go through the shared helper (one transaction, non-zero exit on error).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import refdb  # noqa: E402

#singularity run $SING/psycopg2:0.1.sif python 05a_push_stats_compiled_results_to_sql.py ~/postgresql_details/oceanomics.cfg

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
# File paths
input_file = "stats_compiled.tsv"
output_file = "stats_compiled_split.tsv"

print(f"📥 Reading {input_file}...")

# STEP 1: Read and clean the raw file
df_raw = pd.read_csv(input_file, sep="\t", dtype=str)

# STEP 2: Split space-separated 'format' field into correct columns
split_cols = df_raw['format'].str.split(r'\s+', expand=True)
split_cols.columns = ['format', 'type', 'num_seqs', 'sum_len', 'min_len', 'avg_len', 'max_len']

# Combine with original 'file' column
df = pd.concat([df_raw['file'], split_cols], axis=1)

# STEP 3: Remove commas from numeric fields
for col in ['num_seqs', 'sum_len', 'min_len', 'avg_len', 'max_len']:
    df[col] = df[col].str.replace(",", "", regex=False)

# STEP 4: Parse identifiers
df["og_id"] = df["file"].str.split('.').str[0].str.split('_').str[0]
df["seq_date"] = df["file"].str.split('.').str[0].str.split('_').str[1].str.lstrip("v")
df["version"] = df["file"].str.split('.').str[1]
df["stage"] = df["file"].str.split('.').str[2].astype(int)
df["haplotype"] = df["file"].str.split('.').str[4].str.split('_').str[0]

# STEP 5: Save intermediate file
df.to_csv(output_file, sep="\t", index=False)
print(f"✅ Cleaned + split file saved to: {output_file}")
print("📋 Columns:", df.columns.tolist())

# STEP 6: Convert numeric columns for DB insertion
for col in ['num_seqs', 'sum_len', 'min_len', 'avg_len', 'max_len']:
    df[col] = pd.to_numeric(df[col], errors="coerce")


# STEP 8: Test push with rollback

# -------------------------------
# DB write (Phase RG): one row per assembly, part and tool in ref_assembly, ref_assembly_part and
# ref_seqkit_stats, through scripts/lib/refdb.py. One transaction for the whole file; any error exits 1.
# Table names are unqualified: search_path decides (v4 during the RG window, public after RG.6).
# -------------------------------
PART_KEY = ("og_id", "seq_date", "version", "stage", "haplotype")


def build_rows():
    rows = []
    for _, row in df.iterrows():
        row_dict = row.to_dict()
        params = {
            "og_id": row_dict["og_id"],
            "seq_date": row_dict["seq_date"],
            "version": row_dict["version"],
            "stage": row_dict["stage"],
            "haplotype": row_dict["haplotype"],
            "format": row_dict.get("format"),
            "type": row_dict.get("type"),
            "num_seqs": int(row_dict["num_seqs"]) if not pd.isna(row_dict["num_seqs"]) else None,
            "sum_len": int(row_dict["sum_len"]) if not pd.isna(row_dict["sum_len"]) else None,
            "min_len": int(row_dict["min_len"]) if not pd.isna(row_dict["min_len"]) else None,
            "avg_len": float(row_dict["avg_len"]) if not pd.isna(row_dict["avg_len"]) else None,
            "max_len": int(row_dict["max_len"]) if not pd.isna(row_dict["max_len"]) else None,
        }
        rows.append(({k: params[k] for k in PART_KEY},
                     {k: v for k, v in params.items() if k not in PART_KEY}))
    return rows


refdb.main_guard(lambda: refdb.write_tool_rows(db_params, "ref_seqkit_stats", build_rows()))
