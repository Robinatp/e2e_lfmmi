# this is to process the hyp.trn of sppd3
import sys

in_f = sys.argv[1]
ignore = sys.argv[2]

for line in open(in_f, encoding="utf-8"):
    line = line.strip().replace(ignore, "")
    print(line) 

