process PRETEXT_TO_ASM {
    tag "$meta.id"
    label 'process_medium'

    container "docker://sawtooth01/agp-tpf-uilts:v0.1"

    input:
    tuple val(meta), path(assembly_dir), path(agp_dir, stageAs: 'agp')

    output:
    tuple val(meta), path("${meta.id}_hap1.chr_level.fa"),              emit: hap1
    tuple val(meta), path("${meta.id}_hap2.chr_level.fa"),              emit: hap2
    tuple val(meta), path("assembly.chr_report.csv"),                   emit: chr_report
    tuple val(meta), path("assembly.hap1.1.primary.chromosome.list.csv"), emit: hap1_chr_list
    tuple val(meta), path("assembly.hap2.1.primary.chromosome.list.csv"), emit: hap2_chr_list
    tuple val(meta), path("assembly.hap1.1.primary.curated.agp"),       emit: hap1_agp
    tuple val(meta), path("assembly.hap2.1.primary.curated.agp"),       emit: hap2_agp
    tuple val(meta), path("assembly.info.yaml"),                        emit: info
    tuple val(meta), path("assembly.log"),                              emit: log
    path "versions.yml",                                                emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    assembly_fa=\$(find ${assembly_dir}/ -maxdepth 1 \\( -name "${meta.id}*.fa" -o -name "${meta.id}*.fasta" \\) | head -1)
    agp_file=\$(ls ${agp_dir}/ | head -1)

    pretext-to-asm \\
        --assembly \${assembly_fa} \\
        --pretext ${agp_dir}/\${agp_file} \\
        --output assembly.fa

    mv \$(ls *hap1*.curated.fa 2>/dev/null | head -1) ${prefix}_hap1.chr_level.fa
    mv \$(ls *hap2*.curated.fa 2>/dev/null | head -1) ${prefix}_hap2.chr_level.fa

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        pretext-to-asm: \$(pip show tola-agp-tpf-utils 2>/dev/null | grep '^Version' | cut -d' ' -f2 || echo "unknown")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_hap1.chr_level.fa
    touch ${prefix}_hap2.chr_level.fa
    touch assembly.chr_report.csv
    touch assembly.hap1.1.primary.chromosome.list.csv
    touch assembly.hap2.1.primary.chromosome.list.csv
    touch assembly.hap1.1.primary.curated.agp
    touch assembly.hap2.1.primary.curated.agp
    touch assembly.info.yaml
    touch assembly.log

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        pretext-to-asm: 0.0.0
    END_VERSIONS
    """
}
