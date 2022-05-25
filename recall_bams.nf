#!/usr/bin/env nextflow
/* Pipeline (including QC) to re-call variants from filtered BAMs w/ ploidy *
 * Core steps:                                                              *
 *  dedup_merged_bams && samtools coverage ->                               *
 *  AdapterRemoval -> BWA-MEM -> samtools sort -> samtools merge ->         *
 *  GATK HaplotypeCaller (scattered) -> Picard MergeVcfs (gather)           *
 * QC steps:                                                                *
 *  ValidateVariants (on final gVCF)                                        */

//Default paths, globs, and regexes:
params.bam_glob = "${projectDir}/BQSR_BAMs/*_MD_IR_recal.bam"
//Regex for extracting sample ID from BAM:
params.bam_regex = ~/^(\p{Alnum}+)_MD_IR_recal$/

//Reference-related parameters for the pipeline:
params.ref_prefix = "/gpfs/gibbs/pi/tucci/pfr8/refs"
params.ref = "${params.ref_prefix}/1kGP/hs37d5/hs37d5.fa"
//File of file names for scattering interval BED files for HC:
params.scatteredHC_bed_fofn = "${params.ref_prefix}/1kGP/hs37d5/scatter_intervals/hs37d5_thresh_100Mbp_noEBV_nodecoy_sexsep_scattered_BEDs.fofn"

//Set up the channel of BQSR BAMs (unfiltered):
Channel
   .fromFilePairs(params.bam_glob, size: 1, checkIfExists: true) { file -> (file.getSimpleName() =~ params.bam_regex)[0][1] }
   .ifEmpty { error "Unable to find BAMs matching glob: ${params.bam_glob}" }
   .tap { input_bams }
   .subscribe { println "Added ${it[1]} to input_bams channel" }
//and their indices:
Channel
   .fromFilePairs(params.bam_glob+'.bai', size: 1, checkIfExists: true) { file -> (file.getSimpleName() =~ params.bam_regex)[0][1] }
   .ifEmpty { error "Unable to find BAM indices matching glob: ${params.bam_glob}.bai" }
   .tap { input_bais }
   .subscribe { println "Added ${it[1]} to input_bais channel" }

//Set up the channel for the recall metadata file contents:
Channel
   .fromPath(params.metadata_file, checkIfExists: true)
   .ifEmpty { error "Unable to find recall metadata file: ${params.metadata_file}" }
   .splitCsv(sep: "\t", header: true)
   .map { [ it.Sample, it.LibraryType ] }
   .ifEmpty { error "Recall metadata file is missing columns named Sample and LibraryType" }
   .tap { metadata }
   .subscribe { println "Added ${it[0]} metadata to metadata channel" }

//Set up the file channels for the ref and its various index components:
//Inspired by the IARC alignment-nf pipeline
//amb, ann, bwt, pac, and sa are all generated by bwa index, and alt is used by bwa when available for defining ALT mappings
//fai is generated by samtools faidx, and dict is generated by Picard and used by GATK
ref = file(params.ref, checkIfExists: true)
ref_dict = file(params.ref.replaceFirst("[.]fn?a(sta)?([.]gz)?", ".dict"), checkIfExists: true)
ref_fai = file(params.ref+'.fai', checkIfExists: true)

//Scatter interval BED file list for GATK HC scattered run:
Channel
   .fromPath(params.scatteredHC_bed_fofn, checkIfExists: true)
   .splitText()
   .map { line -> file(line.replaceAll(/[\r\n]+$/, ""), checkIfExists: true) }
   .tap { ref_scatteredHC }
   .tap { ref_scatteredHC_check }
   .subscribe { println "Added ${it} to ref_scatteredHC channel" }
//Keep track of the number of scattered intervals:
num_scatteredHC = file(params.scatteredHC_bed_fofn, checkIfExists: true)
   .readLines()
   .size()

//dbSNP for GATK ValidateVariants:
known_dbsnp = file(params.dbsnp, checkIfExists: true)
known_dbsnp_idx = file(params.dbsnp+'.idx', checkIfExists: true)

//Default parameter values:
//Regex for parsing the reference chunk ID out from the reference chunk BED filename:
params.ref_chunk_regex = ~/^.+_region(\p{Digit}+)$/

