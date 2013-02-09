#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Term::ReadKey;

my $opts = { sleep => 10, pagesize => 4096 };

GetOptions ($opts, 'sleep=i','pagesize=i') or die "Couldn't process command line switches";


open(PAGESIZE,"-|","getconf","PAGESIZE") or die "Couldn't run getconf pagesize! ($!)";
my $pagesize = <PAGESIZE>;
chomp $pagesize;
close PAGESIZE;

my ($wchar, $hchar) = GetTerminalSize();
my $counter = $hchar;

while (1) {
  sleep $opts->{sleep};
  next unless slurp("/sys/kernel/mm/ksm/run");
if ($counter-- == 1) { print "header\n";$counter = $hchar-1}
    my $shared = slurp("/sys/kernel/mm/ksm/pages_shared") * $opts->{pagesize} ;
    my $sharing = slurp("/sys/kernel/mm/ksm/pages_sharing") * $opts->{pagesize} ;
    my $unshared = slurp("/sys/kernel/mm/ksm/pages_unshared") * $opts->{pagesize} ;



    printf("%d%%\t%d%%\t%dMb\t%dMb\n",
    $sharing/$shared,$unshared / $sharing, $shared/1024^3, $sharing/1024^3);

}

sub slurp {
  open(FILE,"<",$_[0]) or die "Couldn't open $_[0] for reading!";
  $_ = <FILE>;
  chomp; return $_;
}
#
#pages_shared
#pages_sharing
#pages_unshared
#pages_volatile
#
#echo "KSM pages shared: $(( $(cat /sys/kernel/mm/ksm/pages_sharing) * $(getconf PAGESIZE) / 1024 / 1024 ))Mb"
#KSM pages shared: 2525Mb
#
