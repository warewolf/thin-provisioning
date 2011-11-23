#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
use Carp::Always;
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

# xpath filters
my $xpath = {  # {{{
  disk => '/domain/devices/disk[@device="disk" and target/@dev="vda"]',
}; # }}}

GetOptions($opts,"domain=s","clone=s") or pod2usage();
pod2usage (-verbose=>1,-msg=>"Error: domain and clone are required") unless length $opts->{domain} && length $opts->{clone};

# error checking
my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
if ($@ =~ m/Domain not found/) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
}

my $domain_xml = $source_domain->get_xml_description();
die "Refusing to clone an active VM" if $source_domain->is_active();

# load the XML into the parser
my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";

die "Failed to load XML" unless ref $domain_doc;

rename_vm($domain_doc,$opts->{clone});

my $cow_vol = make_cow($vmm,$domain_xml,"ram");
my $name = $vol->get_path()
update_disk_image($domain_doc, $cow_vol->get_path());

# remove the UUID
my ($uuid) = $domain_doc->findnodes('/domain/uuid');
$uuid->unbindNode();

print $domain_doc->toString(1),"\n";

sub make_cow {
  my ($vmm,$source_domain_xml,$dest_pool) = @_;
  # get the source disk node path
  my ($source_disk_node) = $source_domain_xml->findnodes('/domain/devices/disk[@device="disk" and target/@dev="vda"]');

  # convert that path into a volume object
  # get that volume's size
  # get the pool this volume will be in
  # my $pool = $vmm->get_storage_pool_by_name($dest_pool)
  # create a new volume based on the old one
  # my $cow_vol = $pool->create_volume($xml)

=begin comment

<volume>
  <name>newimage.qcow2</name>
  <capacity>21474836480</capacity>
  <target>
    <format type='qcow2'/>
  </target>
  <backingStore>
    <path>/dev/vg_raid/malware-o2k7</path>
    <format type='raw'/>
  </backingStore>
</volume>

=end comment



}

sub rename_vm { # {{{
  my ($xml,$name) = @_;

  my ($name_node) = $xml->findnodes('/domain/name');
  my $text = $xml->createTextNode($name);
  my $old_text = $name_node->firstChild();
  $name_node->replaceChild($text,$old_text)
} # }}}

sub update_disk_image { # {{{
  my ($xml,$disk_image) = @_;

  # grab the disk node
  my ($disk_node) = $xml->findnodes('/domain/devices/disk[@device="disk" and target/@dev="vda"]');
  # create a new source element
  my $source = $xml->createElement("source");
  my $source_dev_attr = $xml->createAttribute("dev",$disk_image);
  $source->addChild($source_dev_attr);

  my ($old_source) = $disk_node->findnodes('./source');
  $old_source->replaceNode($source);
} # }}}

=head1 NAME

clone-vm.pl

=head1 SYNOPSIS

clone-vm.pl --domain origin_domain --clone clone_name
