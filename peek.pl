#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
#use Carp::Always;
use Sys::Virt;
use Sys::Virt::Domain;

my $uri = $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";

my $vmm = Sys::Virt->new(uri=>$uri);

# options defaults
my $opts = {};

GetOptions($opts,"domain=s","output=s") or pod2usage();
pod2usage (-verbose=>1,-msg=>"Error: domain and output are required.  $0 --domain=machine --output=/path/to/ram.dump") unless length $opts->{domain} && length $opts->{output};

my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
# XXX RGH FIXME: There have to be more error cases than "Domain not found" ...
if ($@ =~ m/Domain not found/) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

my $domain_xml = $source_domain->get_xml_description();
die "Refusing to dump an inactive VM" unless $source_domain->is_active();

open(OUTPUT,">",$opts->{output});

# pause VM
$source_domain->suspend();
my $READ_SIZE=64*1024; # 64K
my $info = $source_domain->get_info();

for (my $offset=0; $offset < $info->{memory}*1024; $offset+=$READ_SIZE) {
  my $data = $source_domain->memory_peek($offset, $READ_SIZE, 2);
  print OUTPUT $data;
}
close OUTPUT;

# resume VM
$source_domain->resume();

