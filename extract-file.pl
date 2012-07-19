#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;
use Carp::Always;
use Sys::Virt;
use Sys::Guestfs;
use Data::Dumper;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS);
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

# xpath filters
my $xpath = {  # {{{
  # XXX FIXME RGH: locate DISK node
  disk => '/domain/devices/disk[@device="disk" and @type="block" and ends-with(target/@dev,"da")]',
  file => '/domain/devices/disk[@device="disk" and @type="file" and  ends-with(target/@dev,"da")]',
}; # }}}

GetOptions($opts,"domain=s",'files=s@{,}','zip=s') or pod2usage();
print Data::Dumper->Dump([$opts],[qw($opts)]);
pod2usage (-verbose=>1,-msg=>"Error: domain and clone are required") unless length $opts->{domain} && scalar @{$opts->{files}};

# get source domain # {{{
my $source_domain;
eval { $source_domain = $vmm->get_domain_by_name($opts->{domain}) };
# XXX RGH FIXME: There have to be more error cases than "Domain not found" ...
if ($@ =~ m/Domain not found/) {
  my $err = $@;
  $err =~ s/[\r\n]$//g;
  die "Couldn't get domain $opts->{domain}! ($err)";
} # }}}

my $domain_xml = $source_domain->get_xml_description();
die "Refusing to mess with an active VM" if $source_domain->is_active();

# load the XML into the parser
my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
die "Failed to load XML" unless ref $domain_doc;

my ($source_disk) = $domain_doc->findvalue(
  '/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@dev'.
  '|'.
  '/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@file'
);

print Data::Dumper->Dump([$source_disk],[qw($source_disk)]);

my $guest = new Sys::Guestfs();
$guest->add_drive_opts ($source_disk, readonly => 1);
$guest->launch();

my @roots = $guest->inspect_os ();
if (@roots == 0) {
    die "no operating systems found?";
}

for my $root (@roots) { # {{{
    printf "Root device: %s\n", $root;

    my %mps = $guest->inspect_get_mountpoints ($root);
    my @mps = sort { length $a <=> length $b } (keys %mps);
    for my $mp (@mps) { # {{{
        eval { $guest->mount_ro ($mps{$mp}, $mp) };
        if ($@) {
            print "$@ (ignored)\n"
        }
    } # }}}

    my $tempdir = File::Temp->newdir( CLEANUP => 1 );
    my $zip = Archive::Zip->new();

    # fixup windows case sensitivity
    map { $_ = $guest->case_sensitive_path($_) } @{$opts->{files}};

    foreach my $file (@{$opts->{files}}) { # {{{
      # temporary storage of untrusted file-path-names from guest
      my $tempfile_fh = File::Temp->new(DIR => $tempdir, SUFFIX => ".tmp");

      # these objects go out of scope before the zipfile is written to disk,
      # which would cause them to be deleted too early. Let the tempdir
      # CLEANUP take care of them instead.
      $tempfile_fh->unlink_on_destroy(0);

      my $tempfile_name = $tempfile_fh->filename;
      print "Downloading: $file to $tempfile_name\n";
      $guest->download ($file, $tempfile_name);

      # queue for adding to zip
      my $member;
      $member = $zip->addFile($tempfile_name,$file);
      $member->desiredCompressionMethod( COMPRESSION_DEFLATED );
    } # }}}

    unless ($zip->writeToFileNamed($opts->{zip}) == AZ_OK) {
      die 'ZIP write error';
    }
    $guest->umount_all ()
} # }}}
