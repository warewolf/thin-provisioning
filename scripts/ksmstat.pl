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
print "Page size = $pagesize\n";

my ($wchar, $hchar) = GetTerminalSize();
print "w = $wchar, h = $hchar\n";
my $counter = $hchar;

my $header = "Speed\tSh%\tWaste\tShared\tCopies\n";
print $header;

while (1) {
  sleep $opts->{sleep};
  next unless slurp("/sys/kernel/mm/ksm/run");
  if ($counter-- == 2) {
    print $header;
    $counter = $hchar-1;
  }

  my $scan_seconds = slurp("/sys/kernel/mm/ksm/sleep_millisecs") / 0.001;
  my $scan_size = slurp("/sys/kernel/mm/ksm/pages_to_scan") * $opts->{pagesize};

  my $scan_per_second = $scan_size / $scan_seconds;

  my $shared = slurp("/sys/kernel/mm/ksm/pages_shared") * $opts->{pagesize} ;
  my $sharing = slurp("/sys/kernel/mm/ksm/pages_sharing") * $opts->{pagesize} ;
  my $unshared = slurp("/sys/kernel/mm/ksm/pages_unshared") * $opts->{pagesize} ;

  #print "shared: $shared, sharing: $sharing, unshared: $unshared\n";

  my $share_percent = $shared == 0 ? 0 : $sharing/$shared / 0.01;
  my $unshared_precent = $sharing == 0 ? 0 : $unshared / $sharing / 0.01;

  printf("%dMb/s\t"."%2.1f%%\t".          "%2.1f%%\t".               "%dMb\t".       "%dMb\n",
  
  $scan_per_second, $share_percent, $unshared_precent, $shared/1024**2, $sharing/1024**2);
      
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
