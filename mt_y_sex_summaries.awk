#!/bin/awk -f
#Expected inputs:
#id:  Sample ID to feed through
#AlX: X-like autosome for depth normalization (default: 7)
#AlY: Y-like autosome for depth normalization (default: 19)
#Note: These Al* variables are based on length-matching.
#Expected files for inputs:
#1) [sample ID]_haplogrep.tsv
#2) [sample ID]_Yhaplogroup.txt
#3) [sample ID]_coverage.tsv
BEGIN{
   FS="\t";
   OFS=FS;
   #Check for the input variables, or set defaults if needed:
   if (length(id) == 0) {
      print "id variable missing, please set it" > "/dev/stderr";
      exit 2;
   };
   if (length(AlX) == 0) {
      AlX="7";
   };
   if (length(AlY) == 0) {
      AlY="19";
   };
   filenum=0;
}
#Keep track of which input file we're on:
FNR==1{
   filenum++;
}
#Parse the results of haplogrep:
#Input file #1: [sample ID]_haplogrep.tsv
filenum==1&&FNR==1{
   for (i=1; i<=NF; i++) {
      mtcols[$i]=i;
   };
}
filenum==1&&FNR>1{
   mthg=$mtcols["\"Haplogroup\""];
   gsub(/"/, "", mthg);
   mthgqual=$mtcols["\"Quality\""];
   gsub(/"/, "", mthgqual);
}
#Parse the results of Yleaf:
#Input file #2: [sample ID]_Yhaplogroup.txt
filenum==2&&FNR==1{
   for (i=1; i<=NF; i++) {
      ycols[$i]=i;
   };
}
filenum==2&&FNR>1{
   yhg=$ycols["Hg"];
   yhgqual=$ycols["QC-score"];
}
#Parse the results of samtools coverage:
#Input file #3: [sample ID]_coverage.tsv
filenum==3&&/^#/{
   for (i=1; i<=NF; i++) {
      covcols[$i]=i;
   };
}
#Keep track of the number of reads mapped for R_Y and Serena's classifier,
# and depth for my classifier:
filenum==3&&!/^#/{
   #We may want to filter non-major scaffolds out of this sum in the future:
   nT+=$covcols["numreads"];
#   #This regex matches the autosomes, X, Y, and mtDNA:
#   if ($covcols["#rname"] ~ "^[0-9XYM][0-9T]?$") {
   #This regex matches the autosomes, X, and Y:
   if ($covcols["#rname"] ~ "^[0-9XY][0-9]?$") {
      #Calculate a weighted average so that it's a true genome-wide depth:
      dT+=$covcols["meandepth"]*($covcols["endpos"]-$covcols["startpos"]+1);
      bT+=$covcols["endpos"]-$covcols["startpos"]+1;
      #Also keep track of just autosomal depth:
      if ($covcols["#rname"] ~ "^[0-9][0-9]?$") {
         dA+=$covcols["meandepth"]*($covcols["endpos"]-$covcols["startpos"]+1);
         bA+=$covcols["endpos"]-$covcols["startpos"]+1;
      };
   };
   #Also keep track of mtDNA depth:
   if ($covcols["#rname"] == "MT") {
      dMT+=$covcols["meandepth"];
   };
   if ($covcols["#rname"] == AlX) {
      dAlX=$covcols["meandepth"];
   } else if ($covcols["#rname"] == AlY) {
      dAlY=$covcols["meandepth"];
   #These will need to change if we use anything except b37/hs37d5:
   } else if ($covcols["#rname"] == "X") {
      nX=$covcols["numreads"];
      dX=$covcols["meandepth"];
   } else if ($covcols["#rname"] == "Y") {
      nY=$covcols["numreads"];
      dY=$covcols["meandepth"];
   };
}
END{
   #Pontus Skoglund's R_Y estimator and it's 95% CI:
   RY=nY/(nX+nY);
   CI=1.96*RY*(1-RY)/(nX+nY);
   #Genetic sex classification based on Serena's Y read proportion idea:
   sexST=nY/nT > 0.002 ? "XY" : "XX";
   #Genetic sex classification based on X normalized depth:
   #Note: This is an approximate normalization based on length-matching
   # to an autosome so that a value close to 1 means 2 copies, 0.5 means
   # 1 copy, etc.
   #We can also classify based on Y normalized depth, so these classifiers
   # should also catch aneuploidies.
   sexPFR=dX/dAlX > 0.7 ? "XX" : "X";
   sexPFR=sexPFR""(dY/dAlY > 0.15 ? "Y" : "");
   sexPFRalt=dX/(dA/bA) > 0.7 ? "XX" : "X";
   sexPFRalt=sexPFRalt""(dY/(dA/bA) > 0.15 ? "Y" : "");
   #Genetic sex classification based on Pontus' R_Y:
   sexPS=RY+CI < 0.016 ? "XX" : RY-CI > 0.075 ? "XY" : "ambig";
   #Print the mtDNA haplogroup, Y haplogroup, and the sex classifications:
   print id, mthg, mthgqual, dMT, yhg, yhgqual, dY, sexST, nY/nT, sexPFR, dX/dAlX, dY/dAlY, dA/bA, dT/bT, sexPS, RY-CI, RY, RY+CI, sexPFRalt, dX/(dA/bA), dY/(dA/bA);
}
