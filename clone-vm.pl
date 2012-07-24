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

# xpath filters
my $xpath = {  # {{{
  # XXX FIXME RGH: locate DISK node
  disk => '/domain/devices/disk[@device="disk" and @type="block" and ends-with(target/@dev,"da")]',
  file => '/domain/devices/disk[@device="disk" and @type="file" and  ends-with(target/@dev,"da")]',
}; # }}}

GetOptions($opts,"domain=s","clone=s",'cowpool=s') or pod2usage();
pod2usage (-verbose=>1,-msg=>"Error: domain and clone are required") unless length $opts->{domain} && length $opts->{clone};

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
die "Refusing to clone an active VM" if $source_domain->is_active();

# load the XML into the parser
my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
die "Failed to load XML" unless ref $domain_doc;

rename_vm($domain_doc,$opts->{clone});

# get pool for CoW device  {{{
my $cow_pool;
eval { $cow_pool = $vmm->get_storage_pool_by_name($opts->{cowpool}) };
if ($@) {
  my $err = $@; $err =~ s/[\r\n]*$//;
  die "Couldn't get pool for CoW storage! ($err)";
}; # }}}

# create CoW volume {{{
my $cow_vol = create_cow_vol(
  vmm => $vmm,
  domain_doc => $domain_doc,
  cow_pool => $cow_pool,
  name => $opts->{clone},
); # }}}

update_disk_image($domain_doc, $cow_vol);

# remove the UUID to have libvirt autogen it
my ($uuid) = $domain_doc->findnodes('/domain/uuid');
$uuid->unbindNode();

# remove MAC node to have libvirt autogen it
my ($mac) = $domain_doc->findnodes('/domain/devices/interface[./@type="network"]/mac');
$mac->unbindNode();

# define the domain
my $new_domain;
print STDERR $domain_doc->toString(1);
eval { $new_domain = $vmm->define_domain($domain_doc->toString())} ;
if ($@) {
  my $err = $@; $err =~ s/[\r\n]*$//;
  die "Couldn't create domain! ($err)";
}

# helper subroutines
sub create_cow_vol { # {{{
  my $args;
  %{$args} = @_;

  # get the source disk node path
  # XXX FIXME RGH: locate DISK node
  my ($source_disk) = $args->{domain_doc}->findvalue('/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@dev'
  .
  '|'
  .
  '/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@file');

  # convert that path into a volume object # {{{
  my $backing_vol;
  eval {
    $backing_vol = $vmm->get_storage_volume_by_path($source_disk)
  };

  if ($@) {
    my $err = $@; $err =~ s/[\r\n]*$//;
    die "create_cow: Couldn't get backing storage volume for $source_disk! ($err)";
  } # }}}

  my $info = $backing_vol->get_info() ;

  # get that volume's size
  # get the pool this volume will be in
  # my $pool = $vmm->get_storage_pool_by_name($dest_pool)
  # create a new volume based on the old one
  # my $cow_vol = $pool->create_volume($xml)
  my $cow_xml=sprintf( # XML for CoW volume {{{
q|<volume>
  <name>%s</name>
  <capacity>%d</capacity>
  <target>
    <format type='qcow2'/>
  </target>
  <backingStore>
    <path>%s</path>
    <format type='raw'/>
  </backingStore>
</volume>|,
  $args->{name}.".qcow2",
  $info->{capacity},
  $source_disk); # }}}
  return $args->{cow_pool}->create_volume($cow_xml);
} # }}}

sub rename_vm { # {{{
  my ($xml,$name) = @_;

  my ($name_node) = $xml->findnodes('/domain/name');
  my $text = $xml->createTextNode($name);
  my $old_text = $name_node->firstChild();
  $name_node->replaceChild($text,$old_text)
} # }}}

sub update_disk_image { # {{{
  my ($xml,$volume) = @_;
  my $vol_info = $volume->get_info();
  my $disk_image = $volume->get_path();

  use Data::Dumper; print Data::Dumper->Dump([$vol_info],[qw($vol_info)]);

  # grab the disk node
  # XXX FIXME RGH: locate DISK node
  my ($disk_node) = $xml->findnodes('/domain/devices/disk[@device="disk" and target/@dev="vda"]');

  # modify the <disk> type attribute
  my ($old_type) = $disk_node->findnodes('./@type');
  my $new_type;

  # figure out what type the COW volume is
  if ($vol_info->{type} == $Sys::Virt::StorageVol::TYPE_FILE) { $new_type="file"; }
  elsif ($vol_info->{type} == $Sys::Virt::StorageVol::TYPE_BLOCK) { $new_type="block"; }
  elsif ($vol_info->{type} == $Sys::Virt::StorageVol::TYPE_DIR) { $new_type="dir"; }
  else { die "Unknown Sys::Virt::StorageVol type $vol_info->{type}" }
 
  # create a new <disk> type attribute
  my $type = $xml->createAttribute("type",$new_type);
  # and replace it
  $old_type->replaceNode($type); 

  # create a new source element
  my $source = $xml->createElement("source");
  my $source_dev_attr;
  if ($new_type eq "file")
  { $source_dev_attr = $xml->createAttribute("file",$disk_image); }
  elsif ($new_type eq "block")
  { $source_dev_attr = $xml->createAttribute("dev",$disk_image); }
  else { die "Unknown volume type $new_type" };
  $source->addChild($source_dev_attr);

  my ($old_source) = $disk_node->findnodes('./source');
  $old_source->replaceNode($source);

  # create a new driver element
  my $driver = $xml->createElement("driver");
  my $driver_name_attr=$xml->createAttribute("name","qemu");
  my $driver_type_attr=$xml->createAttribute("type","qcow2");
  # this makes snapshots take 5 seconds instead of 5 minutes.
  # XXX RGH FIXME: try cache = none?
  my $driver_cache_attr=$xml->createAttribute("cache","writethrough");

  # assemble the driver element + attributes
  map { $driver->addChild($_) } $driver_name_attr,$driver_type_attr,$driver_cache_attr;
  # and replace it
  my ($old_driver) = $disk_node->findnodes('./driver');
  $old_driver->replaceNode($driver);
} # }}}

=head1 NAME

clone-vm.pl

=head1 SYNOPSIS

./clone-vm.pl --domain malware-o2k7 --clone malware-clone --cowpool raidvirt
