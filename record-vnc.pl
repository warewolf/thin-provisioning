#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
#use Carp::Always;
use Sys::Virt;
use File::Temp qw( tempfile tempdir);

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
pod2usage (-verbose=>1,-msg=>"Error: --domain [domainname] --fbs [fbs_prefox] --port [number] and are required") unless (length $opts->{domain} && length $opts->{fbs} && length $opts->{port});

# get source domain for cloning # {{{
my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
# XXX RGH FIXME: There have to be more error cases than "Domain not found" ...
if ($@ =~ m/Domain not found/) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

my $domain_xml = $source_domain->get_xml_description(Sys::Virt::Domain::XML_SECURE);
die "Can't record an inactive VM" unless $source_domain->is_active();

# load the XML into the parser
my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
die "Failed to load XML" unless ref $domain_doc;

my $vnc_port_xpath = '/domain/devices/graphics[@type="vnc"]/@port';
my $vnc_password_xpath = '/domain/devices/graphics[@type="vnc"]/@passwd';

my $vnc_port = $domain_doc->findvalue($vnc_port_xpath);
my $vnc_password = $domain_doc->findvalue($vnc_password_xpath);

print "VNC port $vnc_port\n";
print "VNC password $vnc_password\n";

# we need to create the host info file
# and the password file
my $tempdir = File::Temp->newdir( CLEANUP => 1 );

my $hostinfo_file_fh = File::Temp->new(DIR => $tempdir, SUFFIX => ".tmp");
my $passwd_file_fh   = File::Temp->new(DIR => $tempdir, SUFFIX => ".tmp");

my @args = qw(vncreflector -t -q);

printf $hostinfo_file "0.0.0.0:%d %s",$vnc_port-5900,$vnc_password;

# hostinfo format:
# hostname:vncdisplay_Number password
# 
# format of password file
# full_control
# view_only


=head1 NAME

clone-vm.pl

=head1 SYNOPSIS

./clone-vm.pl --domain malware-o2k7 --clone malware-clone --cowpool raidvirt
