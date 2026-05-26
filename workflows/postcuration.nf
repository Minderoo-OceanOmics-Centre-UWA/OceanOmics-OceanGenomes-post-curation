/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PRETEXT_TO_ASM            } from '../modules/local/pretext-to-asm/main'
include { RAPID_CURATION            } from '../modules/local/rapid-curation/'
include { MASHMAP                   } from '../modules/nf-core/mashmap/main'
include { UPDATE_MAPPING            } from '../modules/local/update-mapping'
include { BUSCO_BUSCO               } from '../modules/nf-core/busco/busco/main'
include { MERQURY_MERQURY           } from '../modules/nf-core/merqury/merqury/main'
include { GFASTATS as GFASTATS_HAP1 } from '../modules/nf-core/gfastats/main'
include { GFASTATS as GFASTATS_HAP2 } from '../modules/nf-core/gfastats/main'
include { CALCULATE_STATS           } from '../modules/local/calculate_stats/main'
include { CALCULATE_STATS_PRETEXT   } from '../modules/local/calculate_stats_pretext/main'
include { CAT_HIC                   } from '../modules/local/cat_hic/main'
include { OMNIC as OMNIC_HAP1       } from '../modules/local/omnic/main'
include { OMNIC as OMNIC_HAP2       } from '../modules/local/omnic/main'
include { PRETEXTMAP as PRETEXTMAP_HAP_1  } from '../modules/nf-core/pretextmap/main'
include { PRETEXTMAP as PRETEXTMAP_HAP_2   } from '../modules/nf-core/pretextmap/main'
include { PRETEXTSNAPSHOT as PRETEXTSNAPSHOT_HAP1  } from '../modules/nf-core/pretextsnapshot/main' 
include { PRETEXTSNAPSHOT as PRETEXTSNAPSHOT_HAP2  } from '../modules/nf-core/pretextsnapshot/main' 
include { MULTIQC                   } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap          } from 'plugin/nf-validation'
include { paramsSummaryMultiqc      } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML    } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText    } from '../subworkflows/local/utils_nfcore_postcuration_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow POSTCURATION {

    take:
    ch_samplesheet // channel: samplesheet read in from --input

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()

    ///
    /// Create input channels
    ///
    ch_hic = ch_samplesheet
    .map {
        meta ->
            meta = meta[0]
            meta.id = meta.sample + "_" + meta.date + "." + meta.version
            return [ meta, meta.hic_dir ]
    }

    ch_assembly = ch_samplesheet
    .map {
        meta ->
            meta = meta[0]
            meta.id = meta.sample + "_" + meta.date + "." + meta.version
            return [ meta, meta.assembly ]
    }

    ch_agp = ch_samplesheet
    .map {
        meta -> 
            meta = meta[0]
            meta.id = meta.sample + "_" + meta.date + "." + meta.version
            return [ meta, meta.agp]
    }


    ch_meryldb = ch_samplesheet
    .map {
        meta -> 
            meta = meta[0]
            meta.id = meta.sample + "_" + meta.date + "." + meta.version
            return [ meta, meta.meryldb]
    }

    ch_genomesize = ch_samplesheet
        .map {
        meta -> 
            meta = meta[0]
            meta.id = meta.sample + "_" + meta.date + "." + meta.version
            return [ meta, meta.genomesize]
    }

    //
    // MODULE: Split haplotypes and assign chromosome names
    //
    agp_assembly_ch = ch_assembly.join(ch_agp)
        .map { meta, assembly, agp -> [meta, assembly, agp] }

    if (params.curation_tool == 'rapid-curation') {
        RAPID_CURATION(agp_assembly_ch)

        ch_haplotypes = RAPID_CURATION.out.hap1.join(RAPID_CURATION.out.hap2)
        MASHMAP(ch_haplotypes)
        ch_versions = ch_versions.mix(MASHMAP.out.versions.first())

        UPDATE_MAPPING(RAPID_CURATION.out.hap2.join(MASHMAP.out.hap2_hap1_ID))
        ch_versions = ch_versions.mix(UPDATE_MAPPING.out.versions.first())

        ch_hap1 = RAPID_CURATION.out.hap1
        ch_hap2 = UPDATE_MAPPING.out.hap2_new
    } else {
        // pretext-to-asm (default)
        PRETEXT_TO_ASM(agp_assembly_ch)
        ch_versions = ch_versions.mix(PRETEXT_TO_ASM.out.versions.first())

        ch_hap1 = PRETEXT_TO_ASM.out.hap1
        ch_hap2 = PRETEXT_TO_ASM.out.hap2
    }

    ch_busco = ch_hap1.join(ch_hap2)
            .map { meta, hap1, hap2 -> [meta, [hap1, hap2]] }

    BUSCO_BUSCO (
        ch_busco,
        "genome",
        params.buscodb,
        []
    )
    ch_multiqc_files = ch_multiqc_files.mix(BUSCO_BUSCO.out.batch_summary)

    //
    //MODULE: Run Merqury
    //

    ch_assemblies = ch_hap1.join(ch_hap2)
        .map { meta, hap1, hap2 -> [meta, [hap1, hap2]] }

    ch_merqury = ch_meryldb.join(ch_assemblies)

    MERQURY_MERQURY (
        ch_merqury,
        "3.curated"
    )
    ch_multiqc_files = ch_multiqc_files.mix(MERQURY_MERQURY.out.stats)
    ch_multiqc_files = ch_multiqc_files.mix(MERQURY_MERQURY.out.assembly_qv)

    //
    // MODULE: run gfastats
    //

    ch_gfastats_hap1_in = ch_hap1.join(ch_genomesize)
    ch_gfastats_hap2_in = ch_hap2.join(ch_genomesize)

    GFASTATS_HAP1 (
        ch_gfastats_hap1_in,
        "fasta",
        "",
        "hap1",
        "3.curated",
        [],
        [],
        [],
        []
    )
    ch_versions = ch_versions.mix(GFASTATS_HAP1.out.versions.first())

    GFASTATS_HAP2 (
        ch_gfastats_hap2_in,
        "fasta",
        "",
        "hap2",
        "3.curated",
        [],
        [],
        [],
        []
    )
    ch_versions = ch_versions.mix(GFASTATS_HAP2.out.versions.first())

    //
    // MODULE: Cat hic reads
    //
    ch_hic.view()

    CAT_HIC (
        ch_hic
    )

    ///
    /// MODULE: Calculate stats
    ///
    ch_calculate_stats_joined = ch_hap1.join(ch_hap2)
    ch_hap1_for_stats = ch_calculate_stats_joined.map { meta, hap1, hap2 -> [meta, hap1] }
    ch_hap2_for_stats = ch_calculate_stats_joined.map { meta, hap1, hap2 -> [meta, hap2] }

    if (params.curation_tool == 'rapid-curation') {
        CALCULATE_STATS (
            ch_hap1_for_stats,
            ch_hap2_for_stats
        )
    } else {
        CALCULATE_STATS_PRETEXT (
            ch_hap1_for_stats,
            ch_hap2_for_stats
        )
    }

    //
    // MODULE: Run Omnic
    //

    ch_omnic_hap1_in = CAT_HIC.out.cat_files.join(ch_hap1)
        .map { meta, reads, assembly -> [meta, reads, assembly] }

    ch_omnic_hap2_in = CAT_HIC.out.cat_files.join(ch_hap2)
        .map { meta, reads, assembly -> [meta, reads, assembly] }

    OMNIC_HAP1 (
        ch_omnic_hap1_in,
        "hap1",
        params.tempdir
    )
    ch_versions = ch_versions.mix(OMNIC_HAP1.out.versions.first())

    OMNIC_HAP2 (
        ch_omnic_hap2_in,
        "hap2",
        params.tempdir
    )
    ch_versions = ch_versions.mix(OMNIC_HAP2.out.versions.first())


    //
    // MODULE: Run Pretext Map
    ///

    PRETEXTMAP_HAP_1 (OMNIC_HAP1.out.omnic_bam,
                        "hap1",
                        "3.curated.")
    
    ch_versions = ch_versions.mix(PRETEXTMAP_HAP_1.out.versions.first())
    
    PRETEXTMAP_HAP_2 (OMNIC_HAP2.out.omnic_bam,
                    "hap2",
                    "3.curated")
    
    ch_versions = ch_versions.mix(PRETEXTMAP_HAP_1.out.versions.first())

    
    //
    // MODULE: Run Pretext snapshot
    //

    PRETEXTSNAPSHOT_HAP1 (PRETEXTMAP_HAP_1.out.pretext_map,
                        "hap1",
                        "3.curated")  
    
    ch_versions = ch_versions.mix(PRETEXTSNAPSHOT_HAP1.out.versions.first())

    PRETEXTSNAPSHOT_HAP2 (PRETEXTMAP_HAP_2.out.pretext_map,
                    "hap2",
                    "3.curated")

    ch_versions = ch_versions.mix(PRETEXTSNAPSHOT_HAP2.out.versions.first())
    ch_multiqc_files = ch_multiqc_files.mix(PRETEXTSNAPSHOT_HAP1.out.image)
    ch_multiqc_files = ch_multiqc_files.mix(PRETEXTSNAPSHOT_HAP2.out.image)

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_pipeline_software_mqc_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC (one report per OG)
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))

    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    // Group per-sample QC files by meta, then run one MultiQC per OG
    ch_multiqc_per_sample = ch_multiqc_files
        .groupTuple()
        .map { meta, files -> [ meta, files.flatten() ] }

    MULTIQC (
        ch_multiqc_per_sample,
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml').first(),
        ch_collated_versions.first(),
        ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true).first()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: [ [meta, path(multiqc_report.html)], ... ]
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
