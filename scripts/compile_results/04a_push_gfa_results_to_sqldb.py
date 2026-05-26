import psycopg2
import pandas as pd
import numpy as np
import configparser
import sys
from pathlib import Path

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

try:
    # Connect to PostgreSQL
    conn = psycopg2.connect(**db_params)
    cursor = conn.cursor()

    row_count = 0  # Track number of processed rows

    for index, row in gfa.iterrows():
        row_dict = row.to_dict()

        # Extract primary key values
        og_id, seq_date, stage, haplotype = row["og_id"], row["seq_date"], row["stage"], row["haplotype"]

        # UPSERT: Insert if not exists, otherwise update
        upsert_query = """
        INSERT INTO ref_genomes (
            og_id, seq_date, version, stage, haplotype, num_contigs, contig_n50, contig_n50_size_mb, num_scaffolds,
            scaffold_n50, scaffold_n50_size_mb, largest_scaffold, largest_scaffold_size_mb, total_scaffold_length,
            total_scaffold_length_size_mb, gc_content_percent, num_gaps
        )
        VALUES (
            %(og_id)s, %(seq_date)s, %(version)s, %(stage)s, %(haplotype)s, %(num_contigs)s, %(contig_n50)s,
            %(contig_n50_size_mb)s, %(num_scaffolds)s, %(scaffold_n50)s, %(scaffold_n50_size_mb)s,
            %(largest_scaffold)s, %(largest_scaffold_size_mb)s, %(total_scaffold_length)s,
            %(total_scaffold_length_size_mb)s, %(gc_content_percent)s, %(num_gaps)s
        )
        ON CONFLICT (og_id, seq_date, stage, haplotype, version) DO UPDATE SET
            num_contigs = EXCLUDED.num_contigs,
            contig_n50 = EXCLUDED.contig_n50,
            contig_n50_size_mb = EXCLUDED.contig_n50_size_mb,
            num_scaffolds = EXCLUDED.num_scaffolds,
            scaffold_n50 = EXCLUDED.scaffold_n50,
            scaffold_n50_size_mb = EXCLUDED.scaffold_n50_size_mb,
            largest_scaffold = EXCLUDED.largest_scaffold,
            largest_scaffold_size_mb = EXCLUDED.largest_scaffold_size_mb,
            total_scaffold_length = EXCLUDED.total_scaffold_length,
            total_scaffold_length_size_mb = EXCLUDED.total_scaffold_length_size_mb,
            gc_content_percent = EXCLUDED.gc_content_percent,
            num_gaps = EXCLUDED.num_gaps;
        """
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

        # Debugging Check
        print(f"Number of columns in query: {upsert_query.count('%s')}")
        print(f"Column names in DataFrame: {gfa.columns.tolist()}")
        print("row:", row_dict)
        print("params:", params)

        cursor.execute(upsert_query, params)
        row_count += 1  

        conn.commit()
        print(f"✅ Successfully processed {row_count} rows!")

except Exception as e:
    conn.rollback()
    print(f"❌ Error: {e}")

finally:
    cursor.close()
    conn.close()
