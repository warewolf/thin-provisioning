#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
use Sys::Virt;
use Sys::Guestfs;
use Data::Dumper;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS);
use File::Temp qw( tempfile tempdir);
use File::Basename;

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

# RGH FIXME: libvirt uri doesn't permit remote connections, no auth, etc.
my $uri = $ENV{LIBVIRT_DEFAULT_URI} || $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";

my $vmm = Sys::Virt->new(uri=>$uri);

# options defaults
my $opts = { destination => '/malware'};

GetOptions($opts,"imagefile=s","domain=s",'destination=s','zip=s@{,}','help|?','man') or pod2usage();
pod2usage (-verbose=>1,-msg=>"Error: domain or imagefile required") unless (defined($opts->{domain}) or defined($opts->{imagefile}));
pod2usage (-verbose=>1,-msg=>"Error: can't use both domain and imagefile") if (defined($opts->{domain}) && defined($opts->{imagefile}));
pod2usage (-verbose=>1,-msg=>"Error: domain/imagefile and files to extract required") unless scalar @{$opts->{zip}};
pod2usage(1) if $opts->{help};
pod2usage(-verbose => 2) if $opts->{man};

my $source_disk;
if ($opts->{domain}) { # {{{
  # get source domain # {{{
  my $source_domain;
  eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
  if ($@) {
    my $err = $@;
    $err =~ s/[\r\n]$//g;
    die "Couldn't get domain $opts->{domain}! ($err)";
  } # }}}

  my $domain_xml = $source_domain->get_xml_description();

  die "Refusing to mess with an active VM - shut it down first" if $source_domain->is_active();

  # load the XML into the parser
  my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
  die "Failed to load XML" unless ref $domain_doc;

  # RGH FIXME: disk selection XPath only selects virtio disks
  ($source_disk) = $domain_doc->findvalue(
    '/domain/devices/disk[@device="disk" and contains(target/@dev,"da")]/source/@dev'.
    '|'.
    '/domain/devices/disk[@device="disk" and contains(target/@dev,"da")]/source/@file'
  );
} # }}}
elsif ($opts->{imagefile}) { # {{{
  $source_disk = $opts->{imagefile};
} else {
  pod2usage (-verbose=>1,-msg=>"Error: wtf?");
} # }}}

my $guest = new Sys::Guestfs();
# TODO RGH: figure out if we want to use Sys::GuestFS against a domain to dig up all disks/partitions "drives"?
$guest->add_drive_opts ($source_disk, readonly => 0);
$guest->launch();

my @roots = $guest->inspect_os ();
if (@roots == 0) {#{{{
    die "no operating systems found?";
}#}}}

for my $root (@roots) { # {{{
  printf "Root device: %s\n", $root;

  my %mps = $guest->inspect_get_mountpoints ($root);
  my @mps = sort { length $a <=> length $b } (keys %mps);
  for my $mp (@mps) { # {{{
    eval { $guest->mount ($mps{$mp}, $mp) };
    if ($@) {
      print "$@ (ignored)\n"
    }
  } # }}}

  $guest->mkdir_p($opts->{destination});

  my $tempdir = File::Temp->newdir( CLEANUP => 1 );

  foreach my $zip_filename (@{$opts->{zip}}) { # {{{
    warn "$zip_filename does not exist" unless -e $zip_filename;

    my $zip = Archive::Zip->new();
    my $status = $zip->read($zip_filename);
    warn "Couldn't read zip $zip_filename" if $status != AZ_OK;

    foreach my $member ($zip->members()) {  # {{{
      next if $member->isDirectory();
      my $internal_name = $member->fileName();
      my $member_fh = File::Temp->new(DIR => $tempdir, SUFFIX => ".tmp");
      my $member_name = $member_fh->filename;
      $zip->extractMemberWithoutPaths($member,$member_name);
      printf("Extracting zip member %s to %s\n",$internal_name,$member_name);
      upload_file($guest,$member_name,sprintf("%s/%s",$opts->{destination},$internal_name));
    } # }}}
  } # }}}
  $guest->umount_all ()
} # }}}

sub upload_file { # {{{
  my ($guest,$source,$destination) = @_;
  my ($file,$dir) = fileparse($destination);
  print "source = $source, dir = $dir, file = $file, destination = $destination\n";
  $guest->mkdir_p($dir);
  $guest->upload($source,$destination);
} # }}}
