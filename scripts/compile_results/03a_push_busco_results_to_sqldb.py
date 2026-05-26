import psycopg2
import pandas as pd
import numpy as np
import configparser
import sys
from pathlib import Path

#run with singularity run $SING/psycopg2:0.1.sif python 03a_push_busco_results_to_sqldb.py ~/postgresql_details/oceanomics.cfg

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



# File containing BUSCO data

BUSCO_compiled_path = f"BUSCO_compiled_results.tsv"  # if your file structure is different this might not work.

# Import BUSCO data
print(f"Importing data from {BUSCO_compiled_path}")

# Load data
busco = pd.read_csv(BUSCO_compiled_path, sep="\t")

# Split the 'sample' column up so we have og_id, seq_date, stage and haplotype
# Ensure 'sample' column exists
if 'sample' in busco.columns:
    def parse_sample(sample):
        parts = sample.split('.')
        og_date = parts[0]
        og_id = og_date.split('_')[0]
        seq_date = og_date.split('_')[1].lstrip('v')
        if 'chr_level' in sample:
            # pretext-to-asm hap2: OG100_v240116.hic2_hap2.chr_level.fa
            version = parts[1].split('_')[0]
            stage = 3
            haplotype = 'hap2'
        else:
            # standard: OG100_v240116.hic2.3.curated.hap1/hap2
            version = parts[1]
            stage = int(parts[2])
            haplotype = parts[4].split('_')[0]
        return pd.Series({'og_id': og_id, 'seq_date': seq_date, 'version': version, 'stage': stage, 'haplotype': haplotype})

    parsed = busco['sample'].apply(parse_sample)
    busco = pd.concat([busco, parsed], axis=1)


    # Save the updated DataFrame back to a tab-delimited file
    output_file = f"BUSCO_compiled_results_split.tsv"
    busco.to_csv(output_file, sep="\t", index=False)
    
    print("File successfully processed! New columns added.")
else:
    print("Error: 'sample' column not found in the input file.")


# Print summary of changes
print("\n🔍 Final dataset summary:")
print(busco.describe())

try:
    # Connect to PostgreSQL
    conn = psycopg2.connect(**db_params)
    cursor = conn.cursor()

    row_count = 0  # Track number of processed rows

    for index, row in busco.iterrows():
        row_dict = row.to_dict()

        # Extract primary key values
        og_id, seq_date, stage, haplotype = row["og_id"], row["seq_date"], row["stage"], row["haplotype"]

        # UPSERT: Insert if not exists, otherwise update
        upsert_query = """
        INSERT INTO ref_genomes (
            og_id, seq_date, version, stage, haplotype, dataset, complete, single_copy, multi_copy, fragmented,
            missing, n_markers, internal_stop_codon_percent, scaffold_n50_bus, contigs_n50_bus, percent_gaps, number_of_scaffolds
        )
        VALUES (
            %(og_id)s, %(seq_date)s, %(version)s, %(stage)s, %(haplotype)s, %(dataset)s, %(complete)s, %(single_copy)s, %(multi_copy)s, %(fragmented)s,
            %(missing)s, %(n_markers)s, %(internal_stop_codon_percent)s, %(scaffold_n50_bus)s, %(contigs_n50_bus)s, %(percent_gaps)s,
            %(number_of_scaffolds)s
        )
        ON CONFLICT (og_id, seq_date, stage, haplotype, version) DO UPDATE SET
            dataset = EXCLUDED.dataset,
            complete = EXCLUDED.complete,
            single_copy = EXCLUDED.single_copy,
            multi_copy = EXCLUDED.multi_copy,
            fragmented = EXCLUDED.fragmented,
            missing = EXCLUDED.missing,
            n_markers = EXCLUDED.n_markers,
            internal_stop_codon_percent = EXCLUDED.internal_stop_codon_percent,
            scaffold_n50_bus = EXCLUDED.scaffold_n50_bus,
            contigs_n50_bus = EXCLUDED.contigs_n50_bus,
            percent_gaps = EXCLUDED.percent_gaps,
            number_of_scaffolds = EXCLUDED.number_of_scaffolds;
        """
        params = {
            "og_id": row_dict["og_id"],
            "seq_date": row_dict["seq_date"],
            "version": row_dict["version"],
            "stage": row_dict["stage"],
            "haplotype": row_dict["haplotype"],
            "dataset": row_dict["dataset"],
            "complete": float(row_dict["complete"]) if row_dict["complete"] not in [None, ""] else None,  # FLOAT
            "single_copy": float(row_dict["single_copy"]) if row_dict["single_copy"] not in [None, ""] else None,  # FLOAT
            "multi_copy": float(row_dict["multi_copy"]) if row_dict["multi_copy"] not in [None, ""] else None,  # FLOAT
            "fragmented": float(row_dict["fragmented"]) if row_dict["fragmented"] not in [None, ""] else None,  # FLOAT        
            "missing": float(row_dict["missing"]) if row_dict["missing"] not in [None, ""] else None,  # FLOAT
            "n_markers": None if pd.isna(row_dict["n_markers"]) else int(row_dict["n_markers"]),
            "internal_stop_codon_percent": float(row_dict["internal_stop_codon_percent"]) if row_dict["internal_stop_codon_percent"] else None,  # FLOAT
            "scaffold_n50_bus": None if pd.isna(row_dict["scaffold_n50_bus"]) else int(row_dict["scaffold_n50_bus"]),  
            "contigs_n50_bus": None if pd.isna(row_dict["contigs_n50_bus"]) else int(row_dict["contigs_n50_bus"]),
            "percent_gaps": float(str(row_dict["percent_gaps"]).rstrip('%')) if row_dict["percent_gaps"] not in [None, "", "nan", "NaN", float('nan')] and not pd.isna(row_dict["percent_gaps"]) else None,    
            "number_of_scaffolds": None if pd.isna(row_dict["number_of_scaffolds"]) else int(row_dict["number_of_scaffolds"]),
        }

        # Debugging Check
        print(f"Number of columns in query: {upsert_query.count('%s')}")
        print(f"Column names in DataFrame: {busco.columns.tolist()}")
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
