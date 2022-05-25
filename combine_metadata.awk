#!/bin/awk -f
#This script serves to merge the contents of the metadata files for each component dataset,
# as they encode overlapping but not identical sets of information, and sometimes differ in
# the encoding.  For instance, the column names may differ slightly, or the encoding of
# reported sex may differ.
#Pass in as many input metadata files as you wish to combine.
BEGIN{
   FS="\t";
   OFS=FS;
   filenum=0;
   if (length(subcol) > 0 && length(subsize) > 0 && subsize > 0) {
      print "Subsampling "subsize" from each file by column "subcol > "/dev/stderr";
   };
   #Output the metadata file header:
   print "Sample", "Sex", "Region", "Population", "LibraryType";
}
FNR==1{
   #Keep track of which input file we're on:
   filenum++;
   #Keep track of the column names in the input metadata files:
   delete cols;
   for (i=1; i<=NF; i++) {
      cols[$i]=i;
   };
   if (length(subcol) > 0 && !(subcol in cols)) {
      print "Could not find column "subcol" in input file "filenum" ("FILENAME")" > "/dev/stderr";
      exit 2;
   };
}
FNR>1{
   id=$cols["Sample"];
   #Though different concepts, we consolidate "Gender" and "Sex" columns into the same, and
   # encode as uppercase "M" or "F" rather than "male" and "female" or other variations:
   #Note: This column is actually ignored by the re-calling pipeline.
   sex="Gender" in cols ? toupper(substr($cols["Gender"], 1, 1)) : $cols["Sex"];
   #I sometimes use "Population" and "Subpopulation" to mean the same as HGDP calls "Region"
   # and "Population", so this just unifies those two naming schemes under the HGDP scheme:
   region="Region" in cols ? $cols["Region"] : $cols["Population"];
   pop="Region" in cols ? $cols["Population"] : $cols["Subpopulation"];
   libtype=$cols["LibraryType"];
   if (length(subcol) == 0 || length(subsize) == 0 || subsize == 0) {
      print id, sex, region, pop, libtype;
   } else {
      if (c[filenum,$cols[subcol]] < subsize) {
         c[filenum,$cols[subcol]]++;
         print id, sex, region, pop, libtype;
      };
   };
}
