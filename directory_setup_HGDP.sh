#!/bin/bash

#Metadata file with the metadata for each sequencing run:
metadata="$1"
#Batch number:
batch="$2"
#Batch size:
n="$3"

#The HGDP metadata file here is one I created for downloading from ENA.
#It consists of columns for the renamed FASTQ's name, the URL to the
# FASTQ (minus the protocol), the file size, and the MD5 checksum.
#However, this script doesn't really care about anything after the
# first column, it only requires that there be a header line to skip.
#The FASTQs are kept as named for download, which is basically just:
# [Sample ID]_[Run #]_[read end].fastq.gz
#In general, the pattern seems to be that there's only 1 run for PCR-free
# libraries, but 12 for PCR libraries.

batchid="HGDP_part${batch}_${n}indivs";
((prevbatch=batch-1));
prevbatchid="HGDP_part${prevbatch}_${n}indivs";
mkdir -p ${batchid}_fastq_to_gvcf/raw_data;
mkdir /home/pfr8/scratch60/${batchid};
sed "s/part${prevbatch}/part${batch}/g" < ${prevbatchid}_fastq_to_gvcf/${prevbatchid}_fastq_to_gvcf.config > ${batchid}_fastq_to_gvcf/${batchid}_fastq_to_gvcf.config;
pushd ${batchid}_fastq_to_gvcf/;
((start=(batch-1)*n+1));
tail -n+2 ${metadata} | \
   cut -f1 | \
   sort -k1,1V | \
   awk -v "i=${start}" -v "n=${n}" 'BEGIN{FS="_";OFS=FS;}{if (length(ids[$1]) == 0) {ids[$1]=++numids;}; if (ids[$1] >= i && ids[$1] < i+n) {print $0;};}' | \
   while read fn;
      do
      if [[ -e "/gpfs/gibbs/pi/tucci/pfr8/HGDP/FASTQs/${fn}" ]]; then
         ln -s /gpfs/gibbs/pi/tucci/pfr8/HGDP/FASTQs/${fn} raw_data/${fn};
      else
         echo "Unable to find ${fn}";
      fi;
   done
popd
