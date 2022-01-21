# FASTQ to gVCF Nextflow pipeline

This repository contains the setup script, Nextflow pipeline script, and the
configuration file for a pipeline going from FASTQs to per-sample gVCFs based
mostly on the GATK Best Practices. I've deviated in certain ways from the
published WDL scripts for GATK4 Best Practices for analysis-ready BAM prep
and germline variant calling, mainly by re-introducing the indel realignment
step recommended in the GATK3 Best Practices, and adding an adapter trimming
step prior to read mapping.

The configuration file has a few profiles set up, mainly to define the module
files for the two clusters I have set up for it (Farnam and Ruddle), but also
a profile for variant calling against the hs37d5 reference. I'll add GRCh38DH
later.

## Dependencies:

1. [Nextflow](https://www.nextflow.io/index.html#GetStarted) to run the pipeline (tested with 21.10.5b5658 and 21.10.3b5655)
1. Java 1.8 (aka Java 8)
1. [AdapterRemoval](https://github.com/MikkelSchubert/adapterremoval) for adapter trimming (tested with commits 5e6f885 and 5bb3b65)
1. [BWA-MEM](https://github.com/lh3/bwa) for read mapping (tested with commit 13b5637, aka 0.7.17-r1198)
1. [SAMtools](https://github.com/samtools/samtools) for BAM processing and QC (tested with commits af811a6 and cc4e1a6)
1. [HTSlib](https://github.com/samtools/htslib) as a dependency of SAMtools
1. [mutserve](https://github.com/seppinho/mutserve) for mtDNA variant calling (tested 2.0.0-rc12)
1. [haplogrep](https://github.com/seppinho/haplogrep-cmd) for mtDNA haplogroup classification (tested 2.4.0)
1. [Yleaf](https://github.com/genid/Yleaf) for Y haplogroup inference (tested commit 7c33ca0)
1. [Picard](https://github.com/broadinstitute/picard) for various steps (tested 2.24.0)
1. [GATK4](https://github.com/broadinstitute/gatk) for various steps (tested 4.1.8.1 with Java 1.8)
1. [GATK3](https://console.cloud.google.com/storage/browser/gatk-software/package-archive/gatk) for indel realignment (tested 3.8-0-ge9d806836 and 3.8-1-0-gf15c1c3ef)
1. [R](https://r-project.org) for some plotting done by Picard and GATK (tested with 3.6.1, not sure if R 4 will work yet)
1. gsalib package for R (`install.packages(c("gsalib"))`) for some of the R scripts used by Picard and GATK

## Setup of reference files:

It's important to set up the reference and associated files appropriately
before starting the pipeline. I haven't put any processes in the pipeline
for this reference prep, as you only ever have to do it once regardless of
how many different working directories and invocations of the pipeline you
do. I could probably write them in with a "when" clause in the future.

For now, we're only working with hs37d5 as reference, which is GRCh37.p4
with a decoy scaffold comprised of numerous other sequences including
Epstein-Barr Virus' genome. For more details on reference composition,
see [this Biostars post](https://www.biostars.org/p/328824/). For the
actual reference FASTA, see [this NCBI FTP directory](https://ftp.ncbi.nlm.nih.gov/1000genomes/ftp/technical/reference/phase2_reference_assembly_sequence/).

In general, the various resources in the GATK resource bundle for b37
also work for hs37d5, since hs37d5 is almost precisely b37+decoy. So
all of the VCFs of 1000 Genomes Project SNPs and indels, Mills lab
gold-standard indels, dbSNP build 138, and the likes intended for b37
are compatible with hs37d5. Those resources are available [here](https://console.cloud.google.com/storage/browser/gatk-legacy-bundles/b37).

Once you have these things downloaded, you'll need to generate a few
different indices. I usually un-gzip the reference FASTA before use,
but that's not strictly necessary nowadays. Anyways, the indices are:

1. FASTA index (.fai) with `samtools faidx hs37d5.fa`
1. FASTA dictionary (.dict) with `java -jar ${PICARD} CreateSequenceDictionary R=hs37d5.fa O=hs37d5.dict`
1. BWA index files with `bwa index hs37d5.fa`

In order to perform scatter-gather parallelization in certain steps,
we need to identify distinct regions of the genome with similar total
size, but without a region boundary being inside known sequence, as
this would likely result in edge effects. Thus, we determine the regions
of the reference that are not masked (i.e. do not contain Ns), break at
Ns, and then compose BED files of these intervals going up to a certain
total size threshold.

`TODO: FILL THIS IN`

For scatter-gather on BAMs, we need to include the entirety of the
reference, but for variant calling we need to exclude the decoy, so
the BED files are slightly different. We can also use a smaller
threshold for variant calling.

For my purposes, I use a 200 Mbp threshold for scatter-gather on BAMs
while including all regions of the assembly (resulting in 16 total
BEDs), and a 100 Mbp threshold for scatter-gather for HaplotypeCaller
while excluding the EBV (NC_007605) and decoy (hs37d5) scaffolds.
(For later combining of gVCFs and joint genotyping, I use a 50 Mbp
threshold while excluding EBV and decoy.)

Once these BEDs have been generated, be sure to create a file of filenames
(FOFN) of the BEDs (preferably in sequential order) to pass into the
pipeline.

## How to run the pipeline

Make sure you have your reference prepared as detailed above. Now
create a directory where you want the logs and output files to go.
You will need to point to this directory in the config file using a
combination of the `params.output_dir` and `params.output_prefix`
variable definitions. Within this "output" directory, create a
`raw_data` subdirectory. load your FASTQs (could be by copying,
but preferably symlinking) into the `raw_data` subdirectory.

I've provided a script `load_FASTQs.sh` that creates the `raw_data`
subdirectory and symlinks FASTQs based on the contents of a metadata
file that is passed into it. The comments at the beginning of the
script describe the expected format of the metadata file, which should
be achievable for sequencing data that you generate. Data downloaded
from public repositories may be missing some of this information, so
at the bottom of `load_FASTQs.sh` I've commented out a one-liner I've
used specifically for the HGDP FASTQs downloaded from ENA.

Once you've loaded your FASTQs, you need to create a config file (or
copy and edit one of the ones provided in this repo) for your
particular batch. Then create your scratch/working directory (I
usually create this on a scratch volume), and start the pipeline:

`/usr/bin/time -v nextflow -C [config file] -bg run [path to this repo]/fastq_to_gvcf.nf -profile [comma-separated list of profiles to use] -w [absolute path to scratch dir] 2> [batch ID]_fastq_to_gvcf_[date].stderr > [batch ID]_fastq_to_gvcf_[date].stdout`

This runs nextflow in the background so you can log out and it will
continue running, and keeps a log primarily in the .stdout file.
The processes will be run in subdirectories of the scratch directory
that are named based on the hash of the process.

(Once the pipeline is done running successfully, be sure to check
the ValidateVariants logs, and then clean up the scratch directory
using `nextflow clean -f [session ID]`, where `[session ID]` is the
string of two words (usually an adjective and a famous person's name)
listed in brackets `[]` at the beginning of the Nextflow log. If you
had to resume the pipeline, also run `nextflow clean -f -before [session ID]`
to clean up the prior failed runs. Don't worry, none of the files in
the output directory are affected!)

### Config files

Note that you may need to modify the config file (specifically, the
read file glob and the regexes) and possibly even the .nf script
depending on the format of your FASTQ filenames and FASTQ headers.
This has to do with being able to detect the files in `raw_data`
(i.e. needing to adjust `params.read_glob`), parse out the run ID
(i.e. adjusting `params.idfcidlaneid_regex`), parse the sample ID
from the run ID (i.e. adjusting `params.id_regex`), identify which
end a read comes from (i.e. `params.mate_sep`), and parse the Illumina
cluster coordinates from the FASTQ header (i.e. `params.optdup_regex`).

I also added a parameter called `params.fix_ena_readname` that adds
a streamed adjustment to the FASTQ headers by replacing space
characters with colons, thereby assuring that the BAM will contain
the full header. This is necessary for the HGDP FASTQs from ENA, as
they take the form `@[spot ID] [tile #]:[X coord]:[Y coord]`, and
BWA-MEM only keeps the token after `@` and before the first space
as the `QNAME` value for the output SAM/BAM, so Picard MarkDuplicates
would fail to parse out the cluster coordinates for optical duplicate
identification.

I provide two example config files, one based on a more typical
filename and FASTQ header format (i.e. Illumina Casava 1.8+ format),
and one that I used for HGDP data.

The config file also defines some other parameters, like the distance
between clusters to consider for optical duplicates (`params.optdupdist`)
which defaults to 2500 (which is meant for ExAmp-based clustering like
that performed on HiSeq 3000/4000/X and NovaSeq).

There's a whole slew of *_cpus, *_mem, and *_timeout parameters that
define the default core, memory, and time allocations for each type
of process. These have been tuned based on a few hundred samples,
and dynamic resource allocations are also set up in case of task
failure (so that the task gets retried with a greater allocation).
If you change the scatter intervals, you may need to re-tune the
allocations for mdirbqsr and hc.

The profiles that are defined in the config file are of two main types:

1. Cluster module and path definitions
2. Reference genome choice and path definitions

So usually you'll want to run the pipeline with two profiles, like
`ruddle,hs37d5`, which defines the module versions for the
dependencies installed on the Ruddle cluster plus the path to
the rCRS FASTA needed by mutserve, and also defines the paths to
the hs37d5 reference genome, associated scatter interval FOFNs,
the b37 GATK bundle VCFs for IR and BQSR, and the hs37d5 positions
file I generated for Yleaf (modified from the GRCh37 positions file).
If you're running on a different cluster or setup, you'll need to
create a new profile, and likely also adjust the reference genome
paths.

## Results/outputs

Currently, the pipeline outputs the following directories:

`logs`: Logs for each major step

`FastQC`: HTML and ZIP files of the reports from FastQC

`stats`: QC results files, including mtDNA haplogroup, Y haplogroup, per-chromosome depth and read count for genetic sex estimation, and various BAM metrics from Picard tools

`BQSR`: Recalibration tables from GATK BQSR

`BQSR_BAMs`: Whole-genome BAM files and indices used as inputs for GATK HaplotypeCaller

`gVCFs`: Whole-genome gVCF files and indices produced at the end of the pipeline

The BQSR BAMs take up some space, but may be useful later for re-processing
(e.g. SV calling, extracting phase-informative reads, etc.), re-calling
special gene regions (e.g. chrX, chrY), or even extra QC.

## Logging and profiling information

Although Nextflow outputs some useful information into the .stdout
log, and a ton of information (some not so useful) into `.nextflow.log`,
something I've found particularly helpful is the profiling information
in the trace file, which the config files provided define as:
`[batch ID]_fastq_to_gvcf_nextflow_trace.txt`
in the output directory. This contains information on CPU usage,
memory usage, wall-time, time from submission to completion (i.e.
including queue time), resource allocations, and more. However,
the file can be overwhelming to parse by eye, so I've provided
two AWK scripts to help:

1. `nextflow_trace_summarize.awk`: Calculates the range and mean (possibly weighted) for a given statistic in the trace, aggregated across completed and/or cached processes of a given type
1. `nextflow_trace_rescale.awk`: Rescales the raw value of a given column in the trace based on a scaling factor or unit, and omits the remaining columns

In particular, both of these scripts require the following arguments:

`col`: Column name to summarize or rescale, can be a sum or difference of two column names
For example, `-v "col=peak_rss"` gets the maximum memory usage (in bytes) or `-v "col=complete-start"` gets the walltime for process execution (in milliseconds)

`scaling` or `units`: Either an arbitrary divisive factor to scale the raw value, or a unit name to use a pre-defined scaling factor
For example, `-v "scaling=1000"` would divide the raw value by 1000, and `-v "units=hrs"` would set `scaling` to 3600000, scaling milliseconds to hours
Currently accepted values for `units` include:

`d|days|h|hrs|hours|m|mins|minutes|s|secs|seconds`
`KB|KiB|MB|MiB|GB|GiB`

If you want to generate a weighted rescaled value, specify `coefcol`,
which is the name of the column to use as a multiplicative coefficient.
I've used this as a simple way to approximate CPU-hours used by a
given process, so something like:

`-v "col=complete-start" -v "units=hrs" -v "coefcol=cpus"`

will simply multiply the allocated number of CPUs by the walltime.

## Extra scripts

`mt_y_sex_summaries.awk` is meant to take three files from the `stats`
and output a single tab-separated line of the sample ID, mtDNA haplogroup
and quality, Y haplogroup and quality, and three different estimators
of genetic sex. The three input files (in order) are:

1. `[sample ID]_haplogrep.tsv`
1. `[sample ID]_Yhaplogroup.txt`
1. `[sample ID]_coverage.tsv`

The script takes one mandatory argument, and two optional arguments.

Mandatory:

`id`: Sample ID to feed through to the output

Optional:

`AlX`: Autosome whose length is similar to the X (default: 7)

`AlY`: Autosome whose length is similar to the Y (default: 19)

These two variables are used for the depth-normalized estimators
of genetic sex, which basically just estimate ploidy of the X and Y.
The output of "XX" vs. "XY" for this particular estimator is
solely based on the ratio of depth on X to AlX, but both normalized
depths are also output, as is the total depth based on the major
chromosomes (1-22, X, Y, and mtDNA, but mtDNA shouldn't affect much).

The other two estimators for genetic sex are:

1. Serena's suggested classifier based on fraction of total reads mapped to the Y
1. Pontus Skoglund's R_Y

The bounds of the 95% confidence interval of R_Y are reported on either
side of the R_Y estimate, but they generally don't differ from the
estimate on full-depth sequencing data.
