#!/usr/bin/perl
# vim: foldmethod=marker sw=2 commentstring=\ #\ %s
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;

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

# xpath filters
my $xpath = {  # {{{
  backing => 'string(/domain/devices/disk[@device="disk"]/source/@dev|/domain/devices/disk[@device="disk"]/source/@file)',
  size => '/volume/capacity/child::text()',
}; # }}}

GetOptions($opts,"domain=s","name=s") or pod2usage();

# get the domain XML so we can find its virtual disk
open(my $domain_xml_fh,"-|",qw(virsh dumpxml),$opts->{domain}) or die "Couldn't run virsh dumpxml $opts->{domain} ($!)";
# load the XML into the parser
my $domain_doc = $parser->load_xml( IO => $domain_xml_fh );
close $domain_xml_fh;

($opts->{backing}) = $domain_doc->findvalue($xpath->{backing});

print "Backing is $opts->{backing}\n";


# get the domain XML so we can find its virtual disk
open(my $vol_xml_fh,"-|",qw(virsh vol-dumpxml),$opts->{backing}) or die "Couldn't run virsh vol-dumpxml $opts->{backing} ($!)";
# load the XML into the parser
my $vol_doc = $parser->load_xml( IO => $vol_xml_fh );
close $vol_xml_fh;

($opts->{size}) = $vol_doc->findvalue($xpath->{size});

print "Size is $opts->{size}\n";

#virsh vol-create-as ram $CLONE $SIZE --format qcow2 --backing-vol $BACKING --backing-vol-format raw
system(qw(virsh vol-create-as ram),@$opts{qw(name size)},qw(--format qcow2 --backing-vol-format raw),"--backing-vol",$opts->{backing});

# delete a volume
# vol-delete VOLUME POOL
# virsh vol-delete malware-clone ram