//Defaults for cpus, memory, and time for each process:
//dedup_merged_bams
params.dedup_cpus = 1
params.dedup_mem = 8
params.dedup_timeout = '24h'
//Genetic sex
//Memory in MB
params.sex_cpus = 1
params.sex_mem = 256
params.sex_timeout = '24h'
//GATK HaplotypeCaller
params.hc_cpus = 4
params.hc_mem = 24
params.hc_timeout = '24h'
//Picard MergeVcfs
params.gvcf_merge_cpus = 1
params.gvcf_merge_mem = 12
params.gvcf_merge_timeout = '24h'
//GATK ValidateVariants
params.gvcf_check_cpus = 1
params.gvcf_check_mem = 1
params.gvcf_check_timeout = '6h'

//Optionally skip dedup_merged_bams (default: don't skip):
params.skip_dedup = false
//Set up the channels to account for skipping:
(bams_for_dedup, bams_for_cov) = ( params.skip_dedup
                                   ? [Channel.empty(), input_bams.join(input_bais, by: 0, failOnDuplicate: true, failOnMismatch: true)]
                                   : [input_bams.join(input_bais, by: 0, failOnDuplicate: true, failOnMismatch: true), Channel.empty()] )

process dedup_merged_bams {
   tag "${sample_id}"

   cpus params.dedup_cpus
   memory { params.dedup_mem.plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt >= 2 ? '48h' : params.dedup_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 3

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/BQSR_filtered_BAMs", mode: 'copy', pattern: '*_filtered.ba{m,m.bai}'

   input:
   tuple val(sample_id), path(bam), path(bai) from bams_for_dedup

   output:
   tuple path("${sample_id}_dedup_merged_bams.stderr"), path("${sample_id}_dedup_merged_bams.stdout") into filter_logs
   tuple val(sample_id), path("${sample_id}_MD_IR_recal_filtered.bam"), path("${sample_id}_MD_IR_recal_filtered.bam.bai") into filtered_bams

   shell:
   '''
   module load !{params.mod_dedup}
   module load !{params.mod_samtools}
   dedup_merged_bams -i !{bam} -o !{sample_id}_MD_IR_recal_filtered.bam -t !{task.cpus} -d 2> !{sample_id}_dedup_merged_bams.stderr > !{sample_id}_dedup_merged_bams.stdout
   samtools index !{sample_id}_MD_IR_recal_filtered.bam
   '''
}

process geneticsex {
   tag "${sample_id}"

   cpus params.sex_cpus
   memory { params.sex_mem.plus(256).plus(task.attempt.minus(1).power(2).multiply(2048))+' MB' }
   time {task.attempt == 4 ? '48h' : params.sex_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 3

   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_recall_coverage.tsv'

   input:
   tuple val(sample_id), path(bam), path(bai) from filtered_bams.mix(bams_for_cov)

   output:
   tuple val(sample_id), path("${sample_id}_recall_coverage.tsv"), path(bam), path(bai) into ploidy_estimates

   shell:
   '''
   module load !{params.mod_samtools}
   samtools coverage !{bam} > !{sample_id}_recall_coverage.tsv
   '''
}

process gatk_hc {
   tag "${sample_id}_${ref_chunk}"

   cpus params.hc_cpus
   memory { params.hc_mem.plus(1).plus(task.attempt.minus(1).multiply(8))+' GB' }
   time { task.attempt == 3 ? '48h' : params.hc_timeout }
   errorStrategy { task.exitStatus in ([1]+(134..140).collect()) ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(sample_id), path("${sample_id}_recall_coverage.tsv"), path(bam), path(bai), val(librarytype) from ploidy_estimates.join(metadata, by: 0, failOnDuplicate: true, failOnMismatch: true)
   each path(intervals) from ref_scatteredHC
   path ref
   path ref_dict
   path ref_fai

   output:
   tuple val(sample_id), path("${sample_id}_${ref_chunk}.g.vcf.gz") into hc_scattered_gvcfs
   tuple val(sample_id), path("${sample_id}_${ref_chunk}.g.vcf.gz.tbi") into hc_scattered_indices
   tuple path("${sample_id}_${ref_chunk}_recall_haplotypecaller.stderr"), path("${sample_id}_${ref_chunk}_recall_haplotypecaller.stdout") into hc_logs

   shell:
   hc_retry_mem = params.hc_mem.plus(task.attempt.minus(1).multiply(8))
   ref_chunk = (intervals.getSimpleName() =~ params.ref_chunk_regex)[0][1]
   '''
   pcrfree="CONSERVATIVE"
   shopt -s nocasematch
   if [[ "!{librarytype}" =~ "free" ]]; then
      pcrfree="NONE"
   fi
   ploidy=$(!{projectDir}/estimate_chrom_ploidy.awk -v "autosomes=!{params.autosomes}" -v "sexchroms=!{params.sexchroms}" !{sample_id}_recall_coverage.tsv !{intervals})
   module load !{params.mod_gatk4}
   gatk --java-options "-Xms!{hc_retry_mem}g -Xmx!{hc_retry_mem}g" HaplotypeCaller -R !{ref} -I !{bam} -L !{intervals} -ERC GVCF --native-pair-hmm-threads !{task.cpus} -ploidy ${ploidy} --pcr-indel-model ${pcrfree} -O !{sample_id}_!{ref_chunk}.g.vcf.gz 2> !{sample_id}_!{ref_chunk}_recall_haplotypecaller.stderr > !{sample_id}_!{ref_chunk}_recall_haplotypecaller.stdout
   '''
}

process gvcf_merge{
   tag "${sample_id}"

   cpus params.gvcf_merge_cpus
   memory { params.gvcf_merge_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 3 ? '48h' : params.gvcf_merge_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/recalled_gVCFs", mode: 'copy', pattern: '*.g.vcf.g{z,z.tbi}'

   input:
   tuple val(sample_id), path(gvcfs) from hc_scattered_gvcfs.groupTuple(by: 0, size: num_scatteredHC)
   tuple val(idx_sample_id), path("${sample_id}_*.g.vcf.gz.tbi") from hc_scattered_indices.groupTuple(by: 0, size: num_scatteredHC)
   path ref
   path ref_dict
   path ref_fai

   output:
   tuple path("${sample_id}_recall_mergevcfs.stderr"), path("${sample_id}_recall_mergevcfs.stdout") into gvcf_merge_logs
   tuple val(sample_id), path("${sample_id}.g.vcf.gz"), path("${sample_id}.g.vcf.gz.tbi") into hc_final_gvcfs

   shell:
   gvcf_merge_retry_mem = params.gvcf_merge_mem.plus(task.attempt.minus(1).multiply(4))
   gvcf_list = gvcfs
      .collect { gvcf -> "I=${gvcf} " }
      .join()
   '''
   module load !{params.mod_picard}
   java -Xmx!{gvcf_merge_retry_mem}g -Xms!{gvcf_merge_retry_mem}g -jar ${PICARD} MergeVcfs SEQUENCE_DICTIONARY=!{ref_dict} !{gvcf_list} O=!{sample_id}.g.vcf.gz 2> !{sample_id}_recall_mergevcfs.stderr > !{sample_id}_recall_mergevcfs.stdout
   '''
}

process validate_gvcf {
   tag "${sample_id}"

   cpus params.gvcf_check_cpus
   memory { params.gvcf_check_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 2 ? '48h' : params.gvcf_check_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(sample_id), path("${sample_id}.g.vcf.gz"), path("${sample_id}.g.vcf.gz.tbi") from hc_final_gvcfs
   path('*.bed') from ref_scatteredHC_check.collect()
   path ref
   path ref_dict
   path ref_fai
   path known_dbsnp
   path known_dbsnp_idx

   output:
   tuple path("${sample_id}_recall_GATK_ValidateVariants.stderr"), path("${sample_id}_recall_GATK_ValidateVariants.stdout") into validate_gvcf_logs

   shell:
   '''
   module load !{params.mod_gatk4}
   regions_string=$(ls *.bed | sort -k1,1V | awk '{print "-L", $1, "";}')
   gatk --java-options "-Xms!{params.gvcf_check_mem}g -Xmx!{params.gvcf_check_mem}g" ValidateVariants -V !{sample_id}.g.vcf.gz -R !{ref} ${regions_string} -gvcf --validation-type-to-exclude ALLELES --dbsnp !{known_dbsnp} 2> !{sample_id}_recall_GATK_ValidateVariants.stderr > !{sample_id}_recall_GATK_ValidateVariants.stdout
   '''
}
