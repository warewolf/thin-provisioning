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
  disk => '/domain/devices/disk[@device="disk" and target/@dev="vda"]',
}; # }}}

GetOptions($opts,"domain=s","name=s") or pod2usage();

# get the domain XML so we can find its virtual disk
open(my $domain_xml_fh,"-|",qw(virsh dumpxml),$opts->{domain}) or die "Couldn't run virsh dumpxml $opts->{domain} ($!)";
# load the XML into the parser
my $domain_doc = $parser->load_xml( IO => $domain_xml_fh );
close $domain_xml_fh;

# grab the disk node
my ($disk_node) = $domain_doc->findnodes($xpath->{disk});
# create a new source element
my $source = $domain_doc->createElement("source");
my $source_dev_attr = $domain_doc->createAttribute("dev","/tmp/ram/blah");
$source->addChild($source_dev_attr);

print $disk_node->toString(1),"\n";
my ($old_source) = $disk_node->findnodes('./source');
$old_source->replaceNode($source);

print $disk_node->toString(1),"\n";
