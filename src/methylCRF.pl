#!/usr/bin/env perl
#------------------------------------------------------------------------#
# Copyright 2012                                                         #
# Author: stevens _at_ cse.wustl.edu                                     #
#                                                                        #
# This program is free software: you can redistribute it and/or modify   #
# it under the terms of the GNU General Public License as published by   #
# the Free Software Foundation, either version 3 of the License, or      #
# (at your option) any later version.                                    #
#                                                                        #
# This program is distributed in the hope that it will be useful,        #
# but WITHOUT ANY WARRANTY; without even the implied warranty of         #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the          #
# GNU General Public License for more details.                           #
#                                                                        #
# You should have received a copy of the GNU General Public License      #
# along with this program.  If not, see <http://www.gnu.org/licenses/>.  #
#------------------------------------------------------------------------#

use strict;
use FindBin qw($Bin);
FindBin::again(); 

# NOTES #
# should have used BS midpt for training too, so I could avoid caring here
#########

# hiested from http://www.perlmonks.org/bare/?node_id=178170
# NOTE: IO::FILE allows handling fh's in either OO-mode or procedural
#        --maybe switch to filehandle --it's on the system, so maybe it's std
package IO::File::AutoChomp;
use base 'IO::File';
sub getline  { my $v = readline($_[0]) || die "readline failed: [$_[0]] ($!)";chomp $v;return $v}
sub getlines { my ($self) = @_; return map { chomp; $_ } $self->SUPER::getlines(); }



package main;
# uts
my $crfbin     = "$Bin/crfasgd";
my $medip_norm = "$Bin/medip_norm.sh";
my $bed2bin    = "$Bin/bed2avgwinbin.sh";
my $dir2frag   = "$Bin/dir2frag.sh";

my @windist = (0,10,100,1000,10000);

# optional arguments
my %c = (
 -mdir  => 'mdl',  # model dir: has one model file per crf
 -gdat  => 'gdat', # global species specific data: xxx_cpg.bin for each crf, cpg.bed, gdat.tbl
 -gap   => '750',  # size of gap
 -eid   => 'eid',  # prefix for output files

 -cpgfn => '',     # bed file of cpgs to use [dflt: gdat/cpg.bed]
 -crffn => '',     # crf list [dflt: mdir/crf.list]
 -cutfn => '',     # cut list for bining [dflt: mdir/cut.list]
 -gtbl =>  '',     # global data table [dflt:gdat/gdata.tbl]

 # PROCESSING STEPS:
 -sfrom => '0',    # start from step
 -gto   => '5',    # don't go past this step
    # 0 all (format DIP/MRE bed files)
    # 1 DIP/MRE avgwin (25Gb)
    # 1.5 DIP/MRE count files
    # 2 make sampled MRE fragment file
    # 3 make tables  (1.5hr)
    # 3.1 make table for training: no binning or gaps
    #     mCRF.pl xxxxxx   0 3.1
    # 4 predict
    # 5 combine
    # 6 make dirs to put extra files in [have to give explicitely]
);

while ($ARGV[0] =~ /^-/) {
   my $_ = shift @ARGV;
   if (exists $c{$_}) {$c{$_}= shift @ARGV}
   else {$c{$ARGV[0]}++ }
}
$c{-cpgfn}  ||= "$c{-gdat}/cpg.bed";
$c{-crffn}  ||= "$c{-mdir}/crf.list";
$c{-cutfn}  ||= "$c{-mdir}/cut.list";
$c{-gtbl}   ||= "$c{-gdat}/gdata.tbl";



# req arguments
if (@ARGV != 3) { die "USAGE $0 [options] DIP.bed MRE.bed MRE_vdigest.bed"}

my (
  $dipfn,   # MeDIP-seq file
  $mrefn,   # MRE-seq file
  $fragdir, # dir with MRE enzyme frag files -will detect if it's instead a filename and use that
) = @ARGV;


# if dir then derive name [deprecated]
my $fragfn = $fragdir;
if (-d $fragdir) { $fragfn  = $c{-eid}."_".qx(basename $fragdir); chomp $fragfn; }


