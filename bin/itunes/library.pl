# PODNAME: library.pl
use strict;
use warnings;
use feature qw( :5.10 );
use Mac::PropertyList qw( parse_plist_file );
use YAML ();

# The XML iTunes Library has its information in a dictionary key called
# "Tracks".
#
# It's also huge. Might need to do something a bit more custom here...

my $library = parse_plist_file( shift @ARGV );
say YAML::Dump( $_ ) for values %{ $library->as_perl->{Tracks} };

