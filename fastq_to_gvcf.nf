#!/usr/bin/env nextflow
/* Pipeline (including QC) for FASTQ to gVCF                                *
 * Core steps:                                                              *
 *  AdapterRemoval -> BWA-MEM -> samtools sort -> samtools merge ->         *
 *  Picard MarkDuplicates (scattered) -> GATK IndelRealigner (scattered) -> *
 *  GATK BQSR (half-scattered) -> samtools merge (gather) + ApplyBQSR ->    *
 *  dedup_merged_bams ->                                                    *
 *  GATK HaplotypeCaller (scattered) -> Picard MergeVcfs (gather)           *
 * QC steps:                                                                *
 *  FastQC, CollectMultipleMetrics, CollectWgsMetrics,                      *
 *  mutserve+haplogrep, Yleaf, Genetic sex estimates,                       *
 *  ValidateVariants (on final gVCF)                                        */
/* Consolidated steps to reduce disk usage:                                 *
 * 1) AdapterRemoval + BWA-MEM + samtools sort                              *
 * 2) Picard MarkDuplicates + GATK IndelRealigner + GATK BQSR               *
 *    (not ApplyBQSR step though)                                           */
/* Note: half-scattered meaning BaseRecalibrator is scattered, then         *
 *  GatherBQSRReports is run, MD+IR BAMs are merged, and ApplyBQSR is run   *
 *  on the merged BAM using the gathered .recal_table                       */

//Default paths, globs, and regexes:
params.read_glob = "${projectDir}/raw_data/*_R{1,2}_001.fastq.gz"
//The first capture group in the following regex must be a unique identifier
// for the library and sequencing run:
params.idfcidlaneid_regex = ~/^(\p{Alnum}+_\p{Alnum}+_L\d+)_R[12]_001$/
//I'm setting up file names such that they follow this scheme:
//[sample ID]_[flowcell ID]_[lane ID]_R[read end]_001.fastq.gz
//^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//        Capture this part
//Furthermore, to separate out the sample ID I need another regex:
params.id_regex = ~/^(\p{Alnum}+)_\p{Alnum}+_L\d+$/

//Regex needed to get cluster position out of the read name for MarkDuplicates:
//Default is nothing, meaning to not specify READ_NAME_REGEX
//By not specifying READ_NAME_REGEX, MarkDuplicates parses more quickly
// assuming Illumina CASAVA 1.8+ read headers.
//Alternative values:
//For the HGDP ENA FASTQs, they follow a regex like this after fixing:
//[0-9A-Za-z]+[.][0-9]+:[0-9A-Za-z_]*[:]?[0-9]+:([0-9]+):([0-9]+):([0-9]+)[#]?[0-9]*/[0-9]
//Note that any alternative value for the regex needs to specify three
// capture groups for the 3 cluster coordinates:
// 1) Tile
// 2) X coordinate
// 3) Y coordinate
params.optdup_regex = ""
//And the fix for the HGDP ENA FASTQ headers:
params.fix_ena_readname = "0"

//Reference-related parameters for the pipeline:
params.ref_prefix = "/gpfs/gibbs/pi/tucci/pfr8/refs"
params.ref = "${params.ref_prefix}/1kGP/hs37d5/hs37d5.fa"
params.autosomes = "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22"
params.sexchroms = "X,Y"
//File of file names for scattering interval BED files for MD, IR, and BQSR:
params.scatteredBAM_bed_fofn = "${params.ref_prefix}/1kGP/hs37d5/scatter_intervals/hs37d5_thresh_200Mbp_allscafs_scattered_BEDs.fofn"
//File of file names for scattering interval BED files for HC:
params.scatteredHC_bed_fofn = "${params.ref_prefix}/1kGP/hs37d5/scatter_intervals/hs37d5_thresh_100Mbp_noEBV_nodecoy_sexsep_scattered_BEDs.fofn"

//Databases of SNPs and INDELs for IR, BQSR, and VQSR:
params.tgp_indels = "${params.ref_prefix}/Broad/b37/1000G_phase1.indels.b37.vcf"
params.mills_indels = "${params.ref_prefix}/Broad/b37/Mills_and_1000G_gold_standard.indels.b37.vcf"
params.dbsnp = "${params.ref_prefix}/Broad/b37/dbsnp_138.b37.vcf"
params.tgp_snps = "${params.ref_prefix}/Broad/b37/1000G_phase1.snps.high_confidence.b37.vcf"

//Set up the channel of raw paired FASTQs:
Channel
   .fromFilePairs(params.read_glob, checkIfExists: true) { file -> (file.getSimpleName() =~ params.idfcidlaneid_regex)[0][1] }
   .ifEmpty { error "Unable to find reads matching glob: ${params.read_glob}" }
   .map { run -> [ (run[0] =~ params.id_regex)[0][1], run[0], run[1]] }
   .tap { fastq_pairs_fastqc }
   .tap { fastq_pairs_tojoin }
   .groupTuple()
   .map { sample_id,run_id,fastqs -> [sample_id, groupKey(sample_id, fastqs.size())] }
   .combine(fastq_pairs_tojoin, by: 0)
   .map { item -> [item.get(1), item.get(2), item.get(3)] }
   .tap { fastq_pairs }
   .subscribe { println "Added ${it[1]} to fastq_pairs channel" }

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
ref_alt = file(params.ref+'.alt')
ref_amb = file(params.ref+'.amb', checkIfExists: true)
ref_ann = file(params.ref+'.ann', checkIfExists: true)
ref_bwt = file(params.ref+'.bwt', checkIfExists: true)
ref_dict = file(params.ref.replaceFirst("[.]fn?a(sta)?([.]gz)?", ".dict"), checkIfExists: true)
ref_fai = file(params.ref+'.fai', checkIfExists: true)
ref_pac = file(params.ref+'.pac', checkIfExists: true)
ref_sa = file(params.ref+'.sa', checkIfExists: true)

