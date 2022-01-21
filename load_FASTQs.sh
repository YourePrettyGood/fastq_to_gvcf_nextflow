#!/bin/bash

#Metadata file with the metadata for each sequencing run:
metadata="$1"

#The metadata file should have the following columns (whitespace-separated, preferably tab-separated):
# 0|1) Sample ID
# 1|2) Flowcell ID
# 2|3) Lane ID (L###)
# 3|4) read end (R[12])
# 4|5) path to FASTQ
#Any subsequent columns are left unused.
#The FASTQs are renamed into a consistent format:
# [Sample ID]_[Flowcell ID]_[Lane ID]_[read end]_001.fastq.gz
#This is basically the format provided by bcl2fastq2.

mkdir -p raw_data
while read -a fields;
   do
   if [[ -e "${fields[4]}" ]]; then
      ln -s ${fields[4]} raw_data/${fields[0]}_${fields[1]}_${fields[2]}_${fields[3]}_001.fastq.gz;
   else
      echo "Unable to find ${fields[4]}";
   fi
done < ${metadata}

#For HGDP, I did this, changing the value of i to ([batch #]-1)*n+1:
#tail -n+2 /gpfs/gibbs/pi/tucci/pfr8/HGDP/PRJEB6463_FASTQs_wRenames.tsv | \
#   cut -f1 | \
#   sort -k1,1V | \
#   awk -v "i=251" -v "n=50" 'BEGIN{FS="_";OFS=FS;}{if (length(ids[$1]) == 0) {ids[$1]=++numids;}; if (ids[$1] >= i && ids[$1] < i+n) {print $0;};}' | \
#   while read fn;
#      do
#      if [[ -e "/gpfs/gibbs/pi/tucci/pfr8/HGDP/FASTQs/${fn}" ]]; then
#         ln -s /gpfs/gibbs/pi/tucci/pfr8/HGDP/FASTQs/${fn} raw_data/${fn};
#      else
#         echo "Unable to find ${fn}";
#      fi;
#   done
