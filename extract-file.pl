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

# XXX RGH: You may wonder what all this drivel is here in the options to LibXML:
# XXX RGH: It's to prevent XML being fed into LibXML from executing arbitrary code through XML includes, etc.
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

# options defaults
my $opts = {};

GetOptions($opts,"imagefile=s","domain=s",'files=s@{,}','zip=s','help','man') or pod2usage();
pod2usage(1) if $opts->{help};
pod2usage(-verbose => 2) if $opts->{man};

pod2usage (-verbose=>1,-msg=>"Error: domain or imagefile required") unless (defined($opts->{domain}) or defined($opts->{imagefile}));
pod2usage (-verbose=>1,-msg=>"Error: can't use both domain and imagefile") if (defined($opts->{domain}) && defined($opts->{imagefile}));
pod2usage (-verbose=>1,-msg=>"Error: domain/imagefile and files to extract required") unless scalar @{$opts->{files}};
pod2usage (-verbose=>1,-msg=>"Error: destination zip file required") unless defined($opts->{zip});

my $uri = $ENV{LIBVIRT_DEFAULT_URI} || $ENV{VIRSH_DEFAULT_CONNECT_URI} || "qemu:///system";
my $vmm = Sys::Virt->new(uri=>$uri);


=pod

=head1 NAME

extract-file.pl - extract one or more files from a virtual machine and place them into a zip file.

=head1 STNOPSIS

extract-file.pl --domain malware --files /malware/ --files /windows/system32/drivers/config --zip analysis.zip

extract-file.pl --imagefile malware.qcow2 --files /malware/ --files /windows/system32/drivers/config --zip analysis.zip

=head1 OPTIONS

=over 8

=item B<--imagefile>

A virtual machine disk image file to be read from.  Can be a file (e.g. a qcow file) or a block device -- it will be opened read-only.

=item B<--domain>

A libvirt virtual machine domain name, to locate its first disk image to be opened read-only.

=item B<--files> [list] [of] [files or directories]

A list of paths or files to be extracted from the image.  If a directory is specified, it will be recursivly extracted with no depth limit, so don't try to acquire B</>!

=item B<--zip> [zipfile]

A zip file to write the extracted files to.

=item B<--help>

Display help

=back

=cut

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
  die "Refusing to mess with an active VM" if $source_domain->is_active();

  # load the XML into the parser
  my $domain_doc = $parser->load_xml( string => $domain_xml ) or die "Couldn't load XML ($!)";
  die "Failed to load XML" unless ref $domain_doc;

  # XXX RGH FIXME: this only works for paravirt (virtio) drivers
  ($source_disk) = $domain_doc->findvalue(
    '/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@dev'.
    '|'.
    '/domain/devices/disk[@device="disk" and target/@dev="vda"]/source/@file'
  );
} # }}}
elsif ($opts->{imagefile}) {
  $source_disk = $opts->{imagefile};
} else {
  pod2usage (-verbose=>1,-msg=>"Error: wtf?");
}

my $guest = new Sys::Guestfs();
$guest->add_drive_opts ($source_disk, readonly => 1);
$guest->launch();

my @roots = $guest->inspect_os ();
if (@roots == 0) {
    die "no operating systems found?";
}

for my $root (@roots) { # {{{
    printf "Root device: %s\n", $root;

    my %mountpoints_hash = $guest->inspect_get_mountpoints ($root);
    my @mountpoints_list = sort { length $a <=> length $b } (keys %mountpoints_hash);
    for my $mountpoint (@mountpoints_list) { # {{{
        eval { $guest->mount_ro($mountpoints_hash{$mountpoint}, $mountpoint) };
        if ($@) {
            print "GuestFS Error: $@ (ignored)\n"
        }
    } # }}}

    my $tempdir = File::Temp->newdir( CLEANUP => 1 );
    my $zip = Archive::Zip->new();

    # fixup windows case sensitivity
    map { $_ = $guest->case_sensitive_path($_) } @{$opts->{files}};

    foreach my $file (@{$opts->{files}}) { # {{{
      warn "$file does not exist" unless $guest->exists($file);

      if ($guest->is_file($file)) {
        download_file($zip,$file,$tempdir);
      } elsif ($guest->is_dir($file)) {
        my $dir = $file;
        # recursivly acquire files from a directory
        my $find0_fh = File::Temp->new(DIR => $tempdir, SUFFIX => ".tmp");
        my $find0_name = $find0_fh->filename;
        $guest->find0($dir,$find0_name);
        # go to the beginning of the file
        $find0_fh->seek(0,0);
	  {
	    local $/="\x00";
	    foreach my $found_file (<$find0_fh>) {
              chomp $found_file;
	      download_file($zip,"$dir$found_file",$tempdir) if $guest->is_file("$dir$found_file");
	    }
	  }
        $find0_fh->close();
      }
    } # }}}

    unless ($zip->writeToFileNamed($opts->{zip}) == AZ_OK) {
      die 'ZIP write error';
    }
    $guest->umount_all()
} # }}}

sub download_file { # {{{
  my ($zip,$file,$tempdir) = @_;

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
  $file =~ s/^\///;
  $member = $zip->addFile($tempfile_name,$file);
  $member->desiredCompressionMethod( COMPRESSION_DEFLATED );
} # }}}