//Known sites files for IR and BQSR:
known_tgp_indels = file(params.tgp_indels, checkIfExists: true)
known_tgp_indels_idx = file(params.tgp_indels+'.idx', checkIfExists: true)
known_mills_indels = file(params.mills_indels, checkIfExists: true)
known_mills_indels_idx = file(params.mills_indels+'.idx', checkIfExists: true)
known_dbsnp = file(params.dbsnp, checkIfExists: true)
known_dbsnp_idx = file(params.dbsnp+'.idx', checkIfExists: true)
known_tgp = file(params.tgp_snps, checkIfExists: true)
known_tgp_idx = file(params.tgp_snps+'.idx', checkIfExists: true)

//Scatter interval BED file list for BAM scattering:
Channel
   .fromPath(params.scatteredBAM_bed_fofn, checkIfExists: true)
   .splitText()
   .map { line -> file(line.replaceAll(/[\r\n]+$/, ""), checkIfExists: true) }
   .tap { ref_scatteredBAM }
   .subscribe { println "Added ${it} to ref_scatteredBAM channel" }
num_scatteredBAM = file(params.scatteredBAM_bed_fofn, checkIfExists: true)
   .readLines()
   .size()

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

//Default parameter values:
//AdapterRemoval parameters:
//Minimum read length to retain:
//32 bp since k=31-mers are pretty standard
params.minlength = 32
//Maximum quality score expected:
//Q42 since HiSeq X produces Q42, whereas the AdapterRemoval default is Q41 :(
params.qualitymax = 42
//Mate separator (i.e. single character prior to the digit indicating the read end):
//For Illumina CASAVA 1.8+ read headers, this is a space " "
//For ENA and SRA read headers, this is sometimes a slash "/", though may be "."
//For older Illumina reads, this is a slash "/"
params.mate_sep = " "

//Mapping parameters:
//Sequencing platform (PL tag) for read group (RG):
//We're setting the default here as ILLUMINA:
params.PL = 'ILLUMINA'

//mutserve/haplogrep rCRS reference path:
params.rcrs = '/home/pfr8/bin/mutserve/2.0.0-rc12/rCRS.fasta'
rcrs = file(params.rcrs, checkIfExists: true)

//Yleaf position file path:
params.yleafpos = '/home/pfr8/bin/Yleaf/Position_files/WGS_hs37d5.txt'
yleafpos = file(params.yleafpos, checkIfExists: true)

//MarkDuplicates parameters:
//Optical duplicate pixel distance for marking duplicates:
params.optdupdist = 2500

//Regex for parsing the reference chunk ID out from the reference chunk BED filename:
params.ref_chunk_regex = ~/^.+_region(\p{Digit}+)$/

//Defaults for cpus, memory, and time for each process:
//FastQC
//Memory in MB
params.fastqc_cpus = 1
params.fastqc_mem = 256
params.fastqc_timeout = '3h'
//AdapterRemoval and BWA-MEM+samtools sort
params.mapping_cpus = 20
params.mapping_mem = 64
params.mapping_timeout = '24h'
if (params.mapping_cpus < 2) {
   error "Cannot specify less than 2 threads for mapping"
}
if (params.mapping_mem < 32) {
   error "Running the map+sort step with less than 32 GB RAM probably won't work"
}
//samtools merge
//Memory in MB
params.merging_cpus = 20
params.merging_mem = 256
params.merging_timeout = '24h'
//mutserve+haplogrep
//Memory in MB
params.mtdna_cpus = 1
params.mtdna_mem = 256
params.mtdna_timeout = '24h'
//Yleaf
params.y_cpus = 1
params.y_mem = 8
params.y_timeout = '24h'
//Genetic sex
//Memory in MB
params.sex_cpus = 1
params.sex_mem = 256
params.sex_timeout = '24h'
//Picard MarkDuplicates
//GATK RealignerTargetCreator+IndelRealigner
//GATK BaseRecalibrator
params.mdirbqsr_cpus = 1
params.mdirbqsr_mem = 32
params.mdirbqsr_timeout = '24h'
//GATK ApplyBQSR
params.bqsr_cpus = 20
params.bqsr_mem = 32
params.bqsr_timeout = '24h'
/*//Picard CollectMultipleMetrics+CollectOxoGMetrics+CollectRawWgsMetrics*/
//Picard CollectMultipleMetrics+CollectRawWgsMetrics
params.metrics_cpus = 1
params.metrics_mem = 32
params.metrics_timeout = '24h'
//dedup_merged_bams
params.dedup_cpus = 1
params.dedup_mem = 8
params.dedup_timeout = '24h'
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