## sort -k1,1V -k2,2n
qx(sort -k1,1V -k2,2n -k3,3n -o cpg.sort.bed $c{-cpgfn});
qx(sort -k1,1V -k2,2n -k3,3n -o $dipfn $dipfn);
qx(sort -k1,1V -k2,2n -k3,3n -o $mrefn $mrefn);
$c{-cpgfn} = 'cpg.sort.bed';


## 0: Get and Format DIP/MRE data ##

# make correct bed files from handler output (dipfn.bed,mrefn.bed)
if ($c{-sfrom} <=0 && $c{-gto} >= 0) {
  print STDERR scalar localtime(), " format $dipfn and $mrefn\n";
  format_DIPMRE($dipfn,$mrefn,$c{-cpgfn}) 
}

## 1: generate windowed files ({e}_DIP_d{d}.cnt, {e}_MRE_d{d}.cnt)
my $win="0 10 100 1000 10000";
if ($c{-sfrom} <=1 && $c{-gto} >= 1) {
  print STDERR scalar localtime(), " make avg windows for $dipfn and $mrefn\n";
  gen_avgwindows($c{-eid},"$dipfn.norm.bed",$mrefn,$c{-cpgfn},$win ) ;
}
if ($c{-sfrom} <=1.5 && $c{-gto} >= 1.5) {
  print STDERR scalar localtime(), " making DIPMRE.cnt for $dipfn and $mrefn\n";
  make_DIPMRE_cnt($c{-eid}, $win) ;
}

## 2: make MRE frag file
if ($fragdir ne $fragfn && $c{-sfrom} <=2 && $c{-gto}>=2 ) {
  print STDERR scalar localtime(), " make MRE frag in $fragdir\n";
  make_fragfn($fragdir,$c{-cpgfn},"$fragfn.bin");
}
 


## stuff needed for steps (3,4,5) ##

# crf list
my @crf = map {chomp;$_} qx(cat $c{-crffn}|grep -v "^#"); 

# genomic cpg.bed (step 2,3,4)
my $CPG = IO::File::AutoChomp->new($c{-cpgfn},'r') or die "can't open $c{-cpgfn}: $!";

# files have cpgid [0|1] -telling weather CpG is in crf (this is a bad idea, i need to redo it)
# step (2,4)
my @CLS =map { 
    my $fn = "$c{-gdat}/${_}_cpg.bin";
    IO::File::AutoChomp->new($fn, 'r') or die "can't open $fn: $!";
  } @crf;

# CRF table fn's (step 2,3,4)
my @tblfn = map{"$c{-eid}_${_}.tbl"} (@crf);

# get cut list hash (step 2,4[midpt])
my (%cut,$id);
for (qx(cat $c{-cutfn})) {
  chomp;
  if (/[a-zA-Z]/) { $id=$_                 }
  else            { push @{$cut{$id}},$_+0 }
}



