# PODNAME: fill_meta.pl
use strict;
use warnings;

use File::Find;
use File::Basename qw( basename );
use File::Spec::Functions qw( catfile );
use YAML qw( LoadFile DumpFile );
use Getopt::Long;

GetOptions(
    'comic!' => \( my $comic ),
);

my ( $source_file, @destinations ) = @ARGV;

my $meta = LoadFile( $source_file );

for my $dest ( @destinations ) {
    my $dest_file = catfile( $dest, 'metadata.yml' );
    if ( -e $dest_file ) {
        warn "File already exists: $dest_file. Skipping...\n";
        next;
    }
    if ( $comic ) {
        # Determine title from destination folder
        my $title = basename( $dest );
        $meta->{title} = $title;
    }
    DumpFile( $dest_file, $meta );
}