process fastqc {
   tag "${run_id}"

   cpus params.fastqc_cpus
   memory { params.fastqc_mem.plus(256).plus(task.attempt.minus(1).multiply(512))+' MB' }
   time { task.attempt == 2 ? '12h' : params.fastqc_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/FastQC", mode: 'copy', pattern: '*_fastqc.{html,zip}'
   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*_fastqc.std{err,out}'
//   scratch "${scratch_dir}"
//   stageOutMode copy

//   module 'FastQC/0.11.9-Java-1.8'

   input:
   tuple val(sample_id), val(run_id), file(reads) from fastq_pairs_fastqc

   output:
   tuple file("*_fastqc.html"), file("*_fastqc.zip") into fastqc_results
   tuple file("${run_id}_fastqc.stderr"), file("${run_id}_fastqc.stdout") into fastqc_logs

   shell:
   '''
   module load !{params.mod_fastqc}
   fastqc -t !{task.cpus} --noextract !{reads} 2> !{run_id}_fastqc.stderr > !{run_id}_fastqc.stdout
   '''
}

//Debugging on 2021/12/10 indicates that AdapterRemoval 5bb3b65 has a bug related to --interleaved-output that
// prevents outputting anything /dev/stdout. I took a look at the source code, but couldn't find an obvious bug.
// I checked options parsing and didn't see any overwriting/resetting of --interleaved-output or --output1,
// and checked that /dev/stdout is recognized as STDOUT in the FASTQ writing code, as well as briefly checking
// that mate-separator wasn't an issue (Illumina 1.8+ data, and I didn't set mate-separator to " ").
//Some manual pre-run checks on HGDP data indicate that we need to adjust
// the FASTQs for them before passing to BWA-MEM, as their read header format
// is incompatible with Picard MarkDuplicates optical duplicate parsing...
process mapreads {
   tag "${run_id}"

   cpus params.mapping_cpus
   memory { params.mapping_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 3 ? '48h' : params.mapping_timeout }
   errorStrategy { task.exitStatus in ([1]+(134..140).collect()) ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_trimming_stats.settings'

//   module 'AdapterRemoval/5bb3b65'
//   module 'bwa/13b5637'
//   module 'samtools/af811a6'

   input:
//   tuple val(sample_id), val(run_id), file(readone), file(readtwo) from trimmed_fastq_pairs
   tuple val(sample_id), val(run_id), file(reads) from fastq_pairs
   file ref
   if (ref_alt.exists()) {
      file ref_alt
   }
   file ref_ann
   file ref_amb
   file ref_bwt
   file ref_pac
   file ref_sa

   output:
   tuple file("${run_id}_trimming_stats.settings"), file("${run_id}_AdapterRemoval.stderr"), file("${run_id}_AdapterRemoval.stdout") into adaptertrim_logs
   tuple file("${run_id}_bwamem.stderr"), file("${run_id}_samtools_sort.stderr"), file("${run_id}_samtools_sort.stdout"), file("${run_id}_samtools_index.stderr"), file("${run_id}_samtools_index.stdout") into mapreads_logs
   tuple val(sample_id), file("${run_id}_sorted.bam") into sorted_perrun_bams
   tuple val(sample_id), file("${run_id}_sorted.bam.bai") into sorted_perrun_bais
//   tuple file("${run_id}_AdapterRemoval.stderr"), file("${run_id}_bwamem.stderr"), file("${run_id}_samtools_sort.stderr"), file("${run_id}_samtools_sort.stdout"), file("${run_id}_samtools_index.stderr"), file("${run_id}_samtools_index.stdout") into mapreads_logs

   shell:
   map_retry_mem = params.mapping_mem.plus(task.attempt.minus(1).multiply(16))
/*   //This looks a bit arbitrary, but it's an educated guess:
   //samtools sort is generally I/O bound and only multi-threads during compression, so it should get the least threads
   //AdapterRemoval is faster than BWA-MEM (single-threaded runtime independently is about the same as 10-threaded BWA-MEM)
   //BWA-MEM should get the most threads allocated, perhaps twice as much as any other
   bwa_cpus = [task.cpus.intdiv(2), 1].max()
   sort_cpus = [task.cpus.intdiv(4), 1].max()
   trim_cpus = [task.cpus.minus(bwa_cpus).minus(sort_cpus), 1].max()*/
   //Without adapter trimming, the partition of CPUs is about 3/4 to 1/4 BWA-MEM to samtools sort:
   sort_cpus = [task.cpus.intdiv(4), 1].max()
   bwa_cpus = [task.cpus.minus(sort_cpus), 1].max()
   //This too looks a bit arbitrary, but I'm gauging human mapping wouldn't take more than 20 GB
   //Also, we don't account for the addition of memory during retries, as
   // the problem could be two possible cases, neither of which benefits from
   // increasing per-thread allocation to samtools sort:
   // 1) BWA-MEM requires more memory (so keep sort_mem fixed and increase total)
   // 2) samtools sort is transiently exceeding the requested amount
   sort_mem = params.mapping_mem.minus(20).intdiv(sort_cpus)
   bwa_options = '-K 100000000 -Y'
//   bwa_options = '-p -K 100000000 -Y'
   if (params.fix_ena_readname == "0")
      '''
      module load !{params.mod_adapterremoval}
      module load !{params.mod_bwa}
      module load !{params.mod_samtools}
      AdapterRemoval --threads !{task.cpus} --file1 !{reads[0]} --file2 !{reads[1]} --mate-separator "!{params.mate_sep}" --qualitymax !{params.qualitymax} --minlength !{params.minlength} --settings !{run_id}_trimming_stats.settings --gzip --output1 !{run_id}_trimmed_R1.fastq.gz --output2 !{run_id}_trimmed_R2.fastq.gz --discarded !{run_id}_discarded.fastq.gz --singleton !{run_id}_singleton.fastq.gz 2> !{run_id}_AdapterRemoval.stderr > !{run_id}_AdapterRemoval.stdout
      bwa mem -t !{bwa_cpus} !{bwa_options} -R "@RG\\tID:!{run_id}\\tSM:!{sample_id}\\tPL:!{params.PL}\\tLB:!{run_id}" !{ref} !{run_id}_trimmed_R1.fastq.gz !{run_id}_trimmed_R2.fastq.gz 2> !{run_id}_bwamem.stderr | samtools sort -@ !{sort_cpus} -m !{sort_mem}G -o !{run_id}_sorted.bam 2> !{run_id}_samtools_sort.stderr > !{run_id}_samtools_sort.stdout 
      samtools index !{run_id}_sorted.bam 2> !{run_id}_samtools_index.stderr > !{run_id}_samtools_index.stdout
      rm !{run_id}_trimmed_R[12].fastq.gz !{run_id}_discarded.fastq.gz !{run_id}_singleton.fastq.gz
      '''
   else
      '''
      module load !{params.mod_adapterremoval}
      module load !{params.mod_bwa}
      module load !{params.mod_samtools}
      AdapterRemoval --threads !{task.cpus} --file1 !{reads[0]} --file2 !{reads[1]} --mate-separator "!{params.mate_sep}" --qualitymax !{params.qualitymax} --minlength !{params.minlength} --settings !{run_id}_trimming_stats.settings --gzip --output1 !{run_id}_trimmed_R1.fastq.gz --output2 !{run_id}_trimmed_R2.fastq.gz --discarded !{run_id}_discarded.fastq.gz --singleton !{run_id}_singleton.fastq.gz 2> !{run_id}_AdapterRemoval.stderr > !{run_id}_AdapterRemoval.stdout
      bwa mem -t !{bwa_cpus} !{bwa_options} -R "@RG\\tID:!{run_id}\\tSM:!{sample_id}\\tPL:!{params.PL}\\tLB:!{run_id}" !{ref} <(gzip -dc !{run_id}_trimmed_R1.fastq.gz | sed 's/ /:/g') <(gzip -dc !{run_id}_trimmed_R2.fastq.gz | sed 's/ /:/g') 2> !{run_id}_bwamem.stderr | samtools sort -@ !{sort_cpus} -m !{sort_mem}G -o !{run_id}_sorted.bam 2> !{run_id}_samtools_sort.stderr > !{run_id}_samtools_sort.stdout 
      samtools index !{run_id}_sorted.bam 2> !{run_id}_samtools_index.stderr > !{run_id}_samtools_index.stdout
      rm !{run_id}_trimmed_R[12].fastq.gz !{run_id}_discarded.fastq.gz !{run_id}_singleton.fastq.gz
      '''
//   AdapterRemoval --threads !{trim_cpus} --file1 !{reads[0]} --file2 !{reads[1]} --qualitymax !{params.qualitymax} --minlength !{params.minlength} --settings !{run_id}_trimming_stats.settings --interleaved-output --output1 /dev/stdout 2> !{run_id}_AdapterRemoval.stderr | bwa mem -t !{bwa_cpus} !{bwa_options} -R "@RG\\tID:!{run_id}\\tSM:!{sample_id}\\tPL:!{params.PL}\\tLB:!{run_id}" !{ref} - 2> !{run_id}_bwamem.stderr | samtools sort -@ !{sort_cpus} -m !{sort_mem}G -o !{run_id}_sorted.bam 2> !{run_id}_samtools_sort.stderr > !{run_id}_samtools_sort.stdout 
}

process mergebams {
   tag "${sample_id}"

   cpus params.merging_cpus
   memory { params.merging_mem.plus(256).plus(task.attempt.minus(1).multiply(512))+' MB' }
   time { task.attempt == 2 ? '48h' : params.merging_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

//   module 'samtools/af811a6'

   input:
   tuple val(sample_id), file("${sample_id}_*_sorted.bam") from sorted_perrun_bams.groupTuple(by: 0)
   tuple val(bai_sample_id), file("${sample_id}_*_sorted.bam.bai") from sorted_perrun_bais.groupTuple(by: 0)

   output:
   tuple file("${sample_id}_samtools_merge.stderr"), file("${sample_id}_samtools_merge.stdout"), file("${sample_id}_samtools_index_merged.stderr"), file("${sample_id}_samtools_index_merged.stdout") into mergebams_logs
   tuple val(sample_id), file("${sample_id}.bam"), file("${sample_id}.bam.bai") into merged_bams,mtdna_bams,y_bams,sex_bams

   shell:
   '''
   module load !{params.mod_samtools}
   samtools merge -@ !{task.cpus} !{sample_id}.bam !{sample_id}_*_sorted.bam 2> !{sample_id}_samtools_merge.stderr > !{sample_id}_samtools_merge.stdout
   samtools index !{sample_id}.bam 2> !{sample_id}_samtools_index_merged.stderr > !{sample_id}_samtools_index_merged.stdout
   '''
}

process mtdna {
   tag "${sample_id}"

   cpus params.mtdna_cpus
   memory { params.mtdna_mem.plus(256).plus(task.attempt.minus(1).multiply(512))+' MB' }
   time {task.attempt == 3 ? '48h' : params.mtdna_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_haplogrep.tsv'

//   module 'mutserve/2.0.0-rc12'
//   module 'haplogrep/2.4.0'

   input:
   tuple val(sample_id), file("${sample_id}.bam"), file("${sample_id}.bam.bai") from mtdna_bams
   rcrs

   output:
   tuple file("${sample_id}_mutserve.stderr"), file("${sample_id}_mutserve.stdout"), file("${sample_id}_haplogrep.stderr"), file("${sample_id}_haplogrep.stdout") into mtdna_logs
   path "${sample_id}_haplogrep.tsv" into mtdna_haplogroups

   shell:
   '''
   module load !{params.mod_mutserve}
   module load !{params.mod_haplogrep}
   mutserve call --reference !{rcrs} --threads !{task.cpus} --output !{sample_id}_mutserve.vcf.gz !{sample_id}.bam 2> !{sample_id}_mutserve.stderr > !{sample_id}_mutserve.stdout
   haplogrep classify --format vcf --in !{sample_id}_mutserve.vcf.gz --out !{sample_id}_haplogrep.tsv 2> !{sample_id}_haplogrep.stderr > !{sample_id}_haplogrep.stdout
   '''
}

process yleaf {
   tag "${sample_id}"

   cpus params.y_cpus
   memory { params.y_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time {task.attempt == 3 ? '48h' : params.y_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_Yhaplogroup.txt'
//   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*/hg_prediction.hg', saveAs: { hgpath -> hgpath.tokenize('/').get(0)+'_Yhaplogroup.txt' }

//   module 'Yleaf/7c33ca0'

   input:
   tuple val(sample_id), file("${sample_id}.bam"), file("${sample_id}.bam.bai") from y_bams
   yleafpos

   output:
   tuple file("${sample_id}_yleaf.stderr"), file("${sample_id}_yleaf.stdout") into y_logs
   path "${sample_id}_Yhaplogroup.txt" into y_haplogroups

   shell:
   '''
   module load !{params.mod_yleaf}
   python3 ${YLEAF} -bam !{sample_id}.bam -pos !{yleafpos} -r 1 -q 20 -b 90 -out yleaf_!{sample_id} 2> !{sample_id}_yleaf.stderr > !{sample_id}_yleaf.stdout
   cp yleaf_!{sample_id}/hg_prediction.hg !{sample_id}_Yhaplogroup.txt
   '''
}

process geneticsex {
   tag "${sample_id}"

   cpus params.sex_cpus
   memory { params.sex_mem.plus(256).plus(task.attempt.minus(1).power(2).multiply(2048))+' MB' }
   time {task.attempt == 4 ? '48h' : params.sex_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 3

   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_coverage.tsv'

//   module 'samtools/af811a6'

   input:
   tuple val(sample_id), file("${sample_id}.bam"), file("${sample_id}.bam.bai") from sex_bams

   output:
   tuple val(sample_id), path("${sample_id}_coverage.tsv") into ploidy_estimates

   shell:
   '''
   module load !{params.mod_samtools}
   samtools coverage !{sample_id}.bam > !{sample_id}_coverage.tsv
   '''
}

process mdirbqsr {
   tag "${sample_id}_${ref_chunk}"

   cpus params.mdirbqsr_cpus
   memory { params.mdirbqsr_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time {task.attempt >= 3 ? '48h' : params.mdirbqsr_timeout }
   errorStrategy { task.exitStatus in ([1]+(134..140).collect()) ? 'retry' : 'terminate' }
   maxRetries 3

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/BQSR", mode: 'copy', pattern: '*.recal_table'
   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*_metrics.txt'

/*   module 'picard/2.24.0'
   module 'samtools/af811a6'
   module 'GATK/3.8-0-Java-1.8.0_121'
   module 'GATK/4.1.8.1-Java-1.8'
   module 'R/3.6.1-foss-2018b'*/

   input:
   tuple val(sample_id), file("${sample_id}.bam"), file("${sample_id}.bam.bai") from merged_bams
   each file(intervals) from ref_scatteredBAM
   file ref
   file ref_dict
   file ref_fai
   file known_dbsnp
   file known_dbsnp_idx
   file known_tgp
   file known_tgp_idx
   file known_mills_indels
   file known_mills_indels_idx
   file known_tgp_indels
   file known_tgp_indels_idx

   output:
   tuple file("${sample_id}_${ref_chunk}_markdup.stderr"), file("${sample_id}_${ref_chunk}_markdup.stdout"), file("${sample_id}_${ref_chunk}_samtools_index_markdup.stderr"), file("${sample_id}_${ref_chunk}_samtools_index_markdup.stdout") into markdup_logs
   tuple file("${sample_id}_${ref_chunk}_GATK_RTC.stderr"), file("${sample_id}_${ref_chunk}_GATK_RTC.stdout"), file("${sample_id}_${ref_chunk}_GATK_IR.stderr"), file("${sample_id}_${ref_chunk}_GATK_IR.stdout") into ir_logs
   tuple file("${sample_id}_${ref_chunk}_baserecal.stderr"), file("${sample_id}_${ref_chunk}_baserecal.stdout") into baserecal_logs
   tuple val(sample_id), file("${sample_id}_${ref_chunk}_MD_IR.bam") into mdir_bams
   tuple val(sample_id), file("${sample_id}_${ref_chunk}_MD_IR.bam.bai") into mdir_bais
   path "${sample_id}_${ref_chunk}_markdup_metrics.txt" into markdup_metrics
   tuple val(sample_id), file("${sample_id}_${ref_chunk}.recal_table") into bqsr_tables

   shell:
   mdirbqsr_retry_mem = params.mdirbqsr_mem.plus(task.attempt.minus(1).multiply(16))
   ref_chunk = (intervals.getSimpleName() =~ params.ref_chunk_regex)[0][1]
   if (params.optdup_regex != "")
      '''
      #Shard the merged BAM:
      module load !{params.mod_samtools}
      samtools view -b -@ !{task.cpus} -L !{intervals} !{sample_id}.bam > !{sample_id}_!{ref_chunk}.bam
      samtools index !{sample_id}_!{ref_chunk}.bam
      #Picard MarkDuplicates:
      module load !{params.mod_picard}
      java -Xms!{mdirbqsr_retry_mem}g -jar ${PICARD} MarkDuplicates METRICS_FILE=!{sample_id}_!{ref_chunk}_markdup_metrics.txt OPTICAL_DUPLICATE_PIXEL_DISTANCE=!{params.optdupdist} READ_NAME_REGEX="!{params.optdup_regex}" INPUT=!{sample_id}_!{ref_chunk}.bam OUTPUT=!{sample_id}_!{ref_chunk}_MD.bam 2> !{sample_id}_!{ref_chunk}_markdup.stderr > !{sample_id}_!{ref_chunk}_markdup.stdout
      samtools index !{sample_id}_!{ref_chunk}_MD.bam 2> !{sample_id}_!{ref_chunk}_samtools_index_markdup.stderr > !{sample_id}_!{ref_chunk}_samtools_index_markdup.stdout
      rm !{sample_id}_!{ref_chunk}.ba{m,m.bai}
      #GATK IndelRealigner:
      module load !{params.mod_gatk3}
      java -Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g -jar ${EBROOTGATK}/GenomeAnalysisTK.jar -T RealignerTargetCreator -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD.bam -known !{known_tgp_indels} -known !{known_mills_indels} -o !{sample_id}_!{ref_chunk}_IR.intervals 2> !{sample_id}_!{ref_chunk}_GATK_RTC.stderr > !{sample_id}_!{ref_chunk}_GATK_RTC.stdout
      java -Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g -jar ${EBROOTGATK}/GenomeAnalysisTK.jar -T IndelRealigner -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD.bam -targetIntervals !{sample_id}_!{ref_chunk}_IR.intervals -o !{sample_id}_!{ref_chunk}_MD_IR.bam 2> !{sample_id}_!{ref_chunk}_GATK_IR.stderr > !{sample_id}_!{ref_chunk}_GATK_IR.stdout
      mv !{sample_id}_!{ref_chunk}_MD_IR.bai !{sample_id}_!{ref_chunk}_MD_IR.bam.bai
      rm !{sample_id}_!{ref_chunk}_MD.ba{m,m.bai}
      module unload !{params.mod_gatk3}
      #GATK BaseQualityScoreRecalibration:
      module load !{params.mod_gatk4}
      module load !{params.mod_R}
      gatk --java-options "-Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g" BaseRecalibrator -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD_IR.bam --use-original-qualities -O !{sample_id}_!{ref_chunk}.recal_table -known-sites !{known_dbsnp} -known-sites !{known_tgp} -known-sites !{known_mills_indels} 2> !{sample_id}_!{ref_chunk}_baserecal.stderr > !{sample_id}_!{ref_chunk}_baserecal.stdout
      '''
   else
      '''
      #Shard the merged BAM:
      module load !{params.mod_samtools}
      samtools view -b -@ !{task.cpus} -L !{intervals} !{sample_id}.bam > !{sample_id}_!{ref_chunk}.bam
      samtools index !{sample_id}_!{ref_chunk}.bam
      #Picard MarkDuplicates:
      module load !{params.mod_picard}
      java -Xms!{mdirbqsr_retry_mem}g -jar ${PICARD} MarkDuplicates METRICS_FILE=!{sample_id}_!{ref_chunk}_markdup_metrics.txt OPTICAL_DUPLICATE_PIXEL_DISTANCE=!{params.optdupdist} INPUT=!{sample_id}_!{ref_chunk}.bam OUTPUT=!{sample_id}_!{ref_chunk}_MD.bam 2> !{sample_id}_!{ref_chunk}_markdup.stderr > !{sample_id}_!{ref_chunk}_markdup.stdout
      samtools index !{sample_id}_!{ref_chunk}_MD.bam 2> !{sample_id}_!{ref_chunk}_samtools_index_markdup.stderr > !{sample_id}_!{ref_chunk}_samtools_index_markdup.stdout
      rm !{sample_id}_!{ref_chunk}.ba{m,m.bai}
      #GATK IndelRealigner:
      module load !{params.mod_gatk3}
      java -Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g -jar ${EBROOTGATK}/GenomeAnalysisTK.jar -T RealignerTargetCreator -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD.bam -known !{known_tgp_indels} -known !{known_mills_indels} -o !{sample_id}_!{ref_chunk}_IR.intervals 2> !{sample_id}_!{ref_chunk}_GATK_RTC.stderr > !{sample_id}_!{ref_chunk}_GATK_RTC.stdout
      java -Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g -jar ${EBROOTGATK}/GenomeAnalysisTK.jar -T IndelRealigner -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD.bam -targetIntervals !{sample_id}_!{ref_chunk}_IR.intervals -o !{sample_id}_!{ref_chunk}_MD_IR.bam 2> !{sample_id}_!{ref_chunk}_GATK_IR.stderr > !{sample_id}_!{ref_chunk}_GATK_IR.stdout
      mv !{sample_id}_!{ref_chunk}_MD_IR.bai !{sample_id}_!{ref_chunk}_MD_IR.bam.bai
      rm !{sample_id}_!{ref_chunk}_MD.ba{m,m.bai}
      module unload !{params.mod_gatk3}
      #GATK BaseQualityScoreRecalibration:
      module load !{params.mod_gatk4}
      module load !{params.mod_R}
      gatk --java-options "-Xmx!{mdirbqsr_retry_mem}g -Xms!{mdirbqsr_retry_mem}g" BaseRecalibrator -R !{ref} -L !{intervals} -I !{sample_id}_!{ref_chunk}_MD_IR.bam --use-original-qualities -O !{sample_id}_!{ref_chunk}.recal_table -known-sites !{known_dbsnp} -known-sites !{known_tgp} -known-sites !{known_mills_indels} 2> !{sample_id}_!{ref_chunk}_baserecal.stderr > !{sample_id}_!{ref_chunk}_baserecal.stdout
      '''
//   gatk --java-options "-Xmx!{params.bqsr_mem}g -Xms!{params.bqsr_mem}g" AnalyzeCovariates -bqsr 
}

process mergebqsrbams {
   tag "${sample_id}"

   cpus params.bqsr_cpus
   memory { params.bqsr_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 3 ? '48h' : params.bqsr_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/BQSR", mode: 'copy', pattern: '*.recal_table'
//   publishDir path: "${params.output_dir}/BQSR_BAMs", mode: 'copy', pattern: '*_MD_IR_recal.ba{m,m.bai}'

//   module 'samtools/af811a6'
//   module 'GATK/4.1.8.1-Java-1.8'
//   module 'R/3.6.1-foss-2018b'

   input:
   tuple val(sample_id), file("${sample_id}_*_MD_IR.bam") from mdir_bams.groupTuple(by: 0, size: num_scatteredBAM)
   tuple val(bai_sample_id), file("${sample_id}_*_MD_IR.bam.bai") from mdir_bais.groupTuple(by: 0, size: num_scatteredBAM)
   tuple val(table_sample_id), file(recaltables) from bqsr_tables.groupTuple(by: 0, size: num_scatteredBAM)

   output:
   tuple file("${sample_id}_samtools_MDIRmerge.stderr"), file("${sample_id}_samtools_MDIRmerge.stdout"), file("${sample_id}_samtools_index_MDIRmerged.stderr"), file("${sample_id}_samtools_index_MDIRmerged.stdout") into mergemdirbams_logs
   tuple file("${sample_id}_GatherBQSRReports.stderr"), file("${sample_id}_GatherBQSRReports.stdout") into gatherbqsr_logs
   tuple file("${sample_id}_ApplyBQSR.stderr"), file("${sample_id}_ApplyBQSR.stdout") into applybqsr_logs
   tuple val(sample_id), file("${sample_id}_MD_IR_recal.bam"), file("${sample_id}_MD_IR_recal.bam.bai") into merged_bqsr_bams,bqsr_bams_qc

   shell:
   bqsr_retry_mem = params.bqsr_mem.plus(task.attempt.minus(1).multiply(16))
   recaltable_list = recaltables
//      .map { recaltable -> "-I ${recaltable} " }
//      .toSortedList { a,b -> (a =~ /^-I .+_(\d+)[.]recal_table $/)[0][1].toInteger() <=> (b =~ /^-I .+_(\d+)[.]recal_table $/)[0][1].toInteger() }
      .collect { recaltable -> "-I ${recaltable} " }
      .join()
   '''
   module load !{params.mod_samtools}
   module load !{params.mod_gatk4}
   module load !{params.mod_R}
   samtools merge -@ !{task.cpus} -c -p -f !{sample_id}_MD_IR.bam !{sample_id}_*_MD_IR.bam 2> !{sample_id}_samtools_MDIRmerge.stderr > !{sample_id}_samtools_MDIRmerge.stdout
   samtools index !{sample_id}_MD_IR.bam 2> !{sample_id}_samtools_index_MDIRmerged.stderr > !{sample_id}_samtools_index_MDIRmerged.stdout
   gatk --java-options "-Xmx!{bqsr_retry_mem}g -Xms!{bqsr_retry_mem}g" GatherBQSRReports !{recaltable_list} -O !{sample_id}.recal_table 2> !{sample_id}_GatherBQSRReports.stderr > !{sample_id}_GatherBQSRReports.stdout
   gatk --java-options "-Xmx!{bqsr_retry_mem}g -Xms!{bqsr_retry_mem}g" ApplyBQSR -R !{ref} -I !{sample_id}_MD_IR.bam --use-original-qualities --bqsr-recal-file !{sample_id}.recal_table --static-quantized-quals 10 --static-quantized-quals 20 --static-quantized-quals 30 --add-output-sam-program-record -O !{sample_id}_MD_IR_recal.bam 2> !{sample_id}_ApplyBQSR.stderr > !{sample_id}_ApplyBQSR.stdout
   mv !{sample_id}_MD_IR_recal.bai !{sample_id}_MD_IR_recal.bam.bai
   rm !{sample_id}_MD_IR.ba{m,m.bai}
   '''
}

process bammetrics {
   tag "${sample_id}"

   cpus params.metrics_cpus
   memory { params.metrics_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 2 ? '48h' : params.metrics_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/stats", mode: 'copy', pattern: '*.{txt,pdf}'

//   module 'picard/2.24.0'
//   module 'R/3.6.1-foss-2018b'

   input:
   tuple val(sample_id), file("${sample_id}_MD_IR_recal.bam"), file("${sample_id}_MD_IR_recal.bam.bai") from bqsr_bams_qc
   file ref
   file ref_dict
   file known_dbsnp
   file known_dbsnp_idx

   output:
//   tuple file("${sample_id}_picard_CMM.stderr"), file("${sample_id}_picard_CMM.stdout"), file("${sample_id}_picard_OxoG.stderr"), file("${sample_id}_picard_OxoG.stdout"), file("${sample_id}_picard_RawWGS.stderr"), file("${sample_id}_picard_RawWGS.stdout") into bammetrics_logs
   tuple file("${sample_id}_picard_CMM.stderr"), file("${sample_id}_picard_CMM.stdout"), file("${sample_id}_picard_WGS.stderr"), file("${sample_id}_picard_WGS.stdout") into bammetrics_logs
   tuple file("${sample_id}_picardmetrics*.txt"), file("${sample_id}_picardmetrics*.pdf") into bammetrics_stats

   shell:
   accum_opts = 'METRIC_ACCUMULATION_LEVEL=null METRIC_ACCUMULATION_LEVEL=SAMPLE METRIC_ACCUMULATION_LEVEL=LIBRARY'
   metric_opts = 'PROGRAM=CollectGcBiasMetrics'
   '''
   module load !{params.mod_picard}
   module load !{params.mod_R}
   java -Xmx!{params.metrics_mem}g -Xms!{params.metrics_mem}g -jar ${PICARD} CollectWgsMetrics I=!{sample_id}_MD_IR_recal.bam R=!{ref} INCLUDE_BQ_HISTOGRAM=true USE_FAST_ALGORITHM=false O=!{sample_id}_picardmetrics_WGS.txt 2> !{sample_id}_picard_WGS.stderr > !{sample_id}_picard_WGS.stdout
   java -Xmx!{params.metrics_mem}g -Xms!{params.metrics_mem}g -jar ${PICARD} CollectMultipleMetrics I=!{sample_id}_MD_IR_recal.bam R=!{ref} !{accum_opts} !{metric_opts} O=!{sample_id}_picardmetrics 2> !{sample_id}_picard_CMM.stderr > !{sample_id}_picard_CMM.stdout
   '''
//   java -Xmx!{params.metrics_mem}g -Xms!{params.metrics_mem}g -jar ${PICARD} CollectRawWgsMetrics I=!{sample_id}_MD_IR_recal.bam R=!{ref} INCLUDE_BQ_HISTOGRAM=true USE_FAST_ALGORITHM=false O=!{sample_id}_picardmetrics_RawWGS.txt 2> !{sample_id}_picard_RawWGS.stderr > !{sample_id}_picard_RawWGS.stdout
//   java -Xmx!{params.metrics_mem}g -Xms!{params.metrics_mem}g -jar ${PICARD} CollectOxoGMetrics I=!{sample_id}_MD_IR_recal.bam R=!{ref} DB_SNP=!{known_dbsnp} O=!{sample_id}_picardmetrics_OxoG_metrics.txt 2> !{sample_id}_picard_OxoG.stderr > !{sample_id}_picard_OxoG.stdout
}

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
   tuple val(sample_id), path(bam), path(bai) from merged_bqsr_bams

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

process gatk_hc {
   tag "${sample_id}_${ref_chunk}"

   cpus params.hc_cpus
   memory { params.hc_mem.plus(1).plus(task.attempt.minus(1).multiply(8))+' GB' }
   time { task.attempt == 3 ? '48h' : params.hc_timeout }
   errorStrategy { task.exitStatus in ([1]+(134..140).collect()) ? 'retry' : 'terminate' }
   maxRetries 2

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

//   module 'GATK/4.1.8.1-Java-1.8'

   input:
   tuple val(sample_id), path(bam), path(bai), path("${sample_id}_coverage.tsv"), val(librarytype) from filtered_bams.join(ploidy_estimates, by: 0, failOnDuplicate: true, failOnMismatch: true).join(metadata, by: 0, failOnDuplicate: true, failOnMismatch: true)
   each path(intervals) from ref_scatteredHC
   path ref
   path ref_dict
   path ref_fai

   output:
   tuple val(sample_id), file("${sample_id}_${ref_chunk}.g.vcf.gz") into hc_scattered_gvcfs
   tuple val(sample_id), file("${sample_id}_${ref_chunk}.g.vcf.gz.tbi") into hc_scattered_indices
   tuple file("${sample_id}_${ref_chunk}_haplotypecaller.stderr"), file("${sample_id}_${ref_chunk}_haplotypecaller.stdout") into hc_logs

   shell:
   hc_retry_mem = params.hc_mem.plus(task.attempt.minus(1).multiply(8))
   ref_chunk = (intervals.getSimpleName() =~ params.ref_chunk_regex)[0][1]
   '''
   pcrfree="CONSERVATIVE"
   shopt -s nocasematch
   if [[ "!{librarytype}" =~ "free" ]]; then
      pcrfree="NONE"
   fi
   ploidy=$(!{projectDir}/estimate_chrom_ploidy.awk -v "autosomes=!{params.autosomes}" -v "sexchroms=!{params.sexchroms}" !{sample_id}_coverage.tsv !{intervals})
   module load !{params.mod_gatk4}
   gatk --java-options "-Xms!{hc_retry_mem}g -Xmx!{hc_retry_mem}g" HaplotypeCaller -R !{ref} -I !{bam} -L !{intervals} -ERC GVCF --native-pair-hmm-threads !{task.cpus} -ploidy ${ploidy} --pcr-indel-model ${pcrfree} -O !{sample_id}_!{ref_chunk}.g.vcf.gz 2> !{sample_id}_!{ref_chunk}_haplotypecaller.stderr > !{sample_id}_!{ref_chunk}_haplotypecaller.stdout
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
   publishDir path: "${params.output_dir}/gVCFs", mode: 'copy', pattern: '*.g.vcf.g{z,z.tbi}'

//   module 'picard/2.24.0'
//   module 'GATK/4.1.8.1-Java-1.8'

   input:
   tuple val(sample_id), file(gvcfs) from hc_scattered_gvcfs.groupTuple(by: 0, size: num_scatteredHC)
   tuple val(idx_sample_id), file("${sample_id}_*.g.vcf.gz.tbi") from hc_scattered_indices.groupTuple(by: 0, size: num_scatteredHC)
   file ref
   file ref_dict
   file ref_fai

   output:
//   tuple file("${sample_id}_mergevcfs.stderr"), file("${sample_id}_mergevcfs.stdout"), file("${sample_id}_IFF.stderr"), file("${sample_id}_IFF.stdout") into gvcf_merge_logs
   tuple file("${sample_id}_mergevcfs.stderr"), file("${sample_id}_mergevcfs.stdout") into gvcf_merge_logs
   tuple val(sample_id), file("${sample_id}.g.vcf.gz"), file("${sample_id}.g.vcf.gz.tbi") into hc_final_gvcfs

   shell:
   gvcf_merge_retry_mem = params.gvcf_merge_mem.plus(task.attempt.minus(1).multiply(4))
   gvcf_list = gvcfs
      .collect { gvcf -> "I=${gvcf} " }
      .join()
   '''
   module load !{params.mod_picard}
   java -Xmx!{gvcf_merge_retry_mem}g -Xms!{gvcf_merge_retry_mem}g -jar ${PICARD} MergeVcfs SEQUENCE_DICTIONARY=!{ref_dict} !{gvcf_list} O=!{sample_id}.g.vcf.gz 2> !{sample_id}_mergevcfs.stderr > !{sample_id}_mergevcfs.stdout
   '''
//   gatk IndexFeatureFile -F !{sample_id}.g.vcf.gz 2> !{sample_id}_IFF.stderr > !{sample_id}_IFF.stdout
}

process validate_gvcf {
   tag "${sample_id}"

   cpus params.gvcf_check_cpus
   memory { params.gvcf_check_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 2 ? '48h' : params.gvcf_check_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

//   module 'GATK/4.1.8.1-Java-1.8'

   input:
   tuple val(sample_id), file("${sample_id}.g.vcf.gz"), file("${sample_id}.g.vcf.gz.tbi") from hc_final_gvcfs
   file('*.bed') from ref_scatteredHC_check.collect()
   file ref
   file ref_dict
   file ref_fai
   file known_dbsnp
   file known_dbsnp_idx

   output:
   tuple file("${sample_id}_GATK_ValidateVariants.stderr"), file("${sample_id}_GATK_ValidateVariants.stdout") into validate_gvcf_logs   

   shell:
   '''
   module load !{params.mod_gatk4}
   regions_string=$(ls *.bed | sort -k1,1V | awk '{print "-L", $1, "";}')
   gatk --java-options "-Xms!{params.gvcf_check_mem}g -Xmx!{params.gvcf_check_mem}g" ValidateVariants -V !{sample_id}.g.vcf.gz -R !{ref} ${regions_string} -gvcf --validation-type-to-exclude ALLELES --dbsnp !{known_dbsnp} 2> !{sample_id}_GATK_ValidateVariants.stderr > !{sample_id}_GATK_ValidateVariants.stdout
   '''
}
