/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

import groovy.io.FileType
import nextflow.Nextflow

include { validateParameters; paramsHelp; paramsSummaryLog; fromSamplesheet; paramsSummaryMap } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary_params = paramsSummaryMap(workflow)
def parameters_schema = "assets/nextflow_schema.json"

// Print parameter summary log to screen
log.info logo + paramsSummaryLog(workflow) + citation

//WorkflowMcmicro.initialise(params, log)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK } from '../subworkflows/local/input_check'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//

include { BASICPY                     } from '../modules/nf-core/basicpy/main'
include { ASHLAR                      } from '../modules/nf-core/ashlar/main'
include { BACKSUB                     } from '../modules/nf-core/backsub/main'
include { CELLPOSE                    } from '../modules/nf-core/cellpose/main'
include { DEEPCELL_MESMER             } from '../modules/nf-core/deepcell/mesmer/main'
include { MCQUANT                     } from '../modules/nf-core/mcquant/main'
// include { SCIMAP_MCMICRO              } from '../modules/nf-core/scimap/mcmicro/main'
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow MCMICRO {

    def input_type

    if (params.input_sample && !params.input_cycle) {
        input_type = "sample"
        sample_sheet_index_map = make_sample_sheet_index_map(params.input_sample)
        ch_from_samplesheet = Channel.fromSamplesheet(
            "input_sample",
            parameters_schema: parameters_schema,
            skip_duplicate_check: false
            )
            .multiMap
                { it ->
                    ashlar_input: make_ashlar_input_sample(it, sample_sheet_index_map)
                }
    } else if(!params.input_sample && params.input_cycle) {
        input_type = "cycle"
        sample_sheet_index_map = make_sample_sheet_index_map(params.input_cycle)
        ch_from_samplesheet = Channel.fromSamplesheet(
                "input_cycle",
                parameters_schema: parameters_schema,
                skip_duplicate_check: false
            )
            .map { it -> [[id:it[0]], it[3]] }
            .groupTuple()
            .multiMap
                { it ->
                    ashlar_input: it
                }

    } else if(params.input_sample && params.input_cycle) {
        Nextflow.error("ERROR: You must have EITHER an input_sample parameter OR an input_cycle parameter, but not both!")
    } else if(!params.input_sample && !params.input_cycle) {
        Nextflow.error("ERROR: You must have EITHER an input_sample parameter OR and input_cycle paramter!")
    }

    ch_versions = Channel.empty()

    // ch_from_samplesheet_2.ashlar_input.view { "ashlar_2 $it" }

    marker_sheet_index_map = make_marker_sheet_index_map(params.marker_sheet)
    ch_from_marker_sheet = Channel.fromSamplesheet(
        "marker_sheet",
        parameters_schema: parameters_schema,
        skip_duplicate_check: false
        )
    //    .map { validate_marker_sheet(it, sample_sheet_index_map, marker_sheet_index_map) }

    //
    // MODULE: BASICPY
    //

    if ( params.illumination ) {
        if (params.illumination == 'basicpy') {

            ch_from_samplesheet.ashlar_input
                .transpose()
                .set { ch_basicpy_input }

            BASICPY(ch_basicpy_input)
            ch_versions = ch_versions.mix(BASICPY.out.versions)

            BASICPY.out.fields
                .transpose()
                .map { [[it[1].getBaseName()[0..-5],it[0]], it[1]]}
                .groupTuple()
                .set { correction_files_keyed }

            ch_from_samplesheet
                .transpose()
                .map { [[it[1].split('/')[-1][0..-5],it[0]], it[1]] }
                .set { ashlar_input_keyed }

            ashlar_input_keyed
                .concat(correction_files_keyed)
                .groupTuple()
                .map { [it[0][1], it[1][1]] }
                .transpose()
                .branch {
                    dfp: it =~ /-dfp.tiff/
                    ffp: it =~ /-ffp.tiff/
                }
                .set { ordered_correction_files }
            ch_dfp = ordered_correction_files.dfp
                .groupTuple()
                .map { it[1] }
            ch_ffp = ordered_correction_files.ffp
                .groupTuple()
                .map { it[1] }

        } else if(params.illumination == 'manual') {
            ch_dfp = params.dfp
            ch_ffp = params.ffp
        }
    } else {
        ch_dfp = []
        ch_ffp = []
    }

    // MARKER_SHEET_CHECK(params.marker_sheet)
    // INPUT_CHECK(params.input_cycle, params.marker_sheet)
    INPUT_CHECK( input_type, params.input_sample, params.input_cycle, params.marker_sheet )
    // MARKER_CHECK(parmas.marker_sheet)

    // ASHLAR(ch_from_samplesheet.ashlar_input, [], [])
    // ASHLAR(ch_from_samplesheet.ashlar_input, params.dfp, params.ffp)
    // ASHLAR(ch_from_samplesheet.ashlar_input, correction_files.dfp, correction_files.ffp)
    // ASHLAR(ch_from_samplesheet.ashlar_input, ch_dfp, ch_ffp)
    ASHLAR(ch_from_samplesheet.ashlar_input, ch_dfp, ch_ffp)
    ch_versions = ch_versions.mix(ASHLAR.out.versions)

    // // Run Background Correction
    // BACKSUB(ASHLAR.out.tif, ch_markers)
    //BACKSUB(ASHLAR.out.tif, [[id: "backsub"], params.marker_sheet])
    //ch_versions = ch_versions.mix(BACKSUB.out.versions)

    /* Run Segmentation */
    DEEPCELL_MESMER(ASHLAR.out.tif, [[:],[]])
    ch_versions = ch_versions.mix(DEEPCELL_MESMER.out.versions)

    // // Run Quantification

    MCQUANT(ASHLAR.out.tif,
            DEEPCELL_MESMER.out.mask,
            [[:], file(params.marker_sheet)])
    ch_versions = ch_versions.mix(MCQUANT.out.versions)

    emit:
    // ch_from_samplesheet.ashlar_input
    // ch_versions
    // ASHLAR.out.tif
    MCQUANT.out.csv

    /*
    // // Run Reporting
    SCIMAP_MCMICRO(MCQUANT.out.csv)
    ch_versions = ch_versions.mix(SCIMAP_MCMICRO.out.versions)
    */

    /*
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )
    */

    //
    // MODULE: MultiQC
    //
    /*
    workflow_summary    = WorkflowMcmicro.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowMcmicro.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
    */
}

