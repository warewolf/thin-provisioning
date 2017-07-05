#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s 

use strict;
use warnings;
use Getopt::Long qw(:config pass_through);
use Pod::Usage;
use Sys::Virt;
use Sys::Guestfs;
use Win::Hivex;
use Win::Hivex::Regedit qw(reg_export);
use File::Temp qw( tempfile tempdir);
use Encode qw(from_to);
use List::Util qw(first);
use Fcntl qw(:seek);
use Data::Dumper;

# options defaults # {{{
my $opts = {
  cleanup => 1,
};
# }}}
#
GetOptions($opts,
"help|?",
"man",
) or pod2usage();
pod2usage(1) if ($opts->{help});
pod2usage(-verbose=>2) if ($opts->{man});

# connect to LibVirt # {{{
# RGH FIXME: libvirt uri doesn't permit remote connections, no auth, etc.
my $uri = $ENV{LIBVIRT_DEFAULT_URI} || $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";
my $vmm;
eval { $vmm = Sys::Virt->new(uri=>$uri); }; # Sys::Virt croak/dies on everything!
if ($@) {
  die "Couldn't connect to libvirt! ($!)";
} # }}}

my @domains = @ARGV;
my ($left_domain,$right_domain);

# get left domain # {{{
eval { $left_domain = $vmm->get_domain_by_name($domains[0]) };

if ($@) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

# get right domain # {{{
eval { $right_domain = $vmm->get_domain_by_name($domains[1]) };

if ($@) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

die "Refusing to clone an active VM" if $left_domain->is_active();
die "Refusing to clone an active VM" if $right_domain->is_active();


my $guest = new Sys::Guestfs();

$guest->add_domain($domains[0]);
$guest->add_domain($domains[1]);

$guest->launch();

# can't do this until after launching
$guest->mkmountpoint("/left");
$guest->mkmountpoint("/right");

# generally we want the partition, not the entire disk.
my @roots = grep { /\d$/ } $guest->inspect_os();

$guest->mount($roots[0],"/left");
$guest->mount($roots[1],"/right");

# guestfish returns filesystem locations relative to the FS root - which now has /left or /right prepended to it
my $left_systemroot = sprintf("/left%s",$guest->inspect_get_windows_systemroot($roots[0]));
my $right_systemroot = sprintf("/right%s",$guest->inspect_get_windows_systemroot($roots[1]));

# create a temporary area to download registry hives
my $left_tempdir = File::Temp->newdir( "left-XXXXX", CLEANUP => $opts->{cleanup}, DIR=> "/tmp" );
my $right_tempdir = File::Temp->newdir( "right-XXXXX", CLEANUP => $opts->{cleanup}, DIR=> "/tmp" );

# get paths
my $left_software_hive_path = $guest->case_sensitive_path(sprintf("%s/system32/config/software",$left_systemroot));
my $right_software_hive_path = $guest->case_sensitive_path(sprintf("%s/system32/config/software",$right_systemroot));

# left system hive
my $left_system_hive_path = $guest->case_sensitive_path(sprintf("%s/system32/config/system",$left_systemroot));
my $left_temp_system_hive_fh = File::Temp->new("left-system-hive-XXXXX", DIR=>$left_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
$guest->download($left_system_hive_path,$left_temp_system_hive_fh->filename);
my $left_system_hive = Win::Hivex->open($left_temp_system_hive_fh->filename, write => 0);

# right system hive
my $right_system_hive_path = $guest->case_sensitive_path(sprintf("%s/system32/config/system",$right_systemroot));
my $right_temp_system_hive_fh = File::Temp->new("right-system-hive-XXXXX", DIR=>$right_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
$guest->download($right_system_hive_path,$right_temp_system_hive_fh->filename);
my $right_system_hive = Win::Hivex->open($right_temp_system_hive_fh->filename, write => 0);

# left software hive
my $left_temp_software_hive_fh = File::Temp->new("left-software-hive-XXXXX", DIR=>$left_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
$guest->download($left_software_hive_path,$left_temp_software_hive_fh->filename);
my $left_software_hive = Win::Hivex->open($left_temp_software_hive_fh->filename, write => 0);

# right software hive
my $right_temp_software_hive_fh = File::Temp->new("right-software-hive-XXXXX", DIR=>$right_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
$guest->download($right_software_hive_path,$right_temp_software_hive_fh->filename);
my $right_software_hive = Win::Hivex->open($right_temp_software_hive_fh->filename, write => 0);

# left temp files for .reg dumps (system)
my $left_system_reg_fh = File::Temp->new("left-system-reg-XXXXX", DIR=>$left_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
my $right_system_reg_fh = File::Temp->new("right-system-reg-XXXXX", DIR=>$right_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);

# right temp files for .reg dumps (software)
my $left_software_reg_fh = File::Temp->new("left-software-reg-XXXXX", DIR=>$left_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);
my $right_software_reg_fh = File::Temp->new("right-software-reg-XXXXX", DIR=>$right_tempdir, SUFFIX=>".tmp", UNLINK => 0, CLEANUP => 0);

# export system reg hive
reg_export($left_system_hive,"\\", $left_system_reg_fh, prefix => "HKEY_LOCAL_MACHINE\\SYSTEM",);
reg_export($right_system_hive,"\\", $right_system_reg_fh, prefix => "HKEY_LOCAL_MACHINE\\SYSTEM",);

system("diff","-u5","--show-function-line=^[", $left_system_reg_fh->filename(), $right_system_reg_fh->filename(),);

reg_export($left_software_hive,"\\", $left_software_reg_fh, prefix => "HKEY_LOCAL_MACHINE\\SOFTWARE",);
reg_export($right_software_hive,"\\", $right_software_reg_fh, prefix => "HKEY_LOCAL_MACHINE\\SOFTWARE",);

system("diff","-u5","--show-function-line=^[", $left_software_reg_fh->filename(), $right_software_reg_fh->filename(),);

$guest->umount_all();
$guest->shutdown();
$guest->close();
