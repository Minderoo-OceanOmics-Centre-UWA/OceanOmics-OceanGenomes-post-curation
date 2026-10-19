import pandas as pd
import psycopg2
import configparser
import sys
from pathlib import Path

# Phase RG: database writes go through the shared helper (one transaction, non-zero exit on error).
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import refdb  # noqa: E402

# singularity run $SING/psycopg2:0.1.sif python 06b_push_percentage_stats_to_sqldb.py ~/postgresql_details/oceanomics.cfg

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

# Input file
input_file = "percentage_stats_split.tsv"

# Read data
print(f"📥 Reading: {input_file}")
df = pd.read_csv(input_file, sep="\t")

print("🧾 Rows:", len(df))
print(df.head())

# -------------------------------
# DB write (Phase RG): one row per assembly, part and tool in ref_assembly, ref_assembly_part and
# ref_chromosome_stats, through scripts/lib/refdb.py. One transaction for the whole file; any error exits 1.
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
            "stage": int(row_dict["stage"]),
            "haplotype": row_dict["haplotype"],
            "num_chromosomes": int(row_dict["num_chromosomes"]) if pd.notna(row_dict["num_chromosomes"]) else None,
            "pct_assigned": float(row_dict["pct_assigned"]) if pd.notna(row_dict["pct_assigned"]) else None,
            "pct_no_super": float(row_dict["pct_no_super"]) if pd.notna(row_dict["pct_no_super"]) else None,
            "num_seq_no_super": int(row_dict["num_seq_no_super"]) if pd.notna(row_dict["num_seq_no_super"]) else None,
            "max_len_no_super": int(row_dict["max_len_no_super"]) if pd.notna(row_dict["max_len_no_super"]) else None,
        }
        rows.append(({k: params[k] for k in PART_KEY},
                     {k: v for k, v in params.items() if k not in PART_KEY}))
    return rows


refdb.main_guard(lambda: refdb.write_tool_rows(db_params, "ref_chromosome_stats", build_rows()))
