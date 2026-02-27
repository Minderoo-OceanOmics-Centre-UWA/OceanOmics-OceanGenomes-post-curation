#!/bin/bash
scripts=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/scripts/backup_scripts
csv_file=/scratch/pawsey0964/lhuet/post_curation/OceanOmics-OceanGenomes-post-curation/assets/samplesheet.csv

# Loop through each line of the CSV
tail -n +2 "$csv_file" | while IFS=',' read -r sample hic_dir assembly meryldb agp version date genomesize; do
    # Pass sample, date, version to your job script
    sbatch "$scripts/backup.sh" "$sample" "$date" "$version"
    echo "Submitted: $sample $date $version"
done