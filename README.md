# methylCRF 1.2

Because of bedtools requirement, please make sure all the bed files used for the tool has been sorted using `sort -k1,1V -k2,2n`

## 1.2 update:
* sort bedfiles before mapBed

## 1.1 update: 
* Replace olapBed with mapBed in bedtools
* Fix a compiling error of crfasgd on mac 

## about this tool:
* Estimate genome wide methylation level at each CpG sites using MeDIP-seq and MRE-seq data. Please read [methylcrf website](methylcrf.wustl.edu) for more information.
* Publication: [Stevens_GenomeResearch2013](http://genome.cshlp.org/content/23/9/1541.abstract)

## How to install:

* step1: install bedtools.
* step2: make

Enjoy!
