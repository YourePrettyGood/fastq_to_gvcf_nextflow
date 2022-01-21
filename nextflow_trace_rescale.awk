#!/bin/awk -f
#
BEGIN{
   FS="\t";
   OFS=FS;
   #col is the name of the variable we want to rescale:
   if (length(col) == 0) {
      print "No col variable defined, please specify the name of the column you want to rescale" > "/dev/stderr";
      exit 2;
   };
   #If we specify two columns separated by an operator (+,-), split them,
   # store both, indicate a compound column, and store the operator:
   n_col=split(col, querycols, /[+-]/, compoundop);
   if (n_col > 1) {
      compoundcol=1;
   };
   #scaling is a division-based scaling factor for the average, min, and max that helps
   # adjust the output units:
   #For instance, you could use a scaling factor of 1000000 for peak_rss to display
   # average peak memory usage in MB rather than bytes (which is the default).
   if (units ~ /^(d|days|h|hrs|hours|m|mins|minutes|s|secs|seconds|GB|GiB|MB|MiB|KB|KiB)$/) {
      if (units ~ /^(d|days)$/) {
         scaling=1000*60*60*24;
      } else if (units ~ /^(h|hrs|hours)$/) {
         scaling=1000*60*60;
      } else if (units ~ /^(m|mins|minutes)$/) {
         scaling=1000*60;
      } else if (units ~ /^(s|secs|seconds)$/) {
         scaling=1000;
      } else if (units == "GB") {
         scaling=1000*1000*1000;
      } else if (units == "MB") {
         scaling=1000*1000;
      } else if (units == "KB") {
         scaling=1000;
      } else if (units == "GiB") {
         scaling=1024*1024*1024;
      } else if (units == "MiB") {
         scaling=1024*1024;
      } else if (units == "KiB") {
         scaling=1024;
      };
   };
   if (length(scaling) == 0) {
      print "No scaling factor defined, using default of 1" > "/dev/stderr";
      scaling=1;
   };
   #Print the header line:
   if (length(coefcol) > 0) {
      if (length(debug) > 0) {
         print "Process", "WeightedValue", "UnweightedValue", "Scale";
      } else {
         print "Process", "WeightedValue";
      };
   } else if (length(debug) > 0) {
      print "Process", "Value", "Scale";
   } else {
      print "Process", "Value";
   };
}
NR==1{
   #Keep track of the column names:
   for (i=1; i<=NF; i++) {
      cols[$i]=i;
   };
   for (j=1; j<=n_col; j++) {
      if (!(querycols[j] in cols)) {
         print "Unable to find query column "querycol[j]" in trace file, quitting." > "/dev/stderr";
         exit 3;
      };
   };
   if (length(coefcol) > 0 && !(coefcol in cols)) {
      print "Unable to find coefficient column "coefcol" in trace file, quitting." > "/dev/stderr";
      exit 4;
   };
}
NR>1{
   #Keep track of the sum of the desired column, number of instances, min, and max as long as the tasks completed:
   if ($cols["status"] == "COMPLETED" || $cols["status"] == "CACHED") {
      if (compoundcol) {
         if (compoundop[1] == "+") {
            colval=$cols[querycols[1]]+$cols[querycols[2]];
         } else if (compoundop[1] == "-") {
            colval=$cols[querycols[1]]-$cols[querycols[2]];
         };
      } else {
         colval=$cols[col];
      };
      colvals[$cols["name"]]=colval;
      if (length(coefcol) > 0) {
         weightedcolval=$cols[coefcol]*colval;
         weightedcolvals[$cols["name"]]=weightedcolval;
      };
   };
}
END{
   #Iterate over the processes in a predictable order:
   PROCINFO["sorted_in"]="@ind_str_asc";
   for (n in colvals) {
      if (length(coefcol) > 0) {
         if (length(debug) > 0) {
            print n, weightedcolvals[n]/scaling, colvals[n]/scaling, scaling;
         } else {
            print n, weightedcolvals[n]/scaling;
         };
      } else if (length(debug) > 0) {
         print n, colvals[n]/scaling, scaling;
      } else {
         print n, colvals[n]/scaling;
      };
   };
}
