#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
#use Carp::Always;
use Sys::Virt;

my $parser = XML::LibXML->new( # {{{
    {
        no_network      => 1,
        load_ext_dtd    => 0,
        no_blanks       => 1,
        expand_entities => 0,
        expand_xinclude => 0,
        ext_ent_handler => sub {

            # my ($sys_id, $pub_id) = @_;
            # warn "Received external entity: $sys_id:$pub_id";
            "";
        },
    }
); # }}}

my $uri = $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";

my $vmm = Sys::Virt->new(uri=>$uri);

# options defaults
my $opts = {};

GetOptions($opts,"domain=s","fbs=s","port=i") or pod2usage();
#pod2usage (-verbose=>1,-msg=>"Error: domain and clone are required") unless length $opts->{domain} && length $opts->{clone};

# get source domain for cloning # {{{
my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
# XXX RGH FIXME: There have to be more error cases than "Domain not found" ...
if ($@ =~ m/Domain not found/) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

my $domain_xml = $source_domain->get_xml_description();
die "Can't record an inactive VM" unless $source_domain->is_active();

# load the XML into the parser
my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
die "Failed to load XML" unless ref $domain_doc;

my $xpath = '/domain/devices/graphics[@type="vnc"]/@port';

my $vnc_port = $domain_doc->findvalue($xpath);

print "VNC port $vnc_port\n";
=head1 NAME

clone-vm.pl

=head1 SYNOPSIS

./clone-vm.pl --domain malware-o2k7 --clone malware-clone --cowpool raidvirt