def make_sample_sheet_index_map(String sample_sheet_path) {
    def sample_sheet_index_map = [:]
    def header
    new File(sample_sheet_path).withReader { header_list = it.readLine().split(',') }
    def ctr = 0
    header_list.each { value ->
        sample_sheet_index_map[value] = ctr
        ctr = ctr + 1
    }
    return sample_sheet_index_map
}

def make_marker_sheet_index_map(String marker_sheet_path) {
    def marker_sheet_index_map = [:]
    def header
    new File(marker_sheet_path).withReader { header_list = it.readLine().split(',') }
    def ctr = 0
    header_list.each { value ->
        marker_sheet_index_map[value] = ctr
        ctr = ctr + 1
    }
    return marker_sheet_index_map
}

def make_ashlar_input_sample(ArrayList sample_sheet_row, Map sample_sheet_index_map) {
    sample_name_index = sample_sheet_index_map['sample']
    image_dir_path_index = sample_sheet_index_map['image_directory']
    if (sample_sheet_index_map.keySet().collect().contains("cycle_images")) {
        tmp_path = sample_sheet_row[image_dir_path_index]
        if (tmp_path[-1] != "/") {
            tmp_path = "${tmp_path}/"
        }
        cycle_images = sample_sheet_row[sample_sheet_index_map['cycle_images']].split(' ').collect{ "${tmp_path}${it}" }
        // TODO: we need to check that those files exist
        cycle_images.each{ file_path ->
            File file_test = new File(file_path)
            if (!file_test.exists()) {
                Nextflow.error("Error: ${file_path} does not exist!")
            }
        }
    } else {
        // TODO: when cycle_images not specified run every file in directory through ashlar 1 at a time
        // this won't work though will it because we've only got one sample name, so
        //   the only way to run multiple files with no samplesheet column is all at onece.
        cycle_images = []
        def image_dir = new File(sample_sheet_row[image_dir_path_index])
        image_dir.eachFileRecurse (FileType.FILES) {
            if(it.toString().endsWith(".ome.tif")){
                cycle_images << file(it)
            }
        }
    }

    ashlar_input = [[id:sample_sheet_row[sample_name_index]], cycle_images]

    return ashlar_input
}

def make_ashlar_input_cycle(ArrayList sample_sheet_row, Map sample_sheet_index_map) {
    sample_name_index = sample_sheet_index_map['sample']
    image_tiles_path_index = sample_sheet_index_map['image_tiles']
    ashlar_input = [[id:sample_sheet_row[sample_name_index]], sample_sheet_row[image_tiles_path_index]]

    return ashlar_input
}

def make_ashlar_input_cycle_channel(sample_sheet_rows, sample_sheet_index_map) {

    def input_map = [:].withDefault {[]}

    sample_sheet_rows.each { row ->
        input_map[row[0]].add(row[3])
    }

    input_list = []
    input_map.each { entry ->
        def value_str = entry.value.join(' ')
        input_list.add([[id:entry.key], entry.value])
    }

    return input_list[0]
}

def test_channel(sample_sheet_rows) {

    def input_map = [:].withDefault {[]}

    sample_sheet_rows.each { row ->
        input_map[row[0]].add(row[3])
    }

    input_list = []
    input_map.each { entry ->
        def value_str = entry.value.join(' ')
        input_list.add([[id:entry.key], entry.value])
    }

    return input_list
}
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    /*
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    */
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    /*
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
    */
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