## 2: Make Tables ##
if ($c{-sfrom} <=3 && $c{-gto}>=3) {
  print STDERR scalar localtime(), " make table\n";
  # get common filehandles
  my $EFN  = IO::File::AutoChomp->new("$c{-eid}_DIPMRE.cnt", 'r') or die "can't open $c{-eid}_DIPMRE.cnt $_: $!";
  my $FRAG = IO::File::AutoChomp->new($fragfn,'r') or die "can't open $fragfn: $!";
  my $GDAT = IO::File::AutoChomp->new($c{-gtbl},'r') or die "can't open $c{-gtbl}: $!";
  my @gdat_hdr = split /\t/,$GDAT->getline();

  # per CRF fh's (these should close as they go out of scope)
  my @OUT = map { IO::File->new($_, 'w') or die "can't open $_: $!"; } @tblfn ;

  my (@pchr,@plocn);
  # assume CPG is a subset of EFN,FRAG,GDAT and all ftr_cpg.bins (cpgid [0,1]), 
  #     but that cid orders are consistent
  while (my @cpg = split /\t/, <$CPG>) {
    my $cid= $cpg[3];

    my (@dipmre,@frag,@gdat);
    while (1) {
      @dipmre = (split /\t/,  $EFN->getline());chomp $dipmre[-1];
      @frag   = (split /\t/, $FRAG->getline());chomp $frag[-1];
      @gdat   = (split /\t/, $GDAT->getline()); chomp $gdat[-1];
      if ($dipmre[0] eq $cid) {
       die "at cpg: $cid ($dipmre[0] != $frag[0] != $gdat[0])" if grep {$_ ne $dipmre[0]} ($frag[0],$gdat[0]);
       last;
      }
    }

    # each crf
    for my $cidx (0..$#crf) {
      # print this cpg or not?
      my @cls;
      while (1) {
        @cls = split /\t/, $CLS[$cidx]->getline();
        last if ($cls[0] eq $cid);
      }
      #if ($cls[0] ne $cid) {die "cls cpg != cpg ".join(" ", @cpg)."  ".join(" ", @cls)}
      if (!$cls[1]) {next}

      # this crf's fh 
      my $OUT   = $OUT[$cidx];
      my $crfnm = $crf[$cidx];

      if ($c{-gto} == 3.1) {
        ## tables for training: no gap or bin

        # MRE and MeDIP cols
        $OUT->print( $dipmre[$_+1],"\t" ) for (0..$#windist);
        $OUT->print( $dipmre[ $_+1+@windist ],"\t" ) for (0..$#windist);
  
        # mre frag 
        #die "no frag at cpg $cpg[3]" unless defined $frag[1];
        $OUT->print( $frag[1], "\t");
  
        # all other cols (no autochomp) 
        $OUT->print( $gdat[$_],"\t" ) for (1..$#gdat_hdr-1);
        $OUT->print( $gdat[-1],"\n" );

      } else { 
        ## tables for running mCRF

        # add newline for gaps
        if ( $pchr[$cidx] && ($pchr[$cidx] ne $cpg[0] || ($cpg[1] -$plocn[$cidx] >$c{-gap})) ) 
        {$OUT->say("");}
  
        # MRE and MeDIP cols
        $OUT->print( ($dipmre[$_+1]           ==-1 ? -1 : binon( $cut{ "${crfnm}__DIP_d$windist[$_]" },$dipmre[1+$_]          )),"\t" ) for (0..$#windist);
        $OUT->print( ($dipmre[ $_+1+@windist ]==-1 ? -1 : binon( $cut{ "${crfnm}__MRE_d$windist[$_]" },$dipmre[1+$_+@windist] )),"\t" ) for (0..$#windist);
  
        # mre frag 
        #die "no frag at cpg $cpg[3]" unless defined $frag[1];
        $OUT->print( $frag[1], "\t");
  
        # all other cols (no autochomp) 
        $OUT->print( ($gdat[$_]==-1 ? -1 : binon( $cut{ "${crfnm}__$gdat_hdr[$_]" },$gdat[$_] )),"\t" ) for (1..$#gdat_hdr-1);
        $OUT->print( ($gdat[-1]==-1 ? -1 : binon( $cut{ "${crfnm}__$gdat_hdr[-1]" },$gdat[-1] )),"\n" );
      }

      ($pchr[$cidx],$plocn[$cidx]) = ($cpg[0],$cpg[2])
    }
  }
  # add empty last line (maybe didn't work..)
    for (@OUT) { $_->say("");$_->close}
    
  for (@tblfn){ qx((echo $_;tail -n -2 $_|awk '{print NF}') >&2) }
}


## 3: Predict ##
if ($c{-sfrom} <= 4 && $c{-gto}>=4) {
  print STDERR scalar localtime(), " predict\n";
  predict($crfbin,\@tblfn,\@crf,$c{-mdir}, $c{-eid}) 
}
  

## 4: Combine ##
if ($c{-sfrom}<= 5 && $c{-gto}>=5) {
# midpt map
  my $midpt = midpt_map(\@crf,\%cut,1);

  # reset fh posn
  $CPG->seek(0,0);
  for (@CLS) { $_->seek(0,0)}

#prints to stdout
  print STDERR scalar localtime(), " making ensemble prediction\n";
  combine(\@CLS,\@tblfn,$midpt, $CPG);
  print STDERR scalar localtime(), " fin\n";

}

if ($c{-sfrom} == 6) {
  my $d="$c{-eid}_err";qx(mkdir $d; mv $c{-eid}*err $d/);
  $d="$c{-eid}_tbl";qx(mkdir $d; mv $c{-eid}*tbl $d/);
  $d="$c{-eid}_out";qx(mkdir $d; mv $c{-eid}*out $d/);
  $d="$c{-eid}_cnt";qx(mkdir $d; mv $c{-eid}*cnt $d/);
#  $d="$c{-eid}_bed";qx(mkdir $d; mv $c{-eid}*bed_cpg.bed *read.bed *norm.bed *extended.bed *bedGraph $d/);
}



sub format_DIPMRE {
  my ($dfn,$mfn,$cfn) = @_;
# do medip norm
  qx($medip_norm $dfn $cfn >$dfn.norm.bed ) and $? and die "$0: medip_norm ".($? >> 8);

 qx(ls -l $dfn $mfn $dfn.norm.bed >&2);
}

sub gen_avgwindows {
  my ($e,$dfn,$mfn,$cfn,$win) = @_;
  print qx($bed2bin $dfn $cfn "$win" ${e}_DIP) and $? and die "$0: bed2avgwingin(DIP) ".($? >> 8);
  print qx($bed2bin $mfn $cfn "$win" ${e}_MRE) and $? and die "$0: bed2avgwingin(MRE) ".($? >> 8);

  qx(for i in $win; do for a in DIP MRE; do wc ${e}_\${a}_d\${i}.cnt; done;done >&2);

  my $id = join " ", map{"<\(cut -f1 ${e}_DIP_d${_}.cnt)"} (split /\W/,$win)[0];
  my $dip = join " ", map{"<\(cut -f2 ${e}_DIP_d${_}.cnt)"} (split /\W/,$win);
  my $mre = join " ", map{"<\(cut -f2 ${e}_MRE_d${_}.cnt)"} (split /\W/,$win);
  my $out = "${e}_DIPMRE.cnt"; 
  system("bash","-c", "paste $id $dip $mre >$out 2>&1 ") and $? and die "$0: gen_avgwin(paste) ".($? >> 8);

  qx((echo $out "column numbers";awk '{print NF}' $out |sort -u) >&2);
  # del cnt files??
}
sub make_DIPMRE_cnt {
  my ($e,$win) = @_;

  my @win = (split /\W/,$win);
  my $id  = join " ", map{"<\(cut -f1 ${e}_DIP_d${_}.cnt)"} $win[0];
  my $dip = join " ", map{"<\(cut -f2 ${e}_DIP_d${_}.cnt)"} @win;
  my $mre = join " ", map{"<\(cut -f2 ${e}_MRE_d${_}.cnt)"} @win;
  my $out = "${e}_DIPMRE.cnt"; 
  system("bash","-c", "paste $id $dip $mre >$out 2>&1 ") and $? and die "$0: DIPMRE(paste) ".($? >> 8);

  qx((echo $out "column numbers";awk '{print NF}' $out |sort -u) >&2);
  # del cnt files??
}

sub make_fragfn {
  my ($dir,$cpg,$outfn) = @_;
  qx($dir2frag $dir $cpg >$outfn ) and $? and die "$0: medip_norm ".($? >> 8);
  qx(ls -l $outfn >&2;)
}
sub predict {
  my ($bin, $tfn,$crf,$mdldir,$e) = @_;
  for (0..$#$tfn) {
    my $mdl="$mdldir/$crf->[$_].mdl";
    my $mname=qx(basename $mdldir);chomp $mname;
    my $out="$tfn->[$_]_$mname.out";
    qx(stat $mdl $tfn->[$_]) and $? and die "$0:  ".($? >> 8); 
    print STDERR "predict: [$crf->[$_]] [$mdl]\n";
    qx( ($bin -t $mdl $tfn->[$_] |awk '(NF){print \$NF}') >$out ) and $? and die "$0: qx(($bin -t $mdl $tfn->[$_] |awk '(NF){print \$NF}')>$out) ".($? >> 8);

    qx(ls -l $out >&2);
}
}
sub combine {
  my ($CLS,$tblfn,$midmap,$CPG) = @_;

# prediction fh's
  my @pred= map { 
  my $mname=qx(basename $c{-mdir});chomp $mname;
  IO::File::AutoChomp->new("${_}_$mname.out", 'r') or die "can't open ${_}_$mname.out: $!";
  } @$tblfn;

  # assume cpg.bin is a subset of all ftr_cpg.bin  (cpgid [0,1]) and all cid orders are consistent
  while (my @l = split /\t/, <$CPG>) {
    my $cid=$l[3];
    $#l=4; # remove anything after score

    my ($v,$c);
    for my $cidx (0..$#$tblfn) {
      my @cls;
      while (1) {
        @cls = split /\t/, $CLS[$cidx]->getline();
        last if ($cls[0] eq $cid);
      }
      if (!$cls[1]) {next};

      if (defined (my $p = $pred[$cidx]->getline() )){
        $v += $midmap->[$cidx]{ $p+0 };$c++;
      } else {die "$tblfn->[$cidx] has no val for $cid!"}
    }
    die "@l has no predictions!" if !$c;
    $l[4] = sprintf "%.2f", $v/$c;
    print join("\t",@l),"\n";
  }

# sanity check all pred's are eof 
  for (@$CLS) { die "$_ not finished" if !$_->eof()}
}


sub binon {
  my ($cut,$v) = @_;
  #NOTE: v can be < cut[0] if binning was done on small samples
  my $idx=1; while ($idx <= $#$cut && $v >= $cut->[$idx]) {$idx++}
  return  $cut->[$idx-1];
}


sub midpt_map{
  my ($crf, $cut, $max) = @_;
  my @rtn;
  for my $cidx (0..$#$crf) {
    my $k=$crf->[$cidx]."__BS";
    for ( 0 .. $#{$cut->{$k}}-1 ) {
      my $v = $cut->{$k}[$_]; 
      $rtn[$cidx]{$v} = ( $v + $cut->{$k}[$_+1] )/2;
    }
    $rtn[$cidx]{ $cut->{$k}[-1] } =  ( $cut->{$k}[-1] + $max )/2;
  }
  return \@rtn;
}

# Not really sure the best way to do this:
# 1) loop through crfs w/ cpg's inside
# 2) loop through cpg w/ crf's inside
sub make_crf_old {
  my ($CPG,$CLASS,$gapsz,$crfnm,$windist,$cut,$EFN,$FRAG,$GDAT,$gdat_hdr,$OUT) = @_;
  # local $| = 1;

  my $c;
  my ($pchr,$plocn);
  while (my @cpg = split /\t/, <$CPG>) {
    $c++;

    my $dipmre = $EFN->getline();
    my $frag   = $FRAG->getline();
    my $gdat   = $GDAT->getline();

    # print this cpg or not?
    my @cls = (split /\t/,$CLASS->getline());
    if ($cls[0] ne $cpg[3]) {die "cls cpg != cpg ".join(" ", @cpg)."  ".join(" ", @cls)}
    if (!$cls[1]){next}

    # add newline for gaps
    if ( $pchr && ($pchr ne $cpg[0] || ($cpg[1] -$plocn >$gapsz)) ) 
    {$OUT->say("");}

    # MRE and MeDIP cols
    my @dipmre = split /\t/, $dipmre;chomp $dipmre;
    $OUT->print( ($dipmre[$_]           ==-1 ? -1 : binon( $cut->{ "${crfnm}__H1ES_DIP_d$windist[$_]" },$dipmre[$_]          )),"\t" ) for (0..$#windist);
    $OUT->print( ($dipmre[ $_+@windist ]==-1 ? -1 : binon( $cut->{ "${crfnm}__H1ES_MRE_d$windist[$_]" },$dipmre[$_+@windist] )),"\t" ) for (0..$#windist);

    # mre frag 
    $OUT->print( (split /\t/, $frag)[1], "\t");

    # all other cols (no autochomp) 
    my @gdat = split /\t/,$gdat;
    $OUT->print( ($gdat[$_]==-1 ? -1 : binon( $cut->{ "${crfnm}__$gdat_hdr->[$_]" },$gdat[$_] )),"\t" ) for (1..$#$gdat_hdr-1);
    $OUT->print( ($gdat[-1]==-1 ? -1 : binon( $cut->{ "${crfnm}__$gdat_hdr->[-1]" },$gdat[-1] )),"\n" );

    ($pchr,$plocn) = ($cpg[0],$cpg[2]);
  }
  # add empty last line
  $OUT->say("");
}


