#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
use Sys::Virt;

# XXX RGH XXX: You may wonder what all this drivel is here in the options to LibXML:
# XXX RGH XXX: It's to prevent bad XML fed into LibXML from executing arbitrary code through XML includes, etc.
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

# options defaults # {{{
my $opts = { cowpool => "ram" };
GetOptions($opts,"domain=s","clone=s",'cowpool=s',"help|?","man") or pod2usage();
pod2usage(1) if ($opts->{help});
pod2usage(-verbose=>2) if ($opts->{man});
pod2usage (-verbose=>1,-msg=>"Error: domain and clone are required") unless length $opts->{domain} && length $opts->{clone}; # }}}

# connect to LibVirt # {{{
# RGH FIXME: libvirt uri doesn't permit remote connections, no auth, etc.
my $uri = $ENV{LIBVIRT_DEFAULT_URI} || $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";
my $vmm;
eval { $vmm = Sys::Virt->new(uri=>$uri); }; # Sys::Virt croak/dies on everything!
if ($@) {
  die "Couldn't connect to libvirt! ($!)";
} # }}}

# get source domain for cloning # {{{
my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };

if ($@) {
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
my ($mac) = $domain_doc->findnodes('/domain/devices/interface[./@type="network"  or ./@type="bridge"]/mac');
$mac->unbindNode();

# define the domain # {{{
my $new_domain;
eval { $new_domain = $vmm->define_domain($domain_doc->toString())} ;
if ($@) {
  my $err = $@; $err =~ s/[\r\n]*$//;
  die "Couldn't create domain! ($err)";
} # }}}

# and we're done!

# helper subroutines
sub create_cow_vol { # {{{
  my $args;
  %{$args} = @_;

  # get the source disk node path
  # RGH FIXME: disk selection XPath only selects virtio disks
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

  # RGH: Yes, this is cheating - I just don't feel like creating all the nodes/attributes/etc in LibXML.
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

  # grab the disk node
  # FIXME RGH: only operates on virtio disks
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

  # driver element attributes
  my $attributes = {
    name => 'qemu',
    type => 'qcow2',
    cache => "none",
  };

  # create & add the elements
  while (my ($name,$val) = each %$attributes ) {
    $driver->addChild( $xml->createAttribute($name,$val) );
  };

  # and replace it
  my ($old_driver) = $disk_node->findnodes('./driver');
  $old_driver->replaceNode($driver);
} # }}}

=head1 NAME

clone-vm.pl - clone a VM to a lightweight one

=head1 SYNOPSIS

clone-vm.pl --domain [source_domain] --clone [destination_domain] --cowpool [libvirt-pool]

  Options:
    --domain     source domain to base the clone on
    --clone      name of the clone to create
    --cowpool    QEmu QCOW2 storage pool (RAM drive is best)

=head1 DESCRIPTION

B<clone-vm.pl> creates new virtual machines, based on existing ones.  It does this by cloning virtual machines at the hypervisor level, meaning that it swaps out disk images for light-weight copy-on-write ones, changes MAC addreses to prevent conflicts, and generally makes the hypervisor happy that there are two copies of the same virtual machine.  The OS is still the same OS - e.g. if it's windows, it'll have the same hostname and most likely will complain that there's a duplicate netbios name on the network if two clones can see each other.

The base disk image (the source virtual machine) works best if it is a raw disk image - either a partition on a disk, or a logical volume through LVM.  B<clone-vm.pl> also expects the virtual machine disks to be I<virtio> disks, so please download drivers for them them from L<linux-kvm.org|http://www.linux-kvm.org/page/WindowsGuestDrivers/Download_Drivers>, or look online for C<qemu virtio windows drivers> if the linux-kvm.org link is out of date.

=head1 OPTIONS

=over 8

=item --domain

The existing virtal machine (domain) in libvirt to base a new thinly-privisioned virtual machine on.  This VM should be powered off, and the disk image associated with it should be made read-only.

If the base disk image isn't read only, the QCOW2 changes file will no longer line up with the underlying filesystem (leading to corruption of the clone).  So don't do that.  You can get a list of defined virtual machines (domains) under libvirt with C<virsh --list --all>.

=item --clone

The name of the I<new> virtual machine to be created.  This is the virtual machine you'll be operating in.

=item --cowpool

The name of the I<file system> pool in libvirt.  This will be most effective if the filesystem is C<ramfs> or C<tmpfs>.  B<tmpfs> is strongly suggested, because tmpfs has a set size - ramfs does not.  If your copy-on-write disk images grow large enough, ramfs will happilly permit them to eat up all the available RAM on your system.  The system used in testing had between 24 and 32 gigabytes of ram, which C<tmpfs> by default will cut in half to reserve one half of it for the RAM filesystem.

The minimum amount of RAM on a system dedicated to running analysis virtual machines should be no fewer than between 4 and 6 gigabytes.  Don't forget that the OS running the virtual machines needs RAM too.

=back

=cut
