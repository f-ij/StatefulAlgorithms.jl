#!/bin/zsh
# Interleaved: for each round, one fresh process per snapshot. Restores src to HEAD at the end.
cd /Users/fabianijpelaar/dev/StatefulAlgorithms.jl-perf
E=$1; TMPF=$2; OUT=perf/snapshots/results_raw.tsv; : > $OUT
for round in 1 2 3; do
  for snap in "main:5cccbef" "inference-fix:6bf58b0" "route-fix:f1eaeb6"; do
    label=${snap%%:*}; commit=${snap##*:}
    git checkout -q $commit -- src
    julia --project=$E perf/snapshots/measure.jl $label $round > $TMPF 2>&1
    grep -E "^ROW|^NAMES" $TMPF >> $OUT
    echo "INTERNALERR\t$label\t$round\t$(grep -c 'Internal error' $TMPF)" >> $OUT
  done
done
git checkout -q HEAD -- src; rm -f $TMPF
echo DONE
