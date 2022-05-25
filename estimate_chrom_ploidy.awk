#!/bin/awk -f
#This script basically outputs the expected ploidy of the intervals provided in the second file.
#Autosomal intervals are always output as ploidy 2, and for now we constrain sex chromosome ploidy to max 2.
#Unplaced scaffolds get ploidy 2.
#The thresholds for different ploidy levels are hard-coded for now based on existing samples.
#Expected inputs:
#autosomes: Comma-separated list of autosome names
#sexchroms: Comma-separated list of sex chromosome names
#Expected files for inputs:
#1) *_coverage.tsv (output of samtools coverage)
#2) *.bed (BED of intervals to be called)
BEGIN{
   FS="\t";
   OFS=FS;
   n_auto=split(autosomes, a, ",");
   if (n_auto < 1) {
      print "Error: List of autosome names is missing/empty, cannot proceed." > "/dev/stderr";
      exit 6;
   };
   for (i in a) {
      auto[a[i]]=i;
   };
   n_sex=split(sexchroms, s, ",");
   if (n_sex < 1) {
      print "Warning: List of sex chromosome names is missing/empty, all scaffolds will have ploidy 2." > "/dev/stderr";
   };
   for (j in s) {
      sex[s[j]]=j;
   };
   filenum=0;
   #Keep track of if the BED has autosomal intervals, sex chromosome intervals, or both:
   hasauto=0;
   hassex=0;
}
#Keep track of which input file we're on:
FNR==1{
   filenum++;
}
#Parse the results of samtools coverage:
#Input file #1: *_coverage.tsv
filenum==1&&FNR==1{
   for (i=1; i<=NF; i++) {
      covcols[$i]=i;
   };
}
filenum==1&&FNR>1{
   scaf_len=$covcols["endpos"]-$covcols["startpos"]+1;
   #Keep track of the numerator and denominator for total depth of the autosomes and each sex chromosome:
   if ($covcols["#rname"] in auto) {
      dxb_auto+=$covcols["meandepth"]*scaf_len;
      b_auto+=scaf_len;
   } else if ($covcols["#rname"] in sex) {
      dxb_sex[$covcols["#rname"]]=$covcols["meandepth"]*scaf_len;
      b_sex[$covcols["#rname"]]=scaf_len;
   };
}
#Input file #2: *.bed
filenum==2{
   if ($1 in auto) {
      hasauto=1;
   } else if ($1 in sex) {
      hassex=1;
      if (sexchrom != "" && sexchrom != $1) {
         hassex+=1;
      } else {
         sexchrom=$1;
      };
   };
}
END{
   #Quick error check for divide by zero:
   if (b_auto == 0 || dxb_auto == 0) {
      print "2";
      print "Error: Autosomal depth or size in input coverage file is zero, cannot proceed." > "/dev/stderr";
      exit 4;
   };
   #We assume all autosomes and unplaced scaffolds are ploidy 2, and only actually estimate ploidy for the sex chromosomes:
   if (hassex == 0) {
      print "2";
   } else if (hassex == 1 && hasauto == 0) {
      #Error check for divide by zero:
      if (b_sex[sexchrom] == 0) {
         print "2";
         print "Error: Sex chromosome "sexchrom" size in input coverage file is zero, cannot proceed." > "/dev/stderr";
         exit 5;
      };
      sex_auto_ratio=(dxb_sex[sexchrom]/b_sex[sexchrom])/(dxb_auto/b_auto);
      if (sex_auto_ratio < 0.15) {
         print "1";
         print "Warning: Sex chromosome "sexchrom" likely has ploidy 0, but we're outputting ploidy 1 for GATK." > "/dev/stderr";
      } else if (sex_auto_ratio < 0.75) {
         print "1";
      } else if (sex_auto_ratio < 1.15) {
         print "2";
      } else {
         print "2";
         print "Warning: Sex chromosome "sexchrom" likely has ploidy >2, but we're outputting ploidy 2." > "/dev/stderr";
      };
   } else if (hassex > 1 && hasauto == 0) {
      print "2";
      print "Error: The interval BED provided is a mixture of different sex chromosomes." > "/dev/stderr";
      exit 3;
   } else {
      print "2";
      print "Error: The interval BED provided is a mixture of autosomal and sex chromosomes." > "/dev/stderr";
      exit 2;
   };
}
